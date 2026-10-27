# PostgreSQL: физические бэкапы WAL-G

Роль `postgres` настраивает на primary непрерывный WAL-архив и физические
base backup-ы в **два независимых S3-совместимых хранилища** через
[WAL-G](https://github.com/wal-g/wal-g). Каждый WAL-сегмент и каждый base
backup существуют в двух копиях. Реплики WAL не архивируют: они получают
данные потоковой репликацией и при необходимости пересобираются с upstream.

Роль использует WAL-G 3.0.9, PostgreSQL 18, VK Cloud Object Storage как
primary и Yandex Cloud Object Storage как secondary, `zstd` и шифрование
libsodium. Оба таргета обязательны: каждый WAL и каждый base backup
существуют в двух копиях.

## Совместимость со старым сервером

Для этого кластера используется новый libsodium-ключ, сохранённый в
`vault_walg_libsodium_key`. Бэкапы старого сервера `campbox-recovery` были
зашифрованы другим ключом (`/etc/wal-g/libsodium-v1.hex`) и лежали в
префиксе `s3://db-backup/db/pg18/main-encrypted-v1`; текущим ключом их
прочитать нельзя. Если старые бэкапы нужны, сохраните старый ключ отдельно
и используйте для них отдельный WAL-G config. Не направляйте два primary в
один префикс одновременно.

Файл `config-plaintext.json` из `campbox-recovery` относится к старому
незашифрованному префиксу `s3://db-backup/db/pg18/main`. Роль его не
использует; для чтения таких бэкапов нужен отдельный конфиг без
`WALG_LIBSODIUM_*`.

## Что создаётся на primary

| Путь | Назначение |
|---|---|
| `/usr/local/bin/wal-g` | бинарник WAL-G (release `wal-g-pg-24.04-<arch>`) |
| `/usr/local/bin/walg` | обёртка с `--config /etc/wal-g/config.json` (primary S3) |
| `/usr/local/bin/walg-secondary` | обёртка с `--config /etc/wal-g/config-secondary.json` (второй S3) |
| `/usr/local/sbin/walg-archive` | `archive_command`: отправка WAL в оба S3 |
| `/usr/local/sbin/walg-backup` | запуск `full`/`diff`, копирование во второй S3 + retention |
| `/etc/wal-g/config.json` | primary S3: endpoint, credentials, PGDATA, ключ |
| `/etc/wal-g/config-secondary.json` | второй S3: endpoint, credentials, PGDATA, ключ |
| `/etc/wal-g/libsodium-v1.hex` | ключ шифрования, 64 hex-символа (общий для обеих копий) |
| `/etc/systemd/system/wal-g-backup@.service` | oneshot-сервис бэкапа |
| `/etc/systemd/system/wal-g-full.timer` | weekly full, `Sun 02:00` |
| `/etc/systemd/system/wal-g-diff.timer` | daily diff, `03:00` |

Расписание и адреса задаются переменными:

```yaml
postgres_walg_enabled: true
postgres_walg_s3_prefix: "s3://tlcamp-db-backup/db/pg{{ postgres_version }}/main-encrypted-v1"
postgres_walg_s3_endpoint: "https://hb.ru-msk.vkcloud-storage.ru"
postgres_walg_s3_region: "ru-msk"

postgres_walg_secondary_enabled: true
postgres_walg_secondary_s3_prefix: "s3://tlcamp-db-backup/db/pg{{ postgres_version }}/main-encrypted-v1"
postgres_walg_secondary_s3_endpoint: "https://storage.yandexcloud.net"
postgres_walg_secondary_s3_region: "ru-central1"

postgres_walg_full_schedule: "Sun *-*-* 02:00:00"
postgres_walg_diff_schedule: "*-*-* 03:00:00"
postgres_walg_schedule_timezone: "{{ common_timezone }}"
postgres_walg_retain_full: 4
postgres_walg_delta_max_steps: 7
postgres_walg_archive_timeout: "60s"
```

Полный список — в `roles/postgres/defaults/main.yml`. Время в таймерах
указывается в `postgres_walg_schedule_timezone` (по умолчанию
`common_timezone`, то есть `Europe/Moscow`).

Оба S3-таргета обязательны. Роль проверяет, что secondary отличается от
primary хотя бы bucket/prefix или endpoint. Для VK и Yandex используется
один и тот же bucket `tlcamp-db-backup`, поэтому различие обеспечивается
endpoint. Чтобы осознанно оставить одну копию, задайте
`postgres_walg_secondary_enabled: false` (не рекомендуется).

WAL-G делает full backup, а diff-бэкапы строятся от последнего full
(`WALG_DELTA_ORIGIN=LATEST_FULL`). После каждого full выполняется
`wal-g delete retain FULL 4 --confirm`: хранятся четыре последних full и
цепочки diff между ними. Retention выполняется в обоих S3, поэтому наборы
бэкапов остаются одинаковыми.

### Как получаются две копии

- **WAL.** PostgreSQL вызывает `/usr/local/sbin/walg-archive`, а тот
  последовательно делает `wal-push` в primary и secondary S3 независимо.
  Скрипт намеренно отключает фоновую догрузку WAL-G
  (`WALG_UPLOAD_CONCURRENCY=1`) и снимает локальную отметку сегмента
  (`walg_archive_status`): она общая для двух конфигов, и фоновая отправка
  в один S3 иначе могла бы пометить следующий сегмент как уже отправленный
  для второго. Если один S3 недоступен, второй всё равно получает сегмент,
  но `archive_command` возвращает ошибку. PostgreSQL будет повторять
  архивацию, поэтому WAL не потеряется, но `pg_wal` будет расти, пока оба
  S3 не станут доступны. Это осознанная плата за строгие две копии.
- **Base backup.** После `backup-push` в primary S3 скрипт вызывает
  `wal-g copy --from /etc/wal-g/config.json --to
  /etc/wal-g/config-secondary.json`. В daily diff копируется `LATEST` с
  историей WAL, в weekly full — все удерживаемые бэкапы (это также
  догоняет копии, пропущенные из-за сбоя). Копирование байтовое, без
  расшифровки и повторного сжатия.
- **Retention.** `delete retain FULL 4` выполняется и в primary, и в
  secondary S3 только после успешного копирования. Если копирование не
  удалось, сервис завершается с ошибкой, а старые бэкапы не удаляются.

WAL-G не умеет одновременно писать base backup в несколько независимых
хранилищ: `WALG_FAILOVER_STORAGES` — это переключение на резерв при отказе,
а не две копии. Поэтому роль использует два конфига WAL-G и явное
копирование.

При первом включении второго S3 уже существующие в primary бэкапы нужно
скопировать один раз: это делает weekly full (режим full копирует все
бэкапы), либо вручную:

```bash
sudo -u postgres /usr/local/bin/wal-g copy \
  --from /etc/wal-g/config.json \
  --to /etc/wal-g/config-secondary.json \
  --with-history
```

До этого `playbooks/verify.yml` может показать, что старые бэкапы ещё не
скопированы.

## Секреты

В `vault.yml` должны быть пять переменных: credentials обоих облаков и
общий ключ шифрования.

```yaml
# VK Cloud (primary)
vault_walg_s3_access_key_id: "..."
vault_walg_s3_secret_access_key: "..."

# Yandex Cloud (secondary)
vault_walg_secondary_s3_access_key_id: "..."
vault_walg_secondary_s3_secret_access_key: "..."

# Общий ключ для обеих копий, ровно 64 hex-символа
vault_walg_libsodium_key: "..."
```

Ключ шифрования `vault_walg_libsodium_key` общий для обеих копий: без него
невозможно восстановить ни primary, ни secondary. Secondary credentials
обязательны, потому что Yandex Cloud использует отдельный service account;
fallback на ключи VK Cloud остаётся только для случая, когда оба S3
действительно используют один аккаунт.

Ключ генерируется так:

```bash
openssl rand -hex 32
```

Ключ генерируется один раз для кластера. При повторном запуске роли и при
восстановлении должен использоваться тот же ключ, иначе старые бэкапы не
расшифруются.

**Сохраните ключ вне сервера.** Все бэкапы зашифрованы libsodium; без этого
ключа `wal-g backup-fetch` не сможет их расшифровать даже при наличии
рабочих S3-credentials. Копия ключа должна лежать в менеджере секретов или
другом vault, а не только на `pg01`.

S3-ключи и ключ шифрования читаются пользователем `postgres`, потому что
`archive_command` и systemd-сервис работают от его имени. Файлы имеют режим
`0640 root:postgres`.

## Проверка после развёртывания

```bash
# На pg01
systemctl status wal-g-full.timer wal-g-diff.timer
sudo -u postgres walg backup-list
sudo -u postgres walg-secondary backup-list
sudo -u postgres psql -c "SHOW archive_mode; SHOW archive_command;"
sudo -u postgres psql -c "SELECT * FROM pg_stat_archiver;"
```

`archive_mode` должен быть `on`, `archive_command` — вызывать
`/usr/local/sbin/walg-archive`, а `pg_stat_archiver.failed_count` не должен
расти. Списки `walg backup-list` и `walg-secondary backup-list` должны
содержать одинаковые имена бэкапов. Playbook `playbooks/verify.yml`
проверяет это автоматически.

Проверить, что свежий WAL есть в обоих хранилищах, можно так:

```bash
sudo -u postgres walg wal-verify integrity
sudo -u postgres walg-secondary wal-verify integrity
```

Если второй S3 временно недоступен, `archive_command` будет возвращать
ошибку, а PostgreSQL — накапливать WAL в `pg_wal`. Это ожидаемое поведение
при требовании «всегда две копии»; контролируйте `pg_stat_archiver` и
свободное место. После восстановления доступа архивация продолжится
автоматически.

Первый full-бэкап можно создать сразу, не дожидаясь воскресенья:

```bash
sudo systemctl start wal-g-backup@full.service
journalctl -u wal-g-backup@full.service -n 100 --no-pager
```

Либо однократно при первом запуске роли:

```yaml
postgres_walg_run_initial_backup: true
```

После успешного создания верните `false`, иначе бэкап будет запускаться при
каждом прогоне playbook-а.

## Ручные операции

```bash
# Full backup
sudo systemctl start wal-g-backup@full.service

# Differential backup
sudo systemctl start wal-g-backup@diff.service

# Список бэкапов и WAL в обоих хранилищах
sudo -u postgres walg backup-list
sudo -u postgres walg-secondary backup-list
sudo -u postgres walg wal-verify integrity
sudo -u postgres walg-secondary wal-verify integrity

# Догнать второй S3 вручную, если предыдущий запуск копирования упал
sudo -u postgres /usr/local/bin/wal-g copy \
  --from /etc/wal-g/config.json \
  --to /etc/wal-g/config-secondary.json \
  --with-history

# Освободить место вручную (осторожно: удаляет старые цепочки в одном S3)
sudo -u postgres walg delete retain FULL 2 --confirm
sudo -u postgres walg-secondary delete retain FULL 2 --confirm
```

## Восстановление

Восстановление выполняется на хосте с тем же major-версией PostgreSQL
(18) и тем же WAL-G-конфигом. Все команды ниже — на восстанавливаемом
хосте.

### 1. Подготовка

Убедитесь, что:

- `/etc/wal-g/config.json`, `/etc/wal-g/config-secondary.json` и
  `/etc/wal-g/libsodium-v1.hex` на месте;
- `vault_walg_libsodium_key` — тот же, что использовался при создании
  бэкапов;
- нужный S3 доступен, а `walg backup-list` или
  `walg-secondary backup-list` показывает бэкапы;
- PostgreSQL остановлен.

Если primary S3 недоступен, используйте второй S3: замените в командах ниже
`walg` на `walg-secondary`, а в `restore_command` — путь на
`/usr/local/bin/walg-secondary`. Второй S3 содержит те же base backup-ы и
WAL, что и primary.

Если хост пересоздан с нуля, сначала выполните роль `postgres` (она
установит пакеты, WAL-G и конфиги), но **не запускайте приложение** до
окончания restore.

### 2. Full restore

```bash
sudo systemctl stop postgresql

# Сохраните текущий (пустой или повреждённый) каталог
sudo mv /var/lib/postgresql/18/main /var/lib/postgresql/18/main.old

# WAL-G создаст каталог сам
sudo -u postgres /usr/local/bin/walg backup-fetch \
  /var/lib/postgresql/18/main LATEST

# Включаем recovery
sudo -u postgres touch /var/lib/postgresql/18/main/recovery.signal

# Добавляем restore_command в auto.conf
sudo -u postgres sh -c 'cat >> /var/lib/postgresql/18/main/postgresql.auto.conf <<"EOF"
restore_command = '\''/usr/local/bin/walg wal-fetch "%f" "%p"'\''
recovery_target_timeline = '\''latest'\''
EOF'

sudo systemctl start postgresql@18-main
sudo journalctl -u postgresql@18-main -f
```

Дождитесь сообщения `database system is ready to accept connections`.
Проверьте:

```bash
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
```

Если восстановление завершилось и PostgreSQL ещё в recovery, повысьте его:

```bash
sudo -u postgres pg_ctlcluster 18 main promote
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"   # f
```

После успешного старта уберите `restore_command`, чтобы он не применялся при
следующих перезапусках:

```bash
sudo -u postgres psql -c "ALTER SYSTEM RESET restore_command;"
sudo -u postgres psql -c "ALTER SYSTEM RESET recovery_target_timeline;"
sudo -u postgres psql -c "SELECT pg_reload_conf();"
```

Старый каталог `main.old` удалите только после проверки данных и успешного
бэкапа.

### 3. Восстановление из второй копии

Если primary S3 потерян, все шаги те же, но используются secondary-конфиг и
обёртка:

```bash
sudo -u postgres /usr/local/bin/walg-secondary backup-fetch \
  /var/lib/postgresql/18/main LATEST

# restore_command для второй копии
restore_command = '/usr/local/bin/walg-secondary wal-fetch "%f" "%p"'
```

Не смешивайте конфиги в одной цепочке восстановления: base backup и WAL
должны быть из одного S3.

### 4. Point-in-time recovery (PITR)

В `postgresql.auto.conf` вместо (или вместе с) `recovery_target_timeline`
добавьте цель:

```conf
recovery_target_time = '2026-10-21 12:00:00+03'
recovery_target_action = 'promote'
```

Порядок действий такой же, как в full restore. WAL-G будет отдавать WAL из
S3 до указанного времени. Для восстановления на конкретный base backup
подставьте его имя из `walg backup-list` вместо `LATEST`.

### 5. Восстановление на новую ВМ

1. Добавьте хост в inventory и выполните роль `postgres` с тегом `postgres`
   (или `playbooks/postgres.yml --limit <host>`), чтобы получить пакеты,
   WAL-G, ключ и конфиги.
2. Остановите PostgreSQL и выполните full restore из раздела выше.
3. Проверьте данные, затем настройте приложение и мониторинг.
4. Если новая ВМ должна стать primary, обновите `postgres_replication_topology`
   и запустите playbook ещё раз — роль включит `archive_mode=on` на хосте из
   группы `postgres_primary`.

## Failover

На репликах `archive_mode=off`, поэтому после повышения реплики нужно
явно сделать её primary в inventory:

1. Перенесите хост из `postgres_replicas` в `postgres_primary`.
2. Обновите `postgres_replication_topology` (downstream-реплики должны
   смотреть на нового primary).
3. Запустите `playbooks/postgres.yml`. Роль включит WAL-архив на новом
   primary и создаст слоты для downstream-реплик.
4. Старый primary **не запускайте как primary**: его нужно пересобрать как
   реплику, иначе возможен split-brain и конфликт WAL в S3.

`WALG_PREVENT_WAL_OVERWRITE=true` защищает от перезаписи WAL в S3, но не
заменяет процедуру failover.

## Диагностика

```bash
# Ошибки архивации
sudo -u postgres psql -c "SELECT * FROM pg_stat_archiver;"
sudo journalctl -u postgresql@18-main -n 200 --no-pager

# Ошибки бэкапа
sudo journalctl -u wal-g-backup@full.service -n 200 --no-pager
sudo journalctl -u wal-g-backup@diff.service -n 200 --no-pager

# Проверка конфигурации и доступа к обоим S3
sudo -u postgres /usr/local/bin/wal-g --config /etc/wal-g/config.json backup-list
sudo -u postgres /usr/local/bin/wal-g --config /etc/wal-g/config-secondary.json backup-list
```

Типовые причины:

- `403 Forbidden`/`AccessDenied` — неверные S3-ключи, endpoint, регион или
  политика бакета; проверьте оба конфига, у них могут быть разные
  credentials;
- `failed to decrypt`/`invalid key` — не тот libsodium-ключ;
- `archive_command failed` — нет доступа к `/etc/wal-g/config.json`,
  `/etc/wal-g/config-secondary.json`, ключу или одному из S3; смотрите
  `pg_stat_archiver.last_failed_wal` и сообщение `WAL-G archive failed ...
  primary=... secondary=...`;
- `Copy to the second S3 failed` — `wal-g copy` не смог записать во второй
  S3; бэкап остался в primary, retention не выполнялся. Исправьте доступ и
  повторите `wal-g copy` вручную (команда идемпотентна);
- `backup-push` не находит PGDATA — проверьте `PGDATA` в
  `/etc/wal-g/config.json` и права `postgres`.

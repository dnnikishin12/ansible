# Миграция GitLab CE на новую ВМ

Пошаговая процедура переноса существующего GitLab на новую машину,
разворачиваемую этим репозиторием. Предполагается, что старый GitLab
установлен Omnibus-пакетом; для Docker-установки команды backup/restore
отличаются. Схема:

```text
старый GitLab ── backup + gitlab.rb + gitlab-secrets.json ──▶ S3
                                                               │
                                                               ▼
                                              новая ВМ gitlab01 ──▶ restore
```

Резервная копия в S3 — правильный подход, но **одного архива GitLab
недостаточно**. Обязательно переносятся конфигурация и файл секретов, а версия
GitLab на новой машине должна совпадать со старой.

## Что входит в backup

`gitlab-backup create` включает:

- базу данных PostgreSQL;
- Git-репозитории, wiki и LFS;
- загруженные файлы, артефакты CI, логи job-ов;
- container registry и packages, если они хранятся локально;
- GitLab Pages, Terraform state, snippets и Secure Files.

В backup **не входят**:

- `/etc/gitlab/gitlab.rb`;
- `/etc/gitlab/gitlab-secrets.json`;
- TLS- и SSH-ключи, включая `/etc/gitlab/ssl`, `/etc/gitlab/trusted-certs`
  и host keys SSH;
- данные Redis, включая очередь Sidekiq;
- объектное хранилище (S3/MinIO), если uploads, artifacts, registry или
  packages вынесены туда;
- глобальные server hooks и file hooks.

`gitlab-secrets.json` содержит ключи шифрования базы. Без него не будут
работать CI/CD variables, 2FA, runner-токены и другие зашифрованные данные.

## Требования

- Одинаковая версия и редакция GitLab: CE/CE или EE/EE. Восстановить backup
  CE в EE можно не всегда, обратное направление не поддерживается. Роль
  `gitlab` в этом репозитории устанавливает CE; для EE потребуется изменить
  `gitlab_package` и URL репозитория.
- Свободное место в каталоге backup на новой ВМ: **не менее 3× размера
  архива**.
- S3-совместимое хранилище, приватный bucket, шифрование и versioning.
- `rclone` на старой и новой ВМ (или другой способ доставки файлов).
- Окно обслуживания: на время финального backup запись в GitLab
  останавливается.
- Проверочное восстановление на тестовой ВМ до production-переключения.

## 1. Зафиксировать версию

На старом GitLab:

```bash
sudo gitlab-rake gitlab:env:info
dpkg-query -W -f='${Package} ${Version}\n' gitlab-ce
```

Запишите точную версию, например `17.11.4-ce.0`. Дальше есть два варианта:

1. Обновить старый GitLab до целевой версии, затем сделать backup.
2. Установить на новой ВМ ровно ту же версию, что на старом GitLab.

Проще обновить старый GitLab до той версии, которую будете ставить на новую
ВМ. Нельзя восстановить backup в другую версию — `gitlab-backup restore`
остановится с ошибкой version mismatch.

## 2. Подготовить S3

Создайте отдельный bucket или префикс, например:

```text
s3://company-gitlab-backups/encrypted/migration/2026-10-20T02-30-00Z/
```

Рекомендации:

- Block Public Access;
- SSE-S3 или SSE-KMS;
- versioning и lifecycle policy;
- отдельный IAM-пользователь только для этого префикса;
- минимальные права: `PutObject`, `GetObject`, `ListBucket`;
- не использовать учётные данные GitLab или приложения.

Для `gitlab-secrets.json` желательно клиентское шифрование. В примере ниже
используется `rclone crypt` поверх S3. Если crypt не нужен, замените remote
`gitlab-crypt:` на `s3:` и включите SSE-KMS на bucket.

Пример настройки rclone на старом хосте:

```bash
sudo apt-get update
sudo apt-get install -y rclone
sudo install -d -m 0750 /etc/rclone
sudo rclone config --config /etc/rclone/rclone.conf
sudo chmod 600 /etc/rclone/rclone.conf
```

В `rclone config` создайте:

1. S3-remote, например `s3`;
2. crypt-remote `gitlab-crypt` с `remote = s3:company-gitlab-backups/encrypted`.

Пароль crypt-remote сохраните в менеджере секретов: без него backup в S3
невозможно расшифровать.

Проверка:

```bash
sudo rclone lsd gitlab-crypt: --config /etc/rclone/rclone.conf
```

## 3. Настроить backup на старом GitLab

Создайте `/usr/local/sbin/gitlab-s3-backup.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/var/opt/gitlab/backups"
RCLONE_CONFIG="/etc/rclone/rclone.conf"
REMOTE="gitlab-crypt:migration"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="${REMOTE}/${STAMP}"

install -d -o git -g git -m 0700 "${BACKUP_DIR}"

/opt/gitlab/bin/gitlab-backup create CRON=1 STRATEGY=copy

install -m 0600 /etc/gitlab/gitlab.rb \
  "${BACKUP_DIR}/gitlab.rb.${STAMP}"
install -m 0600 /etc/gitlab/gitlab-secrets.json \
  "${BACKUP_DIR}/gitlab-secrets.json.${STAMP}"

ARCHIVE="$(
  find "${BACKUP_DIR}" -maxdepth 1 -type f \
    -name '*_gitlab_backup.tar' -printf '%T@ %p\n' \
    | sort -nr | head -n1 | cut -d' ' -f2-
)"
if [[ -z "${ARCHIVE}" ]]; then
  echo "GitLab backup archive not found" >&2
  exit 1
fi

dpkg-query -W -f='${Package} ${Version}\n' gitlab-ce \
  > "${BACKUP_DIR}/gitlab-version.${STAMP}.txt"

cd "${BACKUP_DIR}"
sha256sum \
  "$(basename "${ARCHIVE}")" \
  "gitlab.rb.${STAMP}" \
  "gitlab-secrets.json.${STAMP}" \
  "gitlab-version.${STAMP}.txt" \
  > "SHA256SUMS.${STAMP}"

for file in \
  "$(basename "${ARCHIVE}")" \
  "gitlab.rb.${STAMP}" \
  "gitlab-secrets.json.${STAMP}" \
  "gitlab-version.${STAMP}.txt" \
  "SHA256SUMS.${STAMP}"; do
  rclone copy "${BACKUP_DIR}/${file}" "${DEST}/" \
    --config "${RCLONE_CONFIG}"
done

rclone ls "${DEST}" --config "${RCLONE_CONFIG}"
```

Выставьте права и проверьте:

```bash
sudo chown root:root /usr/local/sbin/gitlab-s3-backup.sh
sudo chmod 0750 /usr/local/sbin/gitlab-s3-backup.sh
sudo /usr/local/sbin/gitlab-s3-backup.sh
```

Скрипт делает полный backup, копирует конфигурацию и секреты, считает
контрольные суммы и выгружает всё в один каталог с UTC-меткой.

Если в `/etc/gitlab/gitlab.rb` задан нестандартный
`gitlab_rails['backup_path']`, измените `BACKUP_DIR` в скрипте. Если на старом
хосте уже включена штатная выгрузка backup в S3, добавьте к команде
`gitlab-backup` параметр `SKIP=remote`, иначе архив будет выгружен дважды.

> `STRATEGY=copy` требует дополнительного места на диске, примерно равного
> объёму копируемых данных. Для больших инсталляций используйте обычную
> стратегию или отдельный backup-диск.

Для регулярного запуска можно добавить cron:

```cron
30 2 * * * root /usr/local/sbin/gitlab-s3-backup.sh
```

Не запускайте одновременно этот скрипт и штатный таймер backup GitLab.

### Финальный backup

Перед финальным backup:

1. Остановите GitLab Runners или дождитесь завершения CI-задач.
2. Включите maintenance mode в Admin Area, чтобы пользователи не создавали
   изменения.
3. Остановите Puma и Sidekiq.
4. Убедитесь, что в очереди Sidekiq не осталось важных задач.

```bash
sudo gitlab-ctl stop puma
sudo gitlab-ctl stop sidekiq
sudo gitlab-ctl status
sudo /usr/local/sbin/gitlab-s3-backup.sh
```

После успешной выгрузки остановите старый GitLab, но **не удаляйте ВМ** до
проверки новой инсталляции:

```bash
sudo gitlab-ctl stop
```

## 4. Развернуть новую ВМ

В репозитории зафиксируйте версию и временно отключите backup-таймер. Создайте
`inventories/production/host_vars/gitlab01.yml`:

```yaml
---
gitlab_package: "gitlab-ce=17.11.4-ce.0"
gitlab_backup_enabled: false
```

Установите GitLab:

```bash
ansible-playbook playbooks/bootstrap.yml --limit gitlab01 --ask-vault-pass
ansible-playbook playbooks/gitlab.yml --limit gitlab01 --ask-vault-pass
```

Роль создаст рабочую инсталляцию и выполнит `gitlab-ctl reconfigure`. Пока не
восстанавливайте пользовательские данные и не создавайте проекты.

## 5. Скачать backup и восстановить

На новой ВМ настройте такой же rclone remote (те же S3 и crypt-пароль), затем:

```bash
sudo apt-get install -y rclone
sudo install -d -m 0750 /etc/rclone
sudo rclone config --config /etc/rclone/rclone.conf
sudo chmod 600 /etc/rclone/rclone.conf

STAMP="2026-10-20T02-30-00Z"
sudo rclone copy "gitlab-crypt:migration/${STAMP}" \
  /var/opt/gitlab/backups/ \
  --config /etc/rclone/rclone.conf
```

Проверьте контрольные суммы:

```bash
cd /var/opt/gitlab/backups
sudo sha256sum -c "SHA256SUMS.${STAMP}"
```

Восстановите конфигурацию и секреты:

```bash
sudo install -m 0600 "gitlab.rb.${STAMP}" /etc/gitlab/gitlab.rb
sudo install -m 0600 "gitlab-secrets.json.${STAMP}" \
  /etc/gitlab/gitlab-secrets.json
sudo editor /etc/gitlab/gitlab.rb
```

В `gitlab.rb` проверьте как минимум:

- `external_url` — должен соответствовать новому адресу;
- настройки SMTP, LDAP, OAuth и object storage;
- пути repository storage;
- параметры nginx, если GitLab стоит за внешним proxy.

Затем:

```bash
sudo gitlab-ctl reconfigure
```

> Если старый `gitlab.rb` содержит настройки, которых нет в шаблоне роли,
> перенесите их в переменные/шаблон. Иначе следующий запуск
> `playbooks/gitlab.yml` перезапишет `/etc/gitlab/gitlab.rb`.

Архив должен находиться в каталоге `gitlab_rails['backup_path']` из
`/etc/gitlab/gitlab.rb` (по умолчанию `/var/opt/gitlab/backups`). Имя backup
ID — это имя файла без суффикса `_gitlab_backup.tar`:

```bash
cd /var/opt/gitlab/backups
sudo chown git:git ./*_gitlab_backup.tar
BACKUP_ID="$(ls -1t *_gitlab_backup.tar | head -n1 | sed 's/_gitlab_backup.tar$//')"
echo "${BACKUP_ID}"
```

Остановите процессы, которые пишут в базу:

```bash
sudo gitlab-ctl stop puma
sudo gitlab-ctl stop sidekiq
sudo gitlab-ctl status
```

Восстановите:

```bash
sudo GITLAB_ASSUME_YES=1 gitlab-backup restore BACKUP="${BACKUP_ID}"
sudo gitlab-ctl reconfigure
sudo gitlab-ctl restart
```

`GITLAB_ASSUME_YES=1` отключает интерактивные подтверждения. Используйте его
только после проверки, что выбрана правильная ВМ и правильный архив.

Проверка:

```bash
sudo gitlab-ctl status
sudo gitlab-rake gitlab:check SANITIZE=true
sudo gitlab-rake gitlab:doctor:secrets
sudo gitlab-rake gitlab:artifacts:check
sudo gitlab-rake gitlab:lfs:check
sudo gitlab-rake gitlab:uploads:check
```

`gitlab:doctor:secrets` особенно важен: он проверяет, что данные в базе
расшифровываются восстановленным `gitlab-secrets.json`.

## 6. Переключить трафик

Если домен остаётся прежним:

1. Переключите DNS `gitlab.<domain>` на `nginx01`.
2. Убедитесь, что nginx проксирует на новую ВМ `gitlab01`.
3. Обновите inventory, если IP новой ВМ изменился.
4. Примените nginx:
   ```bash
   ansible-playbook playbooks/nginx.yml --ask-vault-pass
   ```

Если меняется FQDN:

- обновите `gitlab_external_url` и `external_url` в `gitlab.rb`;
- обновите URL у GitLab Runners;
- пользователи с WebAuthn/YubiKey должны заново зарегистрировать ключи;
- обновите известные SSH host keys или попросите пользователей удалить старую
  запись из `known_hosts`;
- обновите webhooks и внешние интеграции, если они используют старый URL.

Проверьте вручную:

- вход root и обычного пользователя;
- 2FA;
- `git clone` по SSH и HTTPS;
- запуск тестового pipeline;
- загрузку и скачивание артефактов;
- GitLab Container Registry, если используется;
- webhooks;
- GitLab Runners.

## 7. Вернуть backup-расписание

После успешной проверки:

1. Уберите `gitlab_backup_enabled: false` из `host_vars/gitlab01.yml` или
   установите `true`.
2. Настройте выгрузку backup в S3 для новой ВМ.
3. Запустите `playbooks/gitlab.yml` повторно, чтобы включить таймер.
4. Сделайте первый backup новой инсталляции и проверьте его в S3.

Если для новой ВМ нужна такая же S3-выгрузка, можно использовать тот же
`gitlab-s3-backup.sh` и systemd-таймер вместо локального backup-таймера роли.
Не запускайте два backup-процесса одновременно.

## 8. Rollback

Старую ВМ не удаляйте, пока новая не проверена. Если restore или переключение
не удались:

1. Верните DNS/nginx на старую ВМ.
2. Запустите старый GitLab:
   ```bash
   sudo gitlab-ctl start
   ```
3. Убедитесь, что старый GitLab работает, и только после этого удаляйте
   неудачную новую инсталляцию.

## Частые проблемы

### Version mismatch

`gitlab-backup restore` требует точного совпадения версии и редакции. Установите
на новую ВМ ту же версию `gitlab-ce`, что была на старой, либо обновите старую
до целевой версии и повторите backup.

### Ошибка «repository already exists»

Restore нужно выполнять в чистую инсталляцию. Не создавайте проекты и группы до
восстановления. Если данные уже есть, разверните новую ВМ заново.

### Не работают CI/CD variables или 2FA

Не восстановлен или взят от другого backup `gitlab-secrets.json`. Верните файл
из того же recovery point, выполните `gitlab-ctl reconfigure` и повторите
restore.

### Потеряны uploads, artifacts или registry

Проверьте, не используются ли для них S3/MinIO. GitLab backup не копирует
объектное хранилище. Настройте новую ВМ на тот же bucket или перенесите данные
отдельно.

### Не хватает места

Restore требует минимум 3× размера архива в каталоге backup. Освободите место
или используйте отдельный диск.

## Минимальный чек-лист

- [ ] Версия и редакция GitLab совпадают.
- [ ] S3 bucket приватный, с шифрованием и versioning.
- [ ] Backup содержит архив, `gitlab.rb`, `gitlab-secrets.json`.
- [ ] Контрольные суммы совпадают.
- [ ] Новая ВМ — чистая инсталляция GitLab.
- [ ] Restore выполнен, `gitlab:check` и `gitlab:doctor:secrets` прошли.
- [ ] Проверены clone, pipeline, runners, 2FA и registry.
- [ ] DNS/nginx переключены.
- [ ] Backup-таймер снова включён.
- [ ] Старая ВМ сохранена до окончания проверки.

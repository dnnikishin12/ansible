# Ansible-инфраструктура TLCamp

Playbook-и для развёртывания и сопровождения десяти виртуальных машин из
[`vmlist`](vmlist):

- GitLab CE;
- PostgreSQL 18: primary, реплика первого уровня и каскадная реплика во
  втором облаке; все клиентские и репликационные подключения идут по
  публичным IP и защищены TLS;
- Valkey на хосте primary;
- два production-хоста Docker и один test-хост Docker;
- Elasticsearch + Logstash + Kibana;
- nginx с терминацией TLS;
- maintenance-хост с rclone для выгрузки резервных копий.

Репозиторий описывает **платформу**, а не прикладные сервисы: Docker-хосты
подготавливаются, но приложения в них не разворачиваются. GitLab, PostgreSQL,
Valkey и Elastic Stack устанавливаются и настраиваются.

> **Перед первым запуском обязательно прочитайте раздел
> [«Что заменить перед запуском»](#что-заменить-перед-запуском).**
> В репозитории используются placeholder-адреса, домен и пароли.
> Реальные значения в открытом виде в репозиторий не попадают.

## Содержание

- [Архитектура](#архитектура)
- [Что заменить перед запуском](#что-заменить-перед-запуском)
- [Требования](#требования)
- [Быстрый старт](#быстрый-старт)
- [Секреты и Ansible Vault](#секреты-и-ansible-vault)
- [Inventory](#inventory)
- [Provisioning в Proxmox VE](#provisioning-в-proxmox-ve)
- [Playbook-и и теги](#playbook-и-и-теги)
- [Что настраивается](#что-настраивается)
- [TLS и DNS](#tls-и-dns)
- [Резервное копирование](#резервное-копирование)
- [Миграция GitLab](#миграция-gitlab)
- [Безопасность](#безопасность)
- [Проверка и диагностика](#проверка-и-диагностика)
- [Ограничения и допущения](#ограничения-и-допущения)
- [Структура репозитория](#структура-репозитория)

## Архитектура

### Виртуальные машины

Все ВМ в проекте имеют **публичные адреса**. `203.0.113.0/24` ниже —
placeholder: замените каждый `ansible_host` на реальный публичный IP.
Приватной management-сети нет, поэтому Ansible, межсервисный трафик и
PostgreSQL используют одни и те же публичные адреса.

Провижининг через Proxmox **не запускается по умолчанию**: `make site`
работает с уже существующими ВМ. `make provision` — отдельная опциональная
команда для Proxmox.

| ВМ | Публичный IP | Роль | vCPU / RAM / диск |
|---|---|---|---|
| `gitlab01` | `203.0.113.11` | GitLab CE, встроенный nginx на `:80`/`:443` | 4 / 8 ГБ / 100 ГБ |
| `pg01` | `203.0.113.12` | PostgreSQL 18 primary + Valkey | 4 / 16 ГБ / 200 ГБ |
| `pg02` | `203.0.113.13` | PostgreSQL 18 реплика первого уровня, upstream для `pg03` | 4 / 16 ГБ / 200 ГБ |
| `pg03` | `203.0.113.14` | PostgreSQL 18 каскадная реплика во втором облаке | 4 / 16 ГБ / 200 ГБ |
| `docker-prod-01` | `203.0.113.15` | Docker Engine, production | 4 / 8 ГБ / 100 ГБ |
| `docker-prod-02` | `203.0.113.16` | Docker Engine, production во втором облаке | 4 / 8 ГБ / 100 ГБ |
| `docker-test-01` | `203.0.113.17` | Docker Engine, test | 6 / 8 ГБ / 128 ГБ |
| `elk01` | `203.0.113.18` | Elasticsearch, Logstash, Kibana | 4 / 16 ГБ / 200 ГБ |
| `nginx01` | `203.0.113.19` | nginx, TLS-терминация | 2 / 2 ГБ / 40 ГБ |
| `maint01` | `203.0.113.20` | rclone, backup jobs | 2 / 2 ГБ / 50 ГБ |

В исходном `vmlist` явно задан размер только тестового Docker-хоста
(`6cpu-8Gb-128SSD`). Остальные размеры — разумные стартовые значения; их нужно
скорректировать под реальную нагрузку. Размеры `pg03` и `docker-prod-02`
задаются отдельно во втором облаке.

PostgreSQL использует те же публичные адреса, что и остальные сервисы:
`postgres_replication_address` в `host_vars/pg01.yml`, `host_vars/pg02.yml` и
`host_vars/pg03.yml` совпадает с `ansible_host`. Публичный адрес входит в SAN
сертификата автоматически.

> Предполагается, что `docker-prod-02` — это вторая production-машина во
> втором облаке. Если это отдельный новый хост, добавьте его в `hosts.yml` и
> `postgres_app_client_rules`; `docker-prod-02` можно вернуть в
> `provisioning/proxmox/vars.yml`, если он создаётся в Proxmox.

### Потоки трафика

```text
   HTTPS :443  ──▶ gitlab01 (GitLab, TLS + Let's Encrypt)
   HTTPS :443  ──▶ elk01    (Kibana, TLS + Let's Encrypt)

  Filebeat (все хосты, кроме elk01) ──▶ Logstash :5044 на elk01 (public)
  PostgreSQL pg01 ──streaming (TLS/public)──▶ pg02
  pg02 ──streaming (TLS/public)──▶ pg03 (второе облако)
  Docker prod hosts + внешний app/pgAdmin 95.163.209.96 ──TLS/public──▶ PostgreSQL :5432
  Docker hosts ──public/restricted──▶ Valkey :6379 на pg01 (без TLS)
```

- GitLab и Kibana опубликованы напрямую: DNS указывает на `gitlab01` и
  `elk01`, TLS завершается на самих сервисах. GitLab использует встроенный
  nginx и Let's Encrypt; Kibana слушает `:443` и получает сертификат через
  certbot.
- `nginx01` остаётся отдельным хостом для других задач и не участвует в
  публикации GitLab/Kibana.
- PostgreSQL реплицируется каскадом: `pg01` → `pg02`, затем
  `pg02` → `pg03`. Оба соединения идут по публичным IP и защищены TLS;
  `pg03` не подключается к `pg01` напрямую.
- Приложения подключаются к публичному адресу `pg01` с `sslmode=verify-full`.
  UFW и `pg_hba.conf` разрешают только перечисленные публичные `/32`, в том
  числе внешний Node.js/pgAdmin-сервер `95.163.209.96`, который не входит в
  inventory.
- Physical replication slots создаются на непосредственном upstream:
  `replica_pg02` на `pg01` и `replica_pg03` на `pg02`.
- Valkey не имеет TLS. UFW разрешает `6379` только с публичных адресов
  `docker-prod-01` и `docker-test-01`; `docker-prod-02` во втором облаке
  намеренно не допускается, пока для Valkey не включён TLS.
- Filebeat отправляет системные логи, логи nginx, Docker, GitLab и PostgreSQL
  в Logstash на `elk01` по публичной сети. UFW на `elk01` разрешает `5044`
  только с публичных адресов хостов группы `log_shippers`. Сам `elk01`
  исключён из группы, чтобы не отправлять логи самому себе.

## Что заменить перед запуском

В репозитории намеренно оставлены значения-заглушки. Перед первым запуском
замените:

1. **Публичные IP-адреса** в `inventories/production/hosts.yml`. Замените
   все `203.0.113.x` на реальные публичные адреса ВМ. Если используете
   опциональный Proxmox provisioning, обновите те же адреса, шлюз и
   nameserver в `provisioning/proxmox/vars.yml`. `pg03` и `docker-prod-02`
   находятся во втором облаке и в `proxmox_vms` намеренно отсутствуют.
   `postgres_replication_address` в `host_vars/pg01.yml`, `host_vars/pg02.yml`
   и `host_vars/pg03.yml` должен совпадать с публичным `ansible_host`.
2. **Домен** `campbox.tech` в
   `inventories/production/group_vars/all/main.yml`
   (`internal_domain`, `gitlab_hostname` = `gitlab-test.<domain>`,
   `kibana_hostname` = `elastik.<domain>`) и `proxmox_searchdomain` в
   `provisioning/proxmox/vars.yml`. DNS-записи этих имён должны указывать на
   публичные адреса `gitlab01` и `elk01`.
3. **План адресации**: `203.0.113.0/24` — только placeholder. Публичной
   management-сети нет; замените адреса ВМ на реальные публичные. Если
   используете Proxmox, задайте там реальный публичный шлюз.
4. **Часовой пояс и NTP-серверы**: `common_timezone`, `common_ntp_servers`.
5. **SSH-доступ**: SSH намеренно открыт с любых IPv4/IPv6-адресов
   (`common_firewall_ssh_sources` = `0.0.0.0/0`, `::/0`). Пароли отключены,
   используется только ключ. `common_fail2ban_ignoreips` пуст, поэтому
   fail2ban банит перебор со всех адресов; стандартное исключение — только
   loopback `127.0.0.1/8` и `::1`. Если меняете `common_ssh_port`, задайте
   соответствующий `ansible_port` в inventory.
6. **Публичный доступ к PostgreSQL**: в `host_vars/pg01.yml` задайте
   `postgres_replication_address` — публичный адрес primary, который
   используют приложения и `pg02`; в `host_vars/pg02.yml` — публичный адрес
   `pg02` для `pg03` и `postgres_replication_source_cidr` — публичный/NAT
   source, который видит `pg01`; в `group_vars/postgres_cascading.yml` —
   source `pg03`, который видит `pg02`. `postgres_app_client_rules` в
   `group_vars/postgres.yml` вычисляется из публичных `ansible_host` хостов
   `docker-prod-01` и `docker-prod-02`; внешний Node.js/pgAdmin-сервер
   `95.163.209.96` добавлен туда литеральным `/32`, потому что он не
   управляется этим репозиторием. Если приложение выходит в интернет через
   отдельный NAT-адрес, замените соответствующее значение `from` на этот
   публичный `/32`. `postgres_listen_addresses` уже
   равен `0.0.0.0` для всех БД-хостов. Публичные адреса автоматически попадают в
   SAN сертификатов; для дополнительного DNS-имени используйте
   `postgres_tls_extra_sans`. Существующая реплика может переключиться с
   прежнего адреса на публичный без пересборки: роль допускает старый
   `ansible_host` в `primary_conninfo` и переписывает его на
   `postgres_replication_address`.
7. **Секреты** в зашифрованном `vault.yml` (см. ниже). Скопируйте
   `vault.yml.example`, заполните и зашифруйте. Роли проверяют, что ключевые
   пароли и SSH-ключи не остались заглушками `ChangeMe`/`ReplaceMe`.
   Для WAL-G задайте credentials VK Cloud (`vault_walg_s3_*`), credentials
   Yandex Cloud (`vault_walg_secondary_s3_*`) и общий
   `vault_walg_libsodium_key`. Роль хранит две копии бэкапов в bucket
   `s3://tlcamp-db-backup/...` в VK Cloud и Yandex Cloud; оба таргета
   обязательны. Для GitLab S3 задайте
   `vault_gitlab_backup_s3_access_key_id` и
   `vault_gitlab_backup_s3_secret_access_key`.
8. **Параметры Proxmox** в `provisioning/proxmox/vars.yml`:
   `proxmox_api_host`, `proxmox_node`, `proxmox_template`, `proxmox_storage`,
   `proxmox_bridge`, если используете provisioning.
9. **Размеры ВМ** в `provisioning/proxmox/vars.yml`, если используете
   provisioning. Размеры `pg03` и `docker-prod-02` задаются отдельно во
   втором облаке.
10. **TLS-сертификаты**: GitLab и Kibana получают сертификаты Let's Encrypt
    автоматически. Для отдельного `nginx01` по умолчанию создаётся
    self-signed сертификат; для production подготовьте
    `nginx_tls_mode: custom` и свои файлы.
11. **CA для приложений**: скопируйте `files/postgres-tls/ca.crt` на
    `docker-prod-02` (и другие app-хосты) и укажите его в приложении как
    `sslrootcert`. Без этого `sslmode=verify-full` не сможет проверить
    сертификат PostgreSQL. Приватный ключ `ca.key` на app-хосты не копируется.

> В `vmlist` перечислены роли ВМ, но нет ни сети, ни домена, ни размеров, ни
> гипервизора. Всё перечисленное выше — документированные допущения, а не
> факты о вашей инфраструктуре.

## Требования

### Контрольная машина (Ansible controller)

- Linux или macOS;
- Python 3.11+ (проверено на 3.12) и пакет `python3-venv`;
- `make`, `git`, OpenSSH client;
- сетевой доступ к ВМ по SSH и, при необходимости, к Proxmox API;
- установленные Python-пакеты и Ansible collections из
  `requirements.txt` / `requirements.yml`.

### Целевые ВМ

- Ubuntu 24.04 LTS (noble);
- пользователь `ubuntu` с `sudo` без пароля или с паролем, который знает
  Ansible;
- SSH-ключ пользователя `ubuntu` уже добавлен в `authorized_keys`;
- исходящий доступ к репозиториям Ubuntu, Docker, GitLab, Elastic и PGDG;
- синхронизированное время (роль `common` настраивает chrony);
- для `pg03`: публичный доступ к `pg02` на TCP `5432` и к репозиториям PGDG.
  Для приложений: публичный доступ к `pg01` на TCP `5432`; для `pg02`:
  публичный доступ к `pg01` на TCP `5432`. Все PostgreSQL-серверы принимают
  `:5432` только с публичных адресов `docker-prod-01`, `docker-prod-02`,
  внешнего app/pgAdmin-сервера `95.163.209.96` и непосредственных реплик.
  Внутренние сети не используются. Весь трафик PostgreSQL, включая клиентский,
  шифруется TLS с проверкой сертификата (`sslmode=verify-full`).

Роль `common` создаёт администратора `deploy`, устанавливает ему ключи из
vault и настраивает `sudo`. После первого bootstrap можно переключить
`ansible_user` на `deploy`, предварительно проверив вход.

Если `sudo` на целевых ВМ требует пароль, добавьте к запуску
`--ask-become-pass` (через Makefile:
`make site VAULT_ARGS="--ask-vault-pass --ask-become-pass"`).

### Proxmox VE (опционально)

Нужен только для `playbooks/proxmox-provision.yml`. Требуется:

- Proxmox VE 8+;
- шаблон Ubuntu 24.04 с cloud-init;
- учётная запись API с правами на клонирование, изменение конфигурации,
  управление питанием и выделение места в storage;
- установленный `proxmoxer` и `requests` на контроллере (есть в
  `requirements.txt`).

## Быстрый старт

```bash
git clone <repo-url> ansible
cd ansible

python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
```

То же самое можно сделать одной командой:

```bash
make deps
```

### 1. Создать и зашифровать vault

```bash
cp inventories/production/group_vars/all/vault.yml.example \
   inventories/production/group_vars/all/vault.yml
$EDITOR inventories/production/group_vars/all/vault.yml
ansible-vault encrypt inventories/production/group_vars/all/vault.yml
```

Пароль vault сохраните в менеджере секретов. Для неинтерактивных запусков
можно использовать файл пароля (он уже в `.gitignore`):

```bash
printf '%s' 'ВАШ_ПАРОЛЬ_VAULT' > .vault_pass
chmod 600 .vault_pass
export ANSIBLE_VAULT_PASSWORD_FILE="$PWD/.vault_pass"
```

Либо передавайте `--ask-vault-pass` при каждом запуске.

### 2. Заполнить inventory и переменные

```bash
$EDITOR inventories/production/hosts.yml
$EDITOR inventories/production/group_vars/all/main.yml             # SSH/fail2ban
$EDITOR inventories/production/group_vars/postgres.yml             # public app CIDRs
$EDITOR inventories/production/group_vars/postgres_cascading.yml   # pg03 public source
$EDITOR inventories/production/host_vars/pg01.yml                  # public primary endpoint
$EDITOR inventories/production/host_vars/pg02.yml                  # public pg02 endpoint
$EDITOR inventories/production/host_vars/pg03.yml                  # public pg03 endpoint
$EDITOR provisioning/proxmox/vars.yml   # только если используете Proxmox
```

Все `203.0.113.x` — placeholder-адреса; замените их на реальные публичные IP.
Проверьте, что IP ВМ из Proxmox (если provisioning используется) совпадают с
inventory и домен заменён на реальный. Отдельной приватной сети для
PostgreSQL или других сервисов нет.

### 3. Проверить SSH

```bash
ansible all -m ansible.builtin.ping --ask-vault-pass
```

Если используется `ANSIBLE_VAULT_PASSWORD_FILE`, флаг не нужен:

```bash
ansible all -m ansible.builtin.ping
```

### 4. Bootstrap

```bash
ansible-playbook playbooks/bootstrap.yml --ask-vault-pass
```

Bootstrap ставит базовые пакеты, создаёт `deploy`, устанавливает SSH-ключи,
включает UFW, fail2ban, chrony и unattended-upgrades. SSH открыт с любых
адресов, поэтому **до запуска убедитесь, что SSH-ключ из vault рабочий**:
пароли отключены, а fail2ban начнёт банить перебор. Для аварийного доступа
держите консоль гипервизора/облака.

### 5. Полное развёртывание

```bash
ansible-playbook playbooks/site.yml --ask-vault-pass
```

`site.yml` импортирует bootstrap и все сервисные playbook-и в правильном
порядке: bootstrap → PostgreSQL/Valkey → GitLab → Docker → ELK → Filebeat →
nginx → maintenance.

### 6. Проверка

```bash
ansible-playbook playbooks/verify.yml --ask-vault-pass
```

Либо через `make`:

```bash
make site VAULT_ARGS=--ask-vault-pass
make verify VAULT_ARGS=--ask-vault-pass
```

### Основные команды Makefile

| Команда | Действие |
|---|---|
| `make deps` | venv, Python-пакеты, collections |
| `make lint` | `yamllint` + `ansible-lint` |
| `make syntax` | syntax-check всех playbook-ов |
| `make inventory` | граф inventory |
| `make ping` | SSH-доступность всех хостов |
| `make check` | dry-run `site.yml` (`--check --diff`) |
| `make provision` | опциональное создание/обновление ВМ в Proxmox (не входит в `site`) |
| `make bootstrap` | базовый bootstrap |
| `make site` | полное развёртывание |
| `make verify` | post-deploy проверки |
| `make verify-postgres` | только PostgreSQL: репликация, TLS и WAL-G |
| `make gitlab`, `make postgres`, `make postgres-tls`, `make docker`, `make elk`, `make filebeat`, `make nginx`, `make maintenance` | отдельный сервис |
| `make vault-edit` | редактирование vault |
| `make clean` | удалить venv и локальный кэш |

Для команд, которым нужен vault, передавайте
`VAULT_ARGS=--ask-vault-pass` или экспортируйте
`ANSIBLE_VAULT_PASSWORD_FILE`.

## Секреты и Ansible Vault

`inventories/production/group_vars/all/vault.yml` автоматически подхватывается
Ansible как group vars для всех хостов. Файл зашифрован и исключён из Git.
В репозитории есть только `vault.yml.example` с заглушками.

Обязательные переменные:

| Переменная | Назначение |
|---|---|
| `vault_admin_authorized_keys` | список публичных SSH-ключей для `deploy` |
| `vault_gitlab_root_password` | начальный пароль `root` в GitLab |
| `vault_gitlab_smtp_password` | пароль SMTP (если включён) |
| `vault_postgres_replication_password` | пароль пользователя `replicator` |
| `vault_postgres_app_password` | пример пароля прикладного пользователя |
| `vault_postgres_admin_password` | пароль административной роли `dbadmin` для pgAdmin |
| `vault_walg_s3_access_key_id` | access key для WAL-G в VK Cloud (primary) |
| `vault_walg_s3_secret_access_key` | secret key для WAL-G в VK Cloud |
| `vault_walg_libsodium_key` | 64 hex-символа для шифрования WAL-G (общий ключ обеих копий) |
| `vault_walg_secondary_s3_access_key_id` | access key для WAL-G в Yandex Cloud (secondary) |
| `vault_walg_secondary_s3_secret_access_key` | secret key для WAL-G в Yandex Cloud |
| `vault_valkey_password` | `requirepass` для Valkey |
| `vault_elastic_password` | пароль суперпользователя `elastic` |
| `vault_kibana_system_password` | пароль `kibana_system` |
| `vault_logstash_internal_password` | пароль `logstash_internal` |
| `vault_rclone_s3_endpoint` | S3-совместимый endpoint |
| `vault_rclone_s3_access_key_id` | access key для rclone |
| `vault_rclone_s3_secret_access_key` | secret key для rclone |
| `vault_proxmox_api_password` | пароль API Proxmox (если нужен provisioning) |

Рекомендации по генерации:

```bash
openssl rand -hex 24     # для PostgreSQL replication: без ':' и '\'
openssl rand -base64 24  # для остальных паролей
openssl rand -hex 32     # для vault_walg_libsodium_key (64 hex-символа)
```

Для `vault_postgres_replication_password` лучше использовать hex или другой
алфавит без `:`, `\` и переводов строк: пароль попадает в `.pgpass` на
репликах. Пароли Elastic и Valkey могут содержать большинство спецсимволов,
шаблоны экранируют их при подстановке.

Полезные команды:

```bash
ansible-vault view   inventories/production/group_vars/all/vault.yml
ansible-vault edit   inventories/production/group_vars/all/vault.yml
ansible-vault rekey  inventories/production/group_vars/all/vault.yml
```

Не коммитьте `vault.yml`, `.vault_pass` и файлы с расшифрованными секретами.
`.gitignore` уже это запрещает, но проверяйте `git status` перед коммитом.

### Смена паролей после развёртывания

- **GitLab root**: смените пароль в UI после первого входа. Значение
  `initial_root_password` в `gitlab.rb` предназначено для начальной
  инициализации; после смены пароля обновите vault или уберите переменную.
- **PostgreSQL replication**: обновите vault, запустите
  `ansible-playbook playbooks/postgres.yml --ask-vault-pass`. Роль обновит
  пользователя на primary и `.pgpass` на репликах; для применения нового
  пароля может потребоваться перезапуск PostgreSQL на репликах.
- **Valkey**: обновите vault и запустите `playbooks/postgres.yml` (Valkey
  входит в этот playbook) или `--tags valkey`.
- **Elastic Stack**: обновите vault и запустите `playbooks/elk.yml`.
  Роль проверит `kibana_system` и `logstash_internal` и перезапустит сервисы
  только при необходимости.

## Inventory

`inventories/production/hosts.yml` — единственный источник адресов для
Ansible. Группы:

```text
all
├── gitlab                 gitlab01
├── postgres
│   ├── postgres_primary    pg01
│   ├── postgres_replicas   pg02, pg03
│   └── postgres_cascading  pg03
├── valkey                 pg01
├── docker
│   ├── docker_prod        docker-prod-01, docker-prod-02
│   └── docker_test        docker-test-01
├── elk                    elk01
├── nginx                  nginx01
├── maintenance            maint01
└── log_shippers           gitlab, postgres, docker, nginx, maintenance
```

`pg01` одновременно входит в `postgres_primary` и `valkey`. Его
`host_vars/pg01.yml` задаёт правила UFW для PostgreSQL и Valkey, чтобы
group vars одного сервиса не перекрывали другой.

`pg03` входит в `postgres_replicas` (общие настройки реплики) и в
`postgres_cascading`. Отдельная группа позволяет запускать каскадные реплики
только после `pg02`. `host_vars/pg02.yml` содержит публичный адрес `pg02` и
правило UFW для `pg03`, а `group_vars/postgres_cascading.yml` — публичный
source CIDR `pg03`.

`docker-prod-02` находится во втором облаке; его публичный адрес используется
и для Ansible, и для source-правил PostgreSQL. Если у хоста отдельный
NAT-egress, переопределите `from` в `postgres_app_client_rules`. Все
Docker-хосты и внешний app-сервер подключаются к PostgreSQL через
публичный/NAT-адрес; для PostgreSQL приватная сеть не используется.

`log_shippers` — группа-агрегатор: она включает все хосты, кроме `elk01`.
Filebeat ставится на 9 машин; `elk01` хранит логи локально.

### Топология PostgreSQL

| Переменная | Где задаётся | Назначение |
|---|---|---|
| `postgres_replication_topology` | `group_vars/postgres.yml` | карта `реплика: upstream`; сейчас `pg02: pg01`, `pg03: pg02` |
| `postgres_app_client_rules` | `group_vars/postgres.yml` | публичные source CIDR приложений (Docker prod-хосты и внешний `95.163.209.96`); UFW на всех PG-серверах |
| `postgres_client_networks` | `group_vars/postgres.yml` | вычисляется из `postgres_app_client_rules`; `hostssl`-правила приложений на всех PG-серверах |
| `postgres_replication_address` | `host_vars/pg01.yml`, `host_vars/pg02.yml`, `host_vars/pg03.yml` | публичный адрес, по которому приложения и реплики подключаются к хосту; входит в SAN |
| `postgres_replication_source_cidr` | `host_vars/pg02.yml`, `group_vars/postgres_cascading.yml` | публичный source CIDR, который видит upstream; используется в `pg_hba` и UFW |
| `postgres_listen_addresses` | `group_vars/postgres.yml` | `0.0.0.0` на всех БД-хостах; доступ ограничен UFW и `pg_hba` |
| `postgres_tls_enabled` | `group_vars/postgres.yml` | включает TLS для сервера, приложений и репликации; по умолчанию `true` |
| `postgres_replication_sslmode` | `group_vars/postgres.yml` | режим проверки сертификата upstream; по умолчанию `verify-full` |
| `postgres_tls_cert_not_after` | `roles/postgres/defaults/main.yml` | срок серверного сертификата, 10 лет (`+3650d`) |
| `postgres_tls_ca_not_after` | `roles/postgres/defaults/main.yml` | срок CA, 20 лет (`+7300d`) |
| `postgres_tls_local_dir` | `roles/postgres/defaults/main.yml` | каталог CA и сертификатов на контроллере; по умолчанию `files/postgres-tls/` |
| `postgres_tls_extra_sans` | host/group vars | дополнительные SAN, например `DNS:pg02.db.example.com` |

`postgres_replication_topology` — единственное место, где описана форма
каскада. Роль вычисляет по нему downstream-реплики для слотов и `pg_hba`.
Реплики, которых нет в карте, по умолчанию подключаются напрямую к primary.

### Добавление хоста

1. Добавьте хост в `hosts.yml` в нужную группу (или создайте группу).
2. Укажите `ansible_host`.
3. Добавьте group vars, если сервис требует настроек.
4. Проверьте `ansible-inventory --graph` и `--host <name>`.
5. Запустите playbook с `--limit <name>`.

Не создавайте одновременно `group_vars/<group>.yml` и каталог
`group_vars/<group>/`: Ansible выбирает что-то одно, и переменные из файла
могут «потеряться». Используйте либо файл, либо каталог.

### Внешние клиенты PostgreSQL

Хост, который не управляется репозиторием (например, Node.js-приложение и
pgAdmin на `95.163.209.96`), не добавляется в `hosts.yml`: иначе Ansible
начнёт пытаться подключиться к нему и включит его в `log_shippers`. Вместо
этого добавьте его публичный source-адрес в `postgres_app_client_rules`
(`group_vars/postgres.yml`). Сейчас там уже есть правило `95.163.209.96/32`;
оно попадает и в UFW, и в `pg_hba.conf` на `pg01`, `pg02` и `pg03`.

Применить изменения:

```bash
.venv/bin/ansible-playbook playbooks/site.yml \
  --limit pg01,pg02,pg03 --tags common,postgres \
  --vault-password-file .vault_pass
```

Вместо `--vault-password-file .vault_pass` можно один раз выполнить
`export ANSIBLE_VAULT_PASSWORD_FILE="$PWD/.vault_pass"` или указать
`--ask-vault-pass`, если пароль нужно ввести вручную.

Команда обновит UFW (роль `common`) и `pg_hba.conf` (роль `postgres`), не
запуская остальные сервисы. Если нужно обновить только firewall или только
`pg_hba`, запустите `playbooks/bootstrap.yml` или `playbooks/postgres.yml` с
тем же `--limit`.

На внешний хост копируется только публичный CA, без `ca.key`:

```bash
scp files/postgres-tls/ca.crt \
  root@95.163.209.96:/etc/ssl/certs/postgres-ca.crt
```

Если приложение и pgAdmin запущены в Docker на этом же хосте, отдельное
правило для контейнеров не нужно: исходящие подключения из стандартной
bridge-сети Docker проходят через SNAT, и PostgreSQL видит адрес хоста
`95.163.209.96`. Правило придётся расширить, только если контейнеры
используют macvlan/ipvlan со своими публичными IP или выходят через
отдельный VPN/NAT. Внутренние адреса Docker (`172.17.0.0/16` и т.п.) в
`pg_hba.conf` добавлять не нужно.

CA нужно смонтировать внутрь контейнеров, например:

```yaml
services:
  app:
    volumes:
      - /etc/ssl/certs/postgres-ca.crt:/etc/ssl/certs/postgres-ca.crt:ro
  pgadmin:
    volumes:
      - /etc/ssl/certs/postgres-ca.crt:/etc/ssl/certs/postgres-ca.crt:ro
```

В pgAdmin root certificate указывается как путь **внутри контейнера** —
`/etc/ssl/certs/postgres-ca.crt`. Браузер, с которого открыт pgAdmin, к
PostgreSQL не подключается: соединение устанавливает контейнер pgAdmin.

#### Права на создание БД и ролей

В конфигурации есть отдельная административная роль `dbadmin` с правами
`LOGIN,CREATEDB,CREATEROLE`. Она также является членом `testuser`, поэтому
может создавать объекты и выдавать права в существующей БД `testdb`.
Пароль роли хранится в vault (`vault_postgres_admin_password`).

`dbadmin` может:

- создавать базы данных (`CREATE DATABASE`);
- создавать пользователей и роли (`CREATE ROLE`), задавать им пароли;
- выдавать привилегии на базы, которыми владеет, и на объекты `testdb`
  через членство в `testuser`.

Ограничения:

- `dbadmin` не является суперпользователем и не может создавать роли с
  `SUPERUSER`, `REPLICATION` или `BYPASSRLS`;
- в PostgreSQL 16+ `CREATEROLE` позволяет управлять только ролями, на
  которые у роли есть `ADMIN OPTION`; на созданные ей роли это право
  выдаётся автоматически;
- полные права на любые объекты кластера остаются только у локального
  `postgres` (`sudo -u postgres psql` на БД-хосте).

`testuser` по-прежнему имеет только `LOGIN` и остаётся владельцем `testdb`;
использовать его для администрирования из pgAdmin не нужно.

Параметры подключения к primary (`pg01`):

- host — `postgres_replication_address` из `host_vars/pg01.yml`;
- port — `5432`;
- для приложения — БД и роль из `postgres_databases` / `postgres_users`
  (`testdb` / `testuser`); для pgAdmin — `dbadmin` (может подключаться к
  `testdb` и создавать новые БД);
- `sslmode=verify-full`, `sslrootcert=/etc/ssl/certs/postgres-ca.crt`.

Запись возможна только на `pg01`; `pg02` и `pg03` — read-only реплики, но
принимают те же прикладные подключения.

Пример для `psql`:

```bash
psql "host=<pg01-public-ip> port=5432 dbname=testdb user=testuser \
  sslmode=verify-full sslrootcert=/etc/ssl/certs/postgres-ca.crt"
```

Эквивалент для Node.js (`pg`):

```js
const fs = require('fs');
const { Client } = require('pg');

const client = new Client({
  host: '<pg01-public-ip>',
  port: 5432,
  database: 'testdb',
  user: 'testuser',
  password: process.env.PGPASSWORD,
  ssl: {
    ca: fs.readFileSync('/etc/ssl/certs/postgres-ca.crt'),
    rejectUnauthorized: true,
  },
});
```

В pgAdmin укажите тот же host и порт, пользователя `dbadmin`, SSL mode —
`verify-full`, root certificate — `/etc/ssl/certs/postgres-ca.crt`. Пароль
`dbadmin` хранится в vault (`vault_postgres_admin_password`).

### Основные переменные

`inventories/production/group_vars/all/main.yml`:

| Переменная | Значение по умолчанию | Комментарий |
|---|---|---|
| `internal_domain` | `campbox.tech` | заменить |
| `gitlab_hostname` | `gitlab-test.<domain>` | внешнее имя GitLab |
| `kibana_hostname` | `elastik.<domain>` | внешнее имя Kibana |
| `ansible_user` | `ubuntu` | начальный SSH-пользователь |
| `common_timezone` | `Europe/Moscow` | |
| `common_firewall_ssh_sources` | `0.0.0.0/0`, `::/0` | SSH со всех адресов |
| `common_fail2ban_ignoreips` | `[]` | нет admin/CI whitelist; loopback игнорируется |
| `common_admin_user` | `deploy` | создаётся ролью `common` |
| `common_admin_sudo_nopasswd` | `true` | при необходимости ужесточить |
| `local_backup_keep_days` | `7` | локальное хранение GitLab backup-ов |

## Provisioning в Proxmox VE

Playbook `playbooks/proxmox-provision.yml` создаёт ВМ из cloud-init-шаблона.
Он **не запускается по умолчанию** и не входит в `site.yml`; используйте
`make provision` только если действительно создаёте ВМ в Proxmox. Если ВМ уже
существуют, переходите сразу к `site.yml`. Адреса в примере ниже — публичные
placeholder-адреса.

### Настройка

`provisioning/proxmox/vars.yml`:

```yaml
proxmox_api_host: "pve.example.com"
proxmox_api_user: "ansible@pve"
proxmox_api_password: "{{ vault_proxmox_api_password }}"
proxmox_validate_certs: true

proxmox_node: "pve01"
proxmox_template: "ubuntu-2404-cloudinit-template"
proxmox_storage: "local-lvm"
proxmox_bridge: "vmbr0"
proxmox_gateway: "203.0.113.1"
proxmox_nameservers:
  - "203.0.113.1"
  - "1.1.1.1"
```

Далее — список `proxmox_vms` с `name`, `vmid`, `cores`, `memory`, `disk`,
`ip`. IP перечисленных ВМ должны совпадать с inventory.

`pg03` и `docker-prod-02` намеренно отсутствуют в `proxmox_vms`: они
находятся во втором облаке и создаются средствами этого облака. Добавьте их
в inventory и подготовьте SSH-доступ, но не пытайтесь создать их этим
playbook-ом.

Требования к шаблону:

- Ubuntu 24.04;
- установлен и включён `qemu-guest-agent`;
- есть cloud-init drive;
- системный диск подключён как `virtio0` (или измените
  `proxmox_disk_interface` в `roles/proxmox_vm/defaults/main.yml`);
- в шаблоне не должно быть конфликтующих сетевых настроек.

### Запуск

```bash
ansible-playbook playbooks/proxmox-provision.yml --ask-vault-pass
```

Роль:

1. клонирует шаблон в ВМ с указанным `vmid`;
2. задаёт CPU, RAM, cloud-init (IP, gateway, DNS, SSH-ключи);
3. обновляет ресурсы при повторном запуске;
4. увеличивает диск до `disk`, если текущий размер меньше;
5. запускает ВМ и ждёт SSH на `:22`.

Если ВМ с таким `vmid` уже существует, клонирование пропускается; роль
обновляет ресурсы. Уменьшить диск нельзя. Если шаблон уже больше нужного
размера, установите `resize_disk: false` для этой ВМ. Если SSH на новых ВМ
недоступен с контроллера (например, из-за маршрутизации), установите
`wait_for_ssh: false` и проверьте доступность вручную.

Порт `:22` может открыться раньше, чем cloud-init завершит настройку ключей.
Перед первым `site.yml` дождитесь cloud-init на новых ВМ:

```bash
ansible all -m ansible.builtin.command -a "cloud-init status --wait"
```

Для production лучше использовать отдельного пользователя Proxmox с
минимальными правами и API-token вместо пароля. Текущая реализация
поддерживает пароль; API-token можно добавить, заменив
`proxmox_api_password` на `proxmox_api_token_id`/`proxmox_api_token_secret`
и соответствующие аргументы модулей.

## Playbook-и и теги

| Playbook | Хосты | Назначение |
|---|---|---|
| `bootstrap.yml` | `all` | базовые пакеты, пользователи, SSH, UFW, NTP, fail2ban |
| `site.yml` | `all` | полный стек, импортирует остальные playbook-и |
| `postgres.yml` | `postgres_primary`, `postgres_replicas`, `postgres_cascading`, `valkey` | PostgreSQL 18: primary, реплика первого уровня и каскадная реплика + Valkey |
| `gitlab.yml` | `gitlab` | GitLab CE + backup timer |
| `docker.yml` | `docker_prod`, `docker_test` | Docker Engine, daemon.json, prune timer |
| `elk.yml` | `elk` | Elasticsearch, Logstash, Kibana, security |
| `filebeat.yml` | `log_shippers` | Filebeat |
| `nginx.yml` | `nginx` | TLS, reverse proxy для GitLab и Kibana |
| `maintenance.yml` | `maintenance` | rclone, systemd timers |
| `verify.yml` | `all`, `postgres`, `nginx` | smoke-проверки, включая каскадную репликацию |
| `proxmox-provision.yml` | `localhost` | создание/обновление ВМ |

### Теги

Теги позволяют запускать часть ролей:

```bash
# Только PostgreSQL и Valkey
ansible-playbook playbooks/site.yml --tags postgres,valkey --ask-vault-pass

# Только проверка и перевыпуск TLS-сертификатов PostgreSQL
ansible-playbook playbooks/postgres.yml --tags postgres_tls --ask-vault-pass

# Всё, кроме Docker
ansible-playbook playbooks/site.yml --skip-tags docker --ask-vault-pass

# Только GitLab на одном хосте
ansible-playbook playbooks/site.yml --tags gitlab --limit gitlab01 --ask-vault-pass

# Проверить конфигурацию без изменений
ansible-playbook playbooks/site.yml --check --diff --ask-vault-pass
```

Основные теги: `common`, `bootstrap`, `postgres`, `postgres_tls`,
`postgres_primary`, `postgres_replica`, `postgres_cascading`, `valkey`,
`gitlab`, `docker`, `docker_prod`, `docker_test`, `elk`, `logging`,
`filebeat`, `nginx`, `maintenance`, `rclone`, `provision`, `proxmox`.

`site.yml` запускает bootstrap первым, поэтому на свежих ВМ достаточно одной
команды. Если нужен только bootstrap, запускайте `bootstrap.yml` отдельно.

## Что настраивается

### common (все хосты)

- пакеты: `curl`, `jq`, `chrony`, `fail2ban`, `ufw`, `unattended-upgrades`,
  `qemu-guest-agent`, `rsyslog`, `logrotate` и др.;
- пользователь `deploy`, группа `sudo`, SSH-ключи из vault;
- SSH hardening: только ключи, `PermitRootLogin prohibit-password`,
  ограничение попыток, drop-in `00-ansible-hardening.conf`;
- UFW: входящие по умолчанию запрещены, SSH — с любых IPv4/IPv6-адресов
  (`0.0.0.0/0`, `::/0`), сервисные порты — только из group vars;
- fail2ban для SSH без whitelist (кроме loopback);
- chrony + отключение `systemd-timesyncd`;
- journald, лимиты `nofile`, sysctl;
- `/etc/hosts` со всеми хостами кластера;
- unattended-upgrades.

### PostgreSQL 18

- PGDG-репозиторий, пакеты `postgresql-18` и `postgresql-client-18`;
- кластер `main`, конфигурация в `/etc/postgresql/18/main`, данные в
  `/var/lib/postgresql/18/main`;
- настройки в `conf.d/99-ansible.conf`: `listen_addresses`, память,
  `wal_level`, `max_wal_senders`, `max_replication_slots`, `hot_standby`,
  WAL, слоты, логирование;
- `pg_hba.conf`: peer для локальных; для приложений и реплик — только
  публичные `hostssl`-правила со SCRAM; незашифрованные TCP-подключения
  приложений и репликации отклоняются;
- пользователь `replicator` с правом `REPLICATION` создаётся на primary и
  попадает на реплики вместе с базовой копией;
- топология задаётся картой `postgres_replication_topology`:
  `pg01` → `pg02` → `pg03`;
- physical slots создаются на непосредственном upstream:
  `replica_pg02` на `pg01`, `replica_pg03` на `pg02`;
- `pg02` — одновременно standby и upstream для `pg03`. Поэтому на нём
  включены `max_wal_senders`, `max_replication_slots` и `hot_standby`;
  `pg_hba.conf` и UFW разрешают `:5432` с публичных адресов приложений и
  `pg03`, но не с других адресов;
- приложения подключаются к публичному `postgres_replication_address` из
  `host_vars/pg01.yml`; `pg02` подключается к публичному адресу `pg01`, а
  `pg03` — к публичному адресу `pg02`. `pg02` и `pg03` также принимают
  приложения с трёх app-хостов, но не являются точкой входа по умолчанию.
  Все адреса публичные, отдельной приватной сети нет;
- весь трафик PostgreSQL защищён TLS: на контроллере создаётся приватный CA
  (`files/postgres-tls/`), для каждого PostgreSQL-хоста выпускается
  серверный сертификат. SAN включает inventory hostname, `ansible_host`,
  `postgres_replication_address` и адрес интерфейса. Приложения и реплики
  подключаются с `sslmode=verify-full` и проверяют сервер по CA. Приватный
  ключ CA остаётся на контроллере, на БД-хосты копируются только
  CA-сертификат и собственный ключ хоста;
- `max_slot_wal_keep_size = 10GB`: если downstream-реплика долго недоступна,
  слот инвалидируется вместо бесконечного накопления WAL на upstream
  (реплику после этого нужно пересобрать);
- реплики: `pg_basebackup` при первом запуске или при
  `postgres_replica_rebuild: true`, затем streaming replication;
  `pg02` копируется с `pg01`, `pg03` — с `pg02`;
- прикладные пользователи, базы и привилегии задаются списками
  `postgres_users`, `postgres_databases`, `postgres_privileges` в
  `group_vars/postgres.yml` (по умолчанию пусты);
- физические бэкапы WAL-G на primary: WAL-архив и base backup в **два
  независимых S3**, шифрование libsodium, `zstd`; weekly full (`Sun 02:00`)
  + daily diff (`03:00`), хранение 4 full-бэкапов в каждом S3. Каждый
  WAL-сегмент отправляется в оба S3 через `/usr/local/sbin/walg-archive`,
  а base backup копируется во второй S3 через `wal-g copy`. Реплики не
  архивируют WAL;
- скрипты и таймеры: `/usr/local/sbin/walg-backup`,
  `wal-g-full.timer`, `wal-g-diff.timer`; конфигурация —
  `/etc/wal-g/config.json` и `/etc/wal-g/config-secondary.json`, ключ —
  `/etc/wal-g/libsodium-v1.hex`.

Межоблачная репликация асинхронная: задержка зависит от RTT и пропускной
способности канала. Слот `replica_pg03` на `pg02` удерживает WAL для `pg03`;
следите за `pg_replication_slots` и свободным местом. Если `pg02` пересобрать,
его слот для `pg03` будет потерян, а `pg03` может отстать настолько, что её
тоже придётся пересобрать.

Пример прикладной БД:

```yaml
postgres_users:
  - name: app
    password: "{{ vault_postgres_app_password }}"
    role_attr_flags: "LOGIN"
postgres_databases:
  - name: app
    owner: app
    encoding: "UTF-8"
postgres_privileges:
  - db: app
    role: app
    privs: ALL
    type: database
```

Пересборка реплик:

`postgres_replica_rebuild: true` удаляет data directory реплики и заново
копирует её с upstream. **Пересборка удаляет данные реплики.** Флаг в
`group_vars/postgres_replicas.yml` действует на обе реплики, поэтому для
точечной операции используйте `--limit` или host vars.

На свежей ВМ установка пакета уже создаёт пустой кластер `main`. Роль
распознаёт его (нет `standby.signal` и `primary_conninfo`) и автоматически
делает basebackup; явный флаг для первого запуска не нужен.

#### Пересборка pg02 и зависимой pg03

При пересборке `pg02` исчезает слот `replica_pg03`, а `pg03` может отстать
настолько, что не сможет продолжить с прежней точки WAL. Пересобирайте обе
реплики; playbook выполняет `pg02` раньше `pg03`, поэтому слот успевает
создаться.

```yaml
# inventories/production/group_vars/postgres_replicas.yml
postgres_replica_rebuild: true
```

```bash
ansible-playbook playbooks/postgres.yml --limit pg01,pg02,pg03 --ask-vault-pass
```

#### Пересборка только pg03

`pg02` должен оставаться рабочим. Убедитесь, что слот `replica_pg03`
существует на `pg02`, и включите флаг только для `pg03`:

```yaml
# inventories/production/host_vars/pg03.yml
postgres_replica_rebuild: true
```

```bash
ansible-playbook playbooks/postgres.yml --limit pg02,pg03 --ask-vault-pass
```

В этом запуске `pg02` применяет обычную конфигурацию и создаёт/сохраняет слот,
а `pg03` пересобирается. После успеха верните `false` в обоих местах, иначе
реплики будут пересоздаваться при каждом запуске.

Перед пересборкой проверьте слот на непосредственном upstream. Если он
инвалидирован (`wal_status = lost`), удалите его, иначе `pg_basebackup --slot`
завершится ошибкой:

```bash
# На pg01: слот для pg02
sudo -u postgres psql -c "SELECT slot_name, wal_status FROM pg_replication_slots;"
sudo -u postgres psql -c "SELECT pg_drop_replication_slot('replica_pg02');"

# На pg02: слот для pg03
sudo -u postgres psql -c "SELECT slot_name, wal_status FROM pg_replication_slots;"
sudo -u postgres psql -c "SELECT pg_drop_replication_slot('replica_pg03');"
```

Если на существующем data directory пропал `standby.signal` (например, реплику
повысили вручную), роль не станет перезаписывать данные автоматически:
запуск завершится ошибкой с требованием явно выставить
`postgres_replica_rebuild: true`. Это защита от случайной потери данных при
повторном запуске на повышенной реплике.

Роль также проверяет, что уже настроенная реплика смотрит на upstream из
`postgres_replication_topology` и использует ожидаемый physical slot. Если
топология изменилась, запуск завершится ошибкой: пересоберите реплику
(`postgres_replica_rebuild: true`) или обновите `primary_conninfo` и
`primary_slot_name` вручную и перезапустите PostgreSQL.

Репликация проверяется так:

```bash
# На pg01: должен быть pg02
sudo -u postgres psql -c "SELECT client_addr, application_name, state, sync_state FROM pg_stat_replication;"

# На pg02: должен быть pg03
sudo -u postgres psql -c "SELECT client_addr, application_name, state, sync_state FROM pg_stat_replication;"

# На pg02 и pg03: t; на pg03 — status = streaming
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
sudo -u postgres psql -c "SELECT status FROM pg_stat_wal_receiver;"

# Слоты на upstream
sudo -u postgres psql -c "SELECT slot_name, active, wal_status FROM pg_replication_slots;"
```

Автоматического failover нет. При потере `pg01` повышайте `pg02` вручную
(`pg_ctl promote` или выбранный инструмент); `pg03` может продолжить
репликацию с повышенного `pg02`. При потере `pg02` `pg03` **не**
переключается на `pg01` автоматически: восстановите `pg02` или вручную
перенастройте `pg03` на прямую репликацию с `pg01`, создайте для неё слот
на `pg01` и обновите `postgres_replication_topology` (`pg03: pg01` или
удалите `pg03` из карты). Иначе роль отклонит существующую реплику при
следующем запуске. Если `pg03` уже ушла вперёд по WAL, может потребоваться
пересборка. Не запускайте роль `postgres` на повышенной реплике без
изменения inventory и явного `postgres_replica_rebuild`: она защищает
data directory от перезаписи. Для production стоит рассмотреть Patroni/repmgr.

### Valkey

Valkey 7.2 устанавливается из репозитория Ubuntu 24.04 и работает на `pg01`
(совмещение с primary PostgreSQL — осознанное решение из `vmlist`).
Настраивается:

- пакеты `valkey-server`, `valkey-tools`;
- пароль `requirepass` из vault;
- bind на `127.0.0.1` и публичный IP;
- AOF `everysec`, RDB snapshots;
- UFW: порт `6379` только с публичных адресов `docker-prod-01` и
  `docker-test-01`; `docker-prod-02` во втором облаке не допускается без TLS;
- проверка `PING` с паролем.

`valkey_maxmemory` по умолчанию пуст (без лимита). Для кэша задайте,
например, `"2gb"` и политику `allkeys-lru`. Для очередей/данных, которые
нельзя терять, `noeviction` безопаснее, но запись может начать падать при
заполнении памяти. Учитывайте, что Valkey и PostgreSQL делят RAM одного
хоста.

### GitLab CE

- установка из официального репозитория GitLab;
- `external_url` = `https://gitlab-test.<domain>`;
- GitLab опубликован напрямую, без внешнего nginx: встроенный nginx слушает
  `:80`/`:443`, TLS-сертификат выпускается через Let's Encrypt;
- начальный пароль root из vault;
- ежедневный backup в `/var/opt/gitlab/backups` с копированием
  `gitlab.rb` и `gitlab-secrets.json`;
- backup автоматически выгружается в S3 VK Cloud (`tlcamp-gitlab-backup`)
  через rclone;
- SMTP по умолчанию выключен; включается переменными `gitlab_smtp_*`.

После первого запуска:

```bash
sudo gitlab-ctl status
sudo gitlab-ctl reconfigure
sudo cat /etc/gitlab/initial_root_password   # если файл ещё существует
```

Смените пароль root в UI. GitLab обновляется пакетом `gitlab-ce` до
последней версии; для production зафиксируйте версию и соблюдайте
официальный путь обновления (иначе можно пропустить обязательный шаг).

GitLab SSH для `git clone` работает напрямую на `gitlab01:22`, не через
nginx. Если разработчики подключаются из другой сети, добавьте правило UFW
для порта 22 (или отдельного GitLab Shell-порта) и настройте DNS.

### Docker

- Docker CE, CLI, containerd, buildx, compose plugin;
- `/etc/docker/daemon.json`: json-file, ротация `100m` × 5,
  `live-restore`;
- каталог приложений `/srv/docker`;
- пользователь `deploy` в группе `docker`;
- еженедельный `docker system prune` (таймер systemd);
- проверка `docker info`.

Приложения и compose-файлы не деплоятся. Размещайте их в `/srv/docker` и
открывайте нужные порты через `firewall_extra_rules` в
`host_vars`/`group_vars`.

> **Важно про Docker и UFW.** Docker управляет правилами iptables
> самостоятельно, поэтому порты, опубликованные контейнером через `-p`/
> `ports:`, могут обходить UFW. Не публикуйте порты на `0.0.0.0` без
> необходимости: привязывайте их к `127.0.0.1` или конкретному публичному
> адресу, используйте reverse proxy и отдельно проверяйте
> `iptables -L DOCKER-USER`.
> Для строгой фильтрации добавьте `ufw-docker` или настройте `DOCKER-USER`
> вручную.

### Elastic Stack 9.x

- Elasticsearch, Kibana, Logstash из репозитория Elastic 9.x;
- single-node Elasticsearch, security enabled, HTTP TLS выключен, потому что
  Elasticsearch слушает только `127.0.0.1`;
- Kibana опубликована напрямую на `:443` (`https://elastik.<domain>`),
  TLS-сертификат выпускается через certbot/Let's Encrypt;
- heap Elasticsearch и Logstash ограничен под 4 ГБ RAM тестовой ВМ;
- Logstash beats input `0.0.0.0:5044`, firewall разрешает только публичные
  адреса хостов группы `log_shippers`;
- роли/пользователи `kibana_system`, `logstash_internal`, `logstash_writer`;
- Filebeat на остальных хостах отправляет логи в Logstash.

Проверка:

```bash
curl -u elastic 'http://127.0.0.1:9200/_cluster/health?pretty'
curl -u elastic 'http://127.0.0.1:9200/_cat/indices?v'
```

Пароль `elastic` задаётся через vault. При первом запуске роль сбрасывает
временный пароль через `elasticsearch-reset-password`, затем устанавливает
значение из vault. Index pattern и dashboards автоматически не создаются:
после первого запуска создайте в Kibana index pattern `filebeat-*` (или
`logs-*`, если будете менять pipeline).

### nginx

Роль `nginx` остаётся в репозитории для отдельного хоста `nginx01`, но
**не используется** для публикации GitLab и Kibana: они подключены к
интернету напрямую.

- TLS-терминация и reverse proxy для задач, которые явно размещены на
  `nginx01`;
- HTTP → HTTPS redirect;
- self-signed сертификат по умолчанию;
- поддержка custom-сертификата;
- `client_max_body_size 0` для загрузки больших файлов.

## TLS и DNS

Публичные сервисы используют DNS-имена, которые указывают на сами ВМ:

| Имя | IP | TLS |
|---|---|---|
| `gitlab-test.campbox.tech` | `gitlab01` | встроенный nginx GitLab + Let's Encrypt |
| `elastik.campbox.tech` | `elk01` | Kibana `:443` + certbot/Let's Encrypt |

GitLab выпускает сертификат при `gitlab-ctl reconfigure`
(`gitlab_letsencrypt_enable: true`). Kibana получает сертификат через
`certbot certonly --standalone`; таймер `certbot.timer` продлевает его, а
deploy-hook копирует файлы в `/etc/kibana/certs` и перезапускает Kibana.
Порты `80` и `443` должны быть открыты в UFW и в firewall облака.

Для отдельного `nginx01` по-прежнему доступен `nginx_tls_mode: "selfsigned"`
или `custom`:

```yaml
# inventories/production/group_vars/nginx.yml
nginx_tls_mode: "custom"
nginx_tls_cert_src: "/path/on/controller/fullchain.pem"
nginx_tls_key_src: "/path/on/controller/privkey.pem"
```

Файлы должны быть доступны на контроллере. Не коммитьте приватные ключи:
`.gitignore` уже исключает `*.key`, `*.pem`, `*.p12` и `*.pfx`.
После изменения запустите:

```bash
ansible-playbook playbooks/nginx.yml --ask-vault-pass
```

### TLS PostgreSQL

TLS для PostgreSQL включается вместе с ролью `postgres`. На контроллере
создаётся приватный CA и сертификаты в `files/postgres-tls/`:

- `ca.key`, `ca.csr`, `ca.crt` — корневой CA (20 лет);
- `<host>.key`, `<host>.csr`, `<host>.crt` — серверный сертификат каждого
  хоста (10 лет).

На хостах файлы лежат в `/etc/postgresql/18/main/tls/`; `postgresql.conf`
включает `ssl = on`, а `pg_hba.conf` использует `hostssl` и для приложений,
и для репликации. `pg_basebackup` и WAL receiver подключаются с
`sslmode=verify-full`, поэтому сертификат каждого хоста должен содержать его
публичный адрес из `postgres_replication_address`. Он добавляется в SAN
автоматически. Приложение должно использовать `sslmode=verify-full` и
`sslrootcert=/path/to/ca.crt`; CA-сертификат — публичный, его можно копировать
на app-хосты и монтировать в контейнеры. Приватный ключ CA не копируется.

Пример подключения приложения:

```bash
psql "host=203.0.113.12 port=5432 dbname=app user=app \
  sslmode=verify-full sslrootcert=/etc/ssl/certs/postgres-ca.crt"
```

Проверка на upstream:

```bash
sudo -u postgres psql -c "SHOW ssl;"
sudo -u postgres psql -c "
SELECT r.application_name, r.client_addr, s.ssl, s.version, s.cipher
FROM pg_stat_replication r
JOIN pg_stat_ssl s ON s.pid = r.pid;"
```

Проверка сертификата:

```bash
sudo -u postgres openssl x509 \
  -in /etc/postgresql/18/main/tls/server.crt \
  -noout -subject -issuer -dates -ext subjectAltName
```

`files/postgres-tls/ca.key` — критичный секрет. Сохраните его в защищённом
месте: без него нельзя выпустить новые сертификаты, которым доверяют уже
развёрнутые хосты. Серверные сертификаты действуют 10 лет, CA — 20 лет. Роль
проверяет срок при каждом запуске и перевыпускает сертификат за 30 дней до
истечения. Дополнительно role хранит локальные policy-маркеры: после изменения
срока действия или key size сертификаты перевыпускаются сразу, не дожидаясь
старого срока.

**Автоперевыпуск не является фоновым демоном.** Проверка выполняется только
при запуске роли. Запускайте её по расписанию (например, еженедельно) через
cron, AWX или GitLab CI. Для обновления только TLS используйте:

```bash
make postgres-tls VAULT_ARGS=--ask-vault-pass
# или
ansible-playbook playbooks/postgres.yml --tags postgres_tls --ask-vault-pass
```

`make postgres-tls` рассчитан на уже настроенные хосты: он обновляет
сертификаты и перезапускает PostgreSQL, но не выполняет первоначальную
настройку `ssl_cert_file`/`ssl_key_file`. При первом включении TLS запускайте
полный `make postgres`.

Пример cron-задания с неинтерактивным vault-паролем:

```cron
0 4 * * 1 cd /opt/ansible && \
  ANSIBLE_VAULT_PASSWORD_FILE=/etc/ansible/.vault_pass \
  make postgres-tls >> /var/log/ansible-postgres-tls.log 2>&1
```

При первом включении TLS, после смены CA или изменения публичных адресов
запускайте роль на всех PostgreSQL-хостах (`--limit pg01,pg02,pg03`), иначе у
них будут разные доверенные CA или устаревшие SAN. После смены CA обновите
`ca.crt` на app-хостах, иначе `verify-full` перестанет работать. При
обновлении работающего кластера репликация кратковременно прерывается между
перезапуском upstream и обновлением `primary_conninfo` на реплике; playbook
восстанавливает поток в том же запуске.

DNS:

- `gitlab-test.<domain>` → публичный IP `gitlab01`;
- `elastik.<domain>` → публичный IP `elk01`;
- GitLab SSH для `git clone` работает на `gitlab01:22`.

Для теста без DNS добавьте записи в `/etc/hosts` на рабочей машине.

Let's Encrypt настраивается для GitLab и Kibana. Сертификаты продлеваются
автоматически (`gitlab-ctl` и `certbot.timer`); после смены DNS или IP
перезапустите соответствующую роль.

## Резервное копирование

| Что | Где | Когда | Хранение |
|---|---|---|---|
| PostgreSQL WAL-G (full) | VK Cloud + Yandex Cloud: `s3://tlcamp-db-backup/db/pg18/main-encrypted-v1` | воскресенье 02:00 | 4 full + diffs в каждом S3 |
| PostgreSQL WAL-G (diff) | те же два облака | ежедневно 03:00 | в цепочке full |
| GitLab backup | локально `gitlab01:/var/opt/gitlab/backups` + S3 `s3://tlcamp-gitlab-backup/gitlab01/` | ежедневно 02:30 | 7 дней локально, 30 дней в S3 |
| rclone jobs | `maint01` | по расписанию job-а | зависит от S3 |

Таймеры:

```bash
systemctl list-timers --all | grep -E 'wal-g|gitlab|rclone|docker'
```

### PostgreSQL

Роль `postgres` устанавливает WAL-G (PostgreSQL-сборка, версия из
`postgres_walg_version`) и настраивает физическое резервное копирование в
**два независимых S3-совместимых хранилища**:

- `archive_mode=on` и `archive_command` только на primary; реплики
  продолжают streaming replication и WAL не архивируют;
- `/usr/local/sbin/walg-archive` отправляет каждый WAL-сегмент в оба S3
  независимо и возвращает успех только когда обе копии записаны; фоновая
  догрузка WAL-G отключена, чтобы общая локальная отметка сегмента не
  скрыла отправку во второй S3;
- WAL-G шифрует данные libsodium-ключом
  `/etc/wal-g/libsodium-v1.hex` (переменная `vault_walg_libsodium_key`);
- weekly full backup и daily differential backup запускаются systemd-
  таймерами `wal-g-full.timer` и `wal-g-diff.timer`;
- после `backup-push` база копируется во второй S3 через `wal-g copy`;
- retention: `wal-g delete retain FULL 4` после каждого full в обоих S3;
- конфигурации S3 — `/etc/wal-g/config.json` и
  `/etc/wal-g/config-secondary.json`, обёртки — `/usr/local/bin/walg` и
  `/usr/local/bin/walg-secondary`, скрипт — `/usr/local/sbin/walg-backup`;
- старый `postgres-backup.timer` с `pg_dumpall` роль останавливает и удаляет,
  чтобы не запускались две схемы резервного копирования.

Ручной запуск и проверка:

```bash
# Полный бэкап сейчас
sudo systemctl start wal-g-backup@full.service
journalctl -u wal-g-backup@full.service -n 100 --no-pager

# Списки бэкапов в обоих S3
sudo -u postgres walg backup-list
sudo -u postgres walg-secondary backup-list

# Состояние WAL-архива
sudo -u postgres psql -c "SHOW archive_mode; SHOW archive_command;"
sudo -u postgres psql -c "SELECT * FROM pg_stat_archiver;"
```

Если второй S3 временно недоступен, `archive_command` завершается ошибкой,
а PostgreSQL накапливает WAL в `pg_wal` до восстановления доступа. Это
следствие требования хранить обе копии синхронно; следите за
`pg_stat_archiver` и свободным местом. При первом включении второго S3
запустите full backup вручную (или дождитесь воскресного full), чтобы
скопировать уже существующие бэкапы.

**Ключ шифрования нельзя терять.** Без `vault_walg_libsodium_key` (или его
копии) зашифрованные бэкапы восстановить невозможно. Храните копию ключа
вне `pg01`, например в менеджере секретов или в отдельном vault.

Пошаговое восстановление (full, PITR, восстановление на новую ВМ) описано в
[`docs/postgres-wal-g.md`](docs/postgres-wal-g.md).

### GitLab

`gitlab-backup create` создаёт архив, рядом сохраняются `gitlab.rb`,
`gitlab-secrets.json`, версия GitLab и `SHA256SUMS`. Скрипт
`/usr/local/sbin/gitlab-backup.sh` затем выгружает все файлы через rclone в
VK Cloud Object Storage:

```text
s3://tlcamp-gitlab-backup/gitlab01/<UTC-метка>/
```

Параметры:

- endpoint `https://hb.ru-msk.vkcloud-storage.ru`, region `ru-msk`;
- bucket `tlcamp-gitlab-backup`, path-style access;
- ключи доступа — `vault_gitlab_backup_s3_access_key_id` и
  `vault_gitlab_backup_s3_secret_access_key`;
- локальное хранение — 7 дней, в S3 — 30 дней
  (`gitlab_backup_s3_keep_days`).

Проверка и ручной запуск:

```bash
sudo systemctl start gitlab-backup.service
journalctl -u gitlab-backup.service -n 100 --no-pager
sudo rclone lsf gitlab-backup:tlcamp-gitlab-backup/gitlab01 \
  --config /etc/rclone/rclone.conf --recursive
```

Для восстановления нужны совместимая версия GitLab, архив и
`gitlab-secrets.json`. Официальная процедура: остановить сервисы,
восстановить архив, вернуть `gitlab-secrets.json`, выполнить
`gitlab-ctl reconfigure`.

Перенос GitLab на новую ВМ, включая backup в S3 и восстановление, описан в
[`docs/gitlab-migration.md`](docs/gitlab-migration.md).

### rclone на maint01

Роль `maintenance` устанавливает rclone, создаёт `/etc/rclone/rclone.conf` и
systemd-сервисы/таймеры для задач из `rclone_jobs`. **По умолчанию
`rclone_jobs: []`**, потому что в репозитории неизвестно, откуда maintenance-
хост должен забирать бэкапы. Если S3-совместимого хранилища ещё нет,
установите `rclone_manage_config: false`, иначе роль потребует реальные
`vault_rclone_*` (заглушки `ChangeMe`/`example.com` отклоняются). Пример:

```yaml
# inventories/production/group_vars/maintenance.yml
rclone_jobs:
  - name: gitlab-backups
    source: /mnt/backups/gitlab/
    destination: backups/gitlab/
    mode: copy
    schedule: "*-*-* 03:30:00"
    transfers: 4
    checkers: 8
    retries: 3
```

`source` — локальный путь на `maint01`. Чтобы копировать бэкапы с других ВМ,
нужно сначала смонтировать их на `maint01` (NFS/SMB/SSHFS) или расширить роль
задачей `rclone sync` с SFTP-remote. В текущем виде роль не забирает файлы по
SSH автоматически.

Проверка:

```bash
sudo rclone lsd backup: --config /etc/rclone/rclone.conf
sudo systemctl start rclone-gitlab-backups.service
journalctl -u rclone-gitlab-backups.service -n 100
```

Включите versioning/object lock и шифрование в S3, ограничьте IAM-политику
только нужным префиксом. Регулярно проверяйте восстановление, а не только
наличие файлов.

## Миграция GitLab

Если GitLab уже работает на другой машине, используйте отдельный runbook:
[`docs/gitlab-migration.md`](docs/gitlab-migration.md).

Кратко:

1. Зафиксируйте версию и редакцию GitLab (CE/EE).
2. Настройте backup в S3 на старом хосте.
3. Перенесите не только `*_gitlab_backup.tar`, но и `gitlab.rb`,
   `gitlab-secrets.json`, TLS/SSH-ключи и, при необходимости, данные
   объектного хранилища.
4. Разверните на новой ВМ **ту же версию** GitLab.
5. Восстановите секреты, конфигурацию и архив, затем выполните
   `gitlab-ctl reconfigure`.
6. Проверьте `gitlab:check`, `gitlab:doctor:secrets`, clone, pipelines,
   runners и 2FA, после чего переключайте DNS/nginx.

GitLab backup не включает конфигурацию, секреты, Redis и объектное хранилище.
Эти данные переносятся отдельно.

## Безопасность

Что сделано:

- UFW с deny по умолчанию;
- SSH только по ключам, root login запрещён (кроме key-based
  `prohibit-password`), fail2ban;
- отдельный пользователь `deploy` с sudo;
- пароли и ключи в Ansible Vault;
- Elasticsearch security enabled, Kibana/Logstash-пользователи с паролями;
- Valkey с `requirepass`;
- PostgreSQL: SCRAM для TCP, peer для локальных; приложения и репликация
  только через публичные `hostssl`-подключения (`sslmode=verify-full`) с
  сертификатами приватного CA; порт `5432` в UFW разрешён только конкретным
  публичным `/32`;
- Let's Encrypt TLS на публичных GitLab и Kibana; self-signed/custom — на
  отдельном `nginx01`;
- unattended-upgrades;
- `StrictHostKeyChecking=accept-new` для первичного подключения к новым ВМ.

Что важно учесть:

- `common_admin_sudo_nopasswd: true` — удобно, но повышает последствия
  компрометации ключа. Для строгих требований поставьте `false`.
- Valkey работает **без TLS** и доступен по публичному IP только с
  `docker-prod-01` и `docker-test-01`. Хост во втором облаке не должен
  обращаться к Valkey напрямую; если это требуется, сначала настройте TLS и
  отдельный публичный endpoint.
- Приватный ключ PostgreSQL CA (`files/postgres-tls/ca.key`) хранится на
  контроллере. Без резервной копии потеря ключа потребует перевыпуска CA и
  сертификатов на всех хостах PostgreSQL.
- Elasticsearch HTTP TLS выключен, потому что слушает loopback
  (`127.0.0.1:9200/9300`). Kibana опубликована напрямую на `:443`; сам
  Elasticsearch снаружи недоступен.
- На `gitlab01` UFW открывает только `22/tcp` (SSH и Git по SSH),
  `80/tcp` (ACME и redirect на HTTPS) и `443/tcp`. Внутренние порты GitLab
  (`5050`, `8060`, `9094` и экспортёры) снаружи закрыты.
- На `elk01` UFW открывает `22/tcp`, `80/tcp` (только для продления
  сертификата), `443/tcp` (Kibana) и `5044/tcp` **только с публичных
  адресов хостов группы `log_shippers`**. Список строится из inventory;
  placeholder-адреса `203.0.113.x` исключаются до заполнения реальных IP.
  Порты `5601`, `9200`, `9300` и `9600` снаружи закрыты.
- Проверить фактическую экспозицию можно через
  `ansible-playbook playbooks/verify.yml --tags verify_firewall`.
- UFW ограничивает источники, но часть межсервисного трафика остаётся
  незашифрованной: Filebeat → Logstash идёт по plain Beats. Для строгих
  требований включите TLS на этом участке или поднимите VPN; PostgreSQL TLS
  этого не покрывает.
- Резервные копии содержат секреты (GitLab secrets, дампы БД). Защищайте S3
  и локальные каталоги.
- Пароль root GitLab из vault — начальный. Смените его и уберите/обновите
  значение в vault.
- Зафиксируйте версии GitLab/Elastic/Docker и проверяйте путь обновления.
  Автоматическое обновление major-версий может сломать сервис.
- `StrictHostKeyChecking=accept-new` доверяет ключу при первом подключении.
  Для повышенных требований заранее добавьте fingerprint-ы в `known_hosts`
  и используйте строгую проверку.
- Нет централизованного мониторинга, IDS/IPS и аудита. Для production
  добавьте Prometheus/Grafana, alerting и централизованный сбор логов
  (сам ELK уже есть, но алертов нет).

## Проверка и диагностика

### Автоматические проверки

```bash
make lint
make syntax
make inventory
make ping VAULT_ARGS=--ask-vault-pass
make check VAULT_ARGS=--ask-vault-pass
make verify VAULT_ARGS=--ask-vault-pass
make verify-postgres VAULT_ARGS=--ask-vault-pass
```

`make verify` проверяет все хосты и требует, чтобы были установлены все
сервисы. Если развёрнуты только PostgreSQL и отдельные Docker-хосты,
используйте `make verify-postgres`.

`make check` выполняет `--check --diff`; часть задач (apt, установка пакетов)
в check-режиме может не выполняться или требовать уже установленных
зависимостей. Это нормально для первого запуска на пустых ВМ: используйте
`make site`.

### Ручные проверки

```bash
# Все хосты доступны
ansible all -m ansible.builtin.ping --ask-vault-pass

# Сервисы (выполняйте на соответствующих хостах)
systemctl status postgresql@18-main              # pg01, pg02, pg03
systemctl status valkey-server                   # pg01
systemctl status docker                          # docker-prod-01/02, docker-test-01
systemctl status nginx                           # nginx01
systemctl status filebeat                        # все хосты, кроме elk01
systemctl status elasticsearch kibana logstash   # elk01
systemctl status gitlab-runsvdir                 # gitlab01

# PostgreSQL
# pg01: pg02; pg02: pg03
sudo -u postgres psql -c "SELECT client_addr, application_name, state FROM pg_stat_replication;"
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"   # на pg02/pg03: t
sudo -u postgres psql -c "SELECT status FROM pg_stat_wal_receiver;"  # pg02/pg03: streaming

# WAL-G (pg01)
systemctl status wal-g-full.timer wal-g-diff.timer
sudo -u postgres psql -c "SELECT * FROM pg_stat_archiver;"
sudo -u postgres walg backup-list
sudo -u postgres walg-secondary backup-list

# Valkey
valkey-cli -h 127.0.0.1 -p 6379 -a "$VALKEY_PASSWORD" --no-auth-warning ping

# GitLab
sudo gitlab-ctl status
curl -fsS http://127.0.0.1/-/health
curl -fsS https://gitlab-test.<domain>/users/sign_in >/dev/null

# Elastic Stack
curl -u elastic 'http://127.0.0.1:9200/_cluster/health?pretty'
curl -fsS https://elastik.<domain>/api/status

# nginx01 (не используется для GitLab/Kibana)
sudo nginx -t

# Логи
journalctl -u postgresql@18-main -n 100 --no-pager
journalctl -u elasticsearch -n 100 --no-pager
journalctl -u gitlab-runsvdir -n 100 --no-pager
```

### Типовые проблемы

| Симптом | Что проверить |
|---|---|
| `vault password` / `no vault secrets found` | создан ли `vault.yml`, зашифрован ли он, передан ли пароль |
| `Permission denied (publickey)` | ключ `ubuntu` в `authorized_keys`, правильный `ansible_user`, SSH-порт |
| Потеряли SSH после bootstrap | проверьте `sshd_config`, UFW и не забанен ли ваш IP в fail2ban; используйте консоль гипервизора/облака |
| `Host key verification failed` | сменился ключ ВМ; удалите старый fingerprint из `known_hosts` |
| `community.*` collection not found | `ansible-galaxy collection install -r requirements.yml` |
| Elasticsearch не стартует | `vm.max_map_count`, memory lock, heap, `journalctl -u elasticsearch` |
| Kibana 401/502 | пароль `kibana_system`, `server.publicBaseUrl`, доступность Elasticsearch |
| GitLab долго не поднимается | `gitlab-ctl reconfigure` может идти минутами; смотрите `gitlab-ctl status` |
| Реплика не догоняет | слот на непосредственном upstream, `pg_stat_replication`, `.pgpass`, `pg_hba`, firewall |
| Роль отклоняет существующую реплику | upstream/slot в `postgres_replication_topology` не совпадает с `SHOW primary_conninfo` / `SHOW primary_slot_name`; пересоберите реплику или обновите конфигурацию вручную |
| Приложение не подключается к `pg01` | `postgres_app_client_rules` (публичный source CIDR), UFW на `pg01`, `hostssl` в `pg_hba.conf`, `postgres_replication_address`, SAN сертификата, `ca.crt` на app-хосте и `sslmode=verify-full` |
| `pg03` не подключается к `pg02` | публичный `postgres_replication_address` на `pg02`, `postgres_replication_source_cidr`, UFW и `pg_hba` на `pg02`, `wal_status` слота `replica_pg03` |
| WAL не архивируется | `SELECT * FROM pg_stat_archiver;`, `journalctl -u postgresql@18-main`, доступность обоих S3, права `postgres` на `/etc/wal-g/config.json`, `/etc/wal-g/config-secondary.json` и ключ, `walg backup-list`, `walg-secondary backup-list` |
| WAL-G backup падает | `journalctl -u wal-g-backup@full.service`, версия `wal-g --version`, S3 endpoint/region в обоих конфигах, `WALG_S3_PREFIX`, ключ libsodium |
| Второй S3 отстаёт или не принимает копии | `journalctl -u wal-g-backup@*`, `walg-secondary backup-list`, `wal-g copy --from /etc/wal-g/config.json --to /etc/wal-g/config-secondary.json`, credentials второго S3 |
| Не восстанавливается зашифрованный бэкап | тот же `vault_walg_libsodium_key`, что при создании; без него restore невозможен |
| `postgres_replica_rebuild` | после пересборки верните `false` |
| nginx отдаёт 502 | upstream IP/порт, UFW на GitLab/ELK, `nginx -t` |
| Сертификат не тот | `nginx_tls_mode`, пути к cert/key, SAN, перезапуск nginx |
| Переменные группы не применились | нет ли одновременно `group_vars/<group>.yml` и каталога `group_vars/<group>/` |
| `stdout_callback` ошибка | в `ansible.cfg` используется `default` + `result_format: yaml` |

## Ограничения и допущения

- **Сеть, домен и IP-адреса — заглушки.** Реальные значения нужно указать
  перед запуском.
- **Размеры ВМ, кроме тестовой, — допущение.** `vmlist` не содержит
  требований к CPU/RAM/диску.
- **Ubuntu 24.04 LTS** — единственная поддерживаемая ОС.
- **Proxmox VE** — опциональный гипервизор; `make site` не создаёт ВМ.
  `pg03` и `docker-prod-02` находятся во втором облаке и этим репозиторием не
  создаются.
- **Нет HA**: GitLab, nginx, ELK, Valkey и maintenance — одиночные хосты.
  PostgreSQL имеет primary, реплику первого уровня и каскадную реплику, но
  без автоматического failover.
- **Межоблачная репликация асинхронная.** `pg03` зависит от доступности
  `pg02`; при потере `pg02` автоматического переключения на `pg01` нет.
  Задержка и стоимость трафика зависят от канала между облаками.
- **Все ВМ публичные.** `pg01`, `pg02`, `pg03` и остальные хосты доступны по
  публичным адресам; приватной management-сети нет. Весь PostgreSQL-трафик
  шифруется TLS, но порт `5432` всё равно должен быть ограничен конкретными
  публичными `/32` в UFW и `pg_hba.conf`; не открывайте его для `0.0.0.0/0`.
  SSH, наоборот, открыт с любых IPv4/IPv6-адресов; защита — только ключи и
  fail2ban, который банит перебор со всех адресов (кроме loopback).
- **Автоперевыпуск TLS ленивый.** Сертификаты проверяются и перевыпускаются
  только при запуске роли; без cron/AWX/GitLab CI они не обновятся сами.
  Пример cron и команда `make postgres-tls` приведены в разделе
  [TLS PostgreSQL](#tls-postgresql).
- **`pg03` — единственная реплика во втором облаке.** Если `pg02` пересобран
  или потерян, `pg03`, возможно, потребуется пересобрать; проверяйте
  `pg_replication_slots` и `pg_stat_wal_receiver`.
- **ELK single-node**: нет кластера Elasticsearch, нет реплик шардов.
  Snapshot/restore индексов не настроен; при необходимости добавьте
  snapshot repository в S3 и ILM-политику. ILM/retention по умолчанию тоже
  не настроены, поэтому индексы будут расти до ручной очистки.
- **Valkey**: AOF/RDB хранятся локально на `pg01`; централизованного backup
  нет. Для важных данных настройте копирование dump-ов отдельно.
- **Нет управления DNS**: записи `gitlab-test` и `elastik` должны указывать
  на публичные адреса соответствующих ВМ. Let's Encrypt для GitLab и Kibana
  настраивается и продлевается автоматически.
- **Приложения не деплоятся**: Docker-хосты только подготовлены.
- **rclone jobs пусты по умолчанию**: нет NFS/SSH-монтирования бэкапов
  других хостов; настройте `rclone_jobs` и источник данных.
- **Нет централизованного мониторинга и алертинга.**
- **Нет автоматического restore-теста.** Резервные копии нужно регулярно
  проверять вручную.
- **GitLab/Elastic/Docker версии не зафиксированы** (кроме major-ветки
  Elastic 9.x). Для production добавьте pinning и процедуру обновления.
- **Секреты в vault** должны иметь реальные значения; примеры в
  `vault.yml.example` небезопасны.

## Структура репозитория

```text
.
├── ansible.cfg
├── Makefile
├── README.md
├── requirements.txt
├── requirements.yml
├── vmlist
├── docs/
│   ├── gitlab-migration.md
│   └── postgres-wal-g.md
├── inventories/
│   └── production/
│       ├── hosts.yml
│       ├── group_vars/
│       │   ├── all/
│       │   │   ├── main.yml
│       │   │   └── vault.yml.example
│       │   ├── docker.yml
│       │   ├── docker_prod.yml
│       │   ├── docker_test.yml
│       │   ├── elk.yml
│       │   ├── gitlab.yml
│       │   ├── maintenance.yml
│       │   ├── nginx.yml
│       │   ├── postgres.yml
│       │   ├── postgres_primary.yml
│       │   ├── postgres_replicas.yml
│       │   ├── postgres_cascading.yml
│       │   └── valkey.yml
│       └── host_vars/
│           ├── pg01.yml
│           ├── pg02.yml
│           └── pg03.yml
├── playbooks/
│   ├── bootstrap.yml
│   ├── docker.yml
│   ├── elk.yml
│   ├── filebeat.yml
│   ├── gitlab.yml
│   ├── maintenance.yml
│   ├── nginx.yml
│   ├── postgres.yml
│   ├── proxmox-provision.yml
│   ├── site.yml
│   └── verify.yml
├── provisioning/
│   └── proxmox/
│       └── vars.yml
└── roles/
    ├── common/
    ├── docker/
    ├── elastic_repo/
    ├── elk/
    ├── filebeat/
    ├── gitlab/
    ├── maintenance/
    ├── nginx/
    ├── postgres/
    ├── proxmox_vm/
    └── valkey/
```

## Статус

Внутренний проект инфраструктуры TLCamp. Изменения проверяются через
`make lint`, `make syntax` и `make verify` на стенде. Перед production-
запуском обязательно замените все placeholder-значения и проверьте
резервное копирование/восстановление.

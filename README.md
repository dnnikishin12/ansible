# Ansible-инфраструктура TLCamp

Playbook-и для развёртывания и сопровождения десяти виртуальных машин из
[`vmlist`](vmlist):

- GitLab CE;
- PostgreSQL 18: primary, реплика первого уровня и каскадная реплика во
  втором облаке;
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

Сеть и домен ниже — **placeholder**: `10.10.10.0/24` для облака Proxmox и
`203.0.113.0/24` для `pg03` во втором облаке. Замените их на свои в
`inventories/production/hosts.yml` и
`inventories/production/group_vars/all/main.yml`.

| ВМ | IP | Роль | vCPU / RAM / диск |
|---|---|---|---|
| `gitlab01` | `10.10.10.11` | GitLab CE, встроенный nginx на `:80` | 4 / 8 ГБ / 100 ГБ |
| `pg01` | `10.10.10.12` | PostgreSQL 18 primary + Valkey | 4 / 16 ГБ / 200 ГБ |
| `pg02` | `10.10.10.13` | PostgreSQL 18 реплика первого уровня, upstream для `pg03` | 4 / 16 ГБ / 200 ГБ |
| `pg03` | `203.0.113.14` | PostgreSQL 18 каскадная реплика во втором облаке | 4 / 16 ГБ / 200 ГБ |
| `docker-prod-01` | `10.10.10.15` | Docker Engine, production | 4 / 8 ГБ / 100 ГБ |
| `docker-prod-02` | `10.10.10.16` | Docker Engine, production | 4 / 8 ГБ / 100 ГБ |
| `docker-test-01` | `10.10.10.17` | Docker Engine, test | 6 / 8 ГБ / 128 ГБ |
| `elk01` | `10.10.10.18` | Elasticsearch, Logstash, Kibana | 4 / 16 ГБ / 200 ГБ |
| `nginx01` | `10.10.10.19` | nginx, TLS-терминация | 2 / 2 ГБ / 40 ГБ |
| `maint01` | `10.10.10.20` | rclone, backup jobs | 2 / 2 ГБ / 50 ГБ |

В исходном `vmlist` явно задан размер только тестового Docker-хоста
(`6cpu-8Gb-128SSD`). Остальные размеры — разумные стартовые значения; их нужно
скорректировать под реальную нагрузку в `provisioning/proxmox/vars.yml`.
Размер `pg03` задаётся отдельно во втором облаке.

### Потоки трафика

```text
                 ┌──────────────────────┐
   HTTPS :443    │       nginx01        │
  ──────────────▶│  TLS termination     │
                 └───────┬──────┬───────┘
                         │      │
             HTTP :80    │      │    HTTP :5601
                         ▼      ▼
                   ┌─────────┐  ┌────────────┐
                   │gitlab01 │  │   elk01    │
                   │ GitLab  │  │  Kibana    │
                   └─────────┘  └────────────┘

  Filebeat (все хосты, кроме elk01) ──▶ Logstash :5044 на elk01
  PostgreSQL pg01 ──streaming──▶ pg02 ──streaming──▶ pg03
             (Proxmox)                (второе облако)
  Docker-хосты ──▶ PostgreSQL :5432 / Valkey :6379 на pg01
```

- nginx принимает внешний HTTPS и проксирует GitLab и Kibana.
- GitLab и Kibana наружу не публикуются: UFW разрешает их порты только с
  `nginx01`, а Kibana слушает внутренний адрес.
- PostgreSQL реплицируется каскадом: `pg01` → `pg02` внутри Proxmox,
  `pg02` → `pg03` через межоблачную сеть. `pg03` не подключается к `pg01`
  напрямую.
- Physical replication slots создаются на непосредственном upstream:
  `replica_pg02` на `pg01` и `replica_pg03` на `pg02`.
- Filebeat отправляет системные логи, логи nginx, Docker, GitLab и PostgreSQL
  в Logstash на `elk01`. Сам `elk01` исключён из группы `log_shippers`, чтобы
  не отправлять логи самому себе.

## Что заменить перед запуском

В репозитории намеренно оставлены значения-заглушки. Перед первым запуском
замените:

1. **IP-адреса** в `inventories/production/hosts.yml` и
   `provisioning/proxmox/vars.yml`. Для ВМ из Proxmox они должны совпадать.
   `pg03` находится во втором облаке и в `proxmox_vms` намеренно отсутствует.
2. **Домен** `campbox.tech` в
   `inventories/production/group_vars/all/main.yml`
   (`internal_domain`, `gitlab_hostname`, `kibana_hostname`) и
   `proxmox_searchdomain` в `provisioning/proxmox/vars.yml`.
3. **Сети** `10.10.10.0/24` и `203.0.113.0/24`, шлюз `10.10.10.1` в
   group_vars и `provisioning/proxmox/vars.yml` (для второго облака —
   в его собственной конфигурации).
4. **Часовой пояс и NTP-серверы**: `common_timezone`, `common_ntp_servers`.
5. **SSH-доступ**: `ansible_user` (по умолчанию `ubuntu`) и
   `common_firewall_ssh_sources`. Не оставляйте SSH открытым только из
   `10.10.10.0/24`, если запускаете Ansible из другой сети. Для `pg03`
   placeholder сети управления находится в
   `group_vars/postgres_cascading.yml`; замените его до bootstrap. Если меняете
   `common_ssh_port`, задайте соответствующий `ansible_port` в inventory.
6. **Межоблачную репликацию**: в `host_vars/pg02.yml` задайте
   `postgres_replication_address` — адрес `pg02`, доступный из второго облака
   (публичный IP, NAT или VPN). В `group_vars/postgres_cascading.yml` задайте
   `postgres_replication_source_cidr` — исходный адрес/подсеть `pg03`, который
   видит `pg02`. При необходимости измените `postgres_listen_addresses` на
   `pg02`.
7. **Секреты** в зашифрованном `vault.yml` (см. ниже). Скопируйте
   `vault.yml.example`, заполните и зашифруйте. Роли проверяют, что ключевые
   пароли и SSH-ключи не остались заглушками `ChangeMe`/`ReplaceMe`.
   Для WAL-G дополнительно задайте `vault_walg_s3_access_key_id`,
   `vault_walg_s3_secret_access_key` и `vault_walg_libsodium_key`. Роль
   хранит две копии бэкапов в двух S3; задайте реальный
   `postgres_walg_secondary_s3_prefix` (по умолчанию там заглушка
   `CHANGE-ME`). Если второй S3 в другом аккаунте, добавьте
   `vault_walg_secondary_s3_access_key_id` и
   `vault_walg_secondary_s3_secret_access_key`, иначе используются ключи
   primary S3.
8. **Параметры Proxmox** в `provisioning/proxmox/vars.yml`:
   `proxmox_api_host`, `proxmox_node`, `proxmox_template`, `proxmox_storage`,
   `proxmox_bridge`, если используете provisioning.
9. **Размеры ВМ** в `provisioning/proxmox/vars.yml`, если используете
   provisioning. Размер `pg03` задаётся отдельно во втором облаке.
10. **TLS-сертификаты**: по умолчанию создаётся self-signed сертификат.
   Для production лучше подготовить `nginx_tls_mode: custom` и свои файлы.

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
- для `pg03`: сетевой доступ к `pg02` на TCP `5432` и к репозиториям PGDG.
  Предпочтительны VPN или private peering; при репликации через публичную
  сеть ограничьте `:5432` на `pg02` только адресом `pg03` в UFW и
  `pg_hba.conf`.

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
$EDITOR inventories/production/group_vars/all/main.yml
$EDITOR inventories/production/group_vars/postgres_cascading.yml   # pg03
$EDITOR inventories/production/host_vars/pg02.yml                  # межоблачный адрес
$EDITOR provisioning/proxmox/vars.yml   # если используете Proxmox
```

Проверьте, что IP ВМ из Proxmox в inventory и в provisioning совпадают, а
домен и сеть заменены на реальные. Для `pg03` отдельно задайте адрес второго
облака и межоблачную сеть репликации.

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
включает UFW, fail2ban, chrony и unattended-upgrades. **Перед запуском
убедитесь, что SSH-ключ из vault рабочий и что `common_firewall_ssh_sources`
содержит сеть, из которой вы подключаетесь.** Иначе можно потерять доступ.

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
| `make provision` | создание/обновление ВМ в Proxmox |
| `make bootstrap` | базовый bootstrap |
| `make site` | полное развёртывание |
| `make verify` | post-deploy проверки |
| `make gitlab`, `make postgres`, `make docker`, `make elk`, `make filebeat`, `make nginx`, `make maintenance` | отдельный сервис |
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
| `vault_walg_s3_access_key_id` | access key для primary WAL-G S3 (PostgreSQL backups) |
| `vault_walg_s3_secret_access_key` | secret key для primary WAL-G S3 |
| `vault_walg_libsodium_key` | 64 hex-символа для шифрования WAL-G (общий ключ обеих копий) |
| `vault_walg_secondary_s3_access_key_id` | опционально: access key для второго WAL-G S3; если не задан, используется primary |
| `vault_walg_secondary_s3_secret_access_key` | опционально: secret key для второго WAL-G S3; если не задан, используется primary |
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
только после `pg02`. `host_vars/pg02.yml` содержит адрес для `pg03` и
правило UFW, а `group_vars/postgres_cascading.yml` — исходный CIDR `pg03`.

`log_shippers` — группа-агрегатор: она включает все хосты, кроме `elk01`.
Filebeat ставится на 9 машин; `elk01` хранит логи локально.

### Топология PostgreSQL

| Переменная | Где задаётся | Назначение |
|---|---|---|
| `postgres_replication_topology` | `group_vars/postgres.yml` | карта `реплика: upstream`; сейчас `pg02: pg01`, `pg03: pg02` |
| `postgres_replication_address` | `host_vars/pg02.yml` | адрес `pg02`, по которому подключается `pg03` (публичный/NAT/VPN) |
| `postgres_replication_source_cidr` | `group_vars/postgres_cascading.yml` | исходный CIDR `pg03`, который видит `pg02`; используется в `pg_hba` и UFW |
| `postgres_listen_addresses` | `host_vars/pg02.yml` | `0.0.0.0` на `pg02`, чтобы NAT/публичный адрес был доступен; доступ ограничен UFW и `pg_hba` |

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

### Основные переменные

`inventories/production/group_vars/all/main.yml`:

| Переменная | Значение по умолчанию | Комментарий |
|---|---|---|
| `internal_domain` | `campbox.tech` | заменить |
| `internal_network` | `10.10.10.0/24` | заменить |
| `gitlab_hostname` | `gitlab.<domain>` | внешнее имя GitLab |
| `kibana_hostname` | `kibana.<domain>` | внешнее имя Kibana |
| `ansible_user` | `ubuntu` | начальный SSH-пользователь |
| `common_timezone` | `Europe/Moscow` | |
| `common_firewall_ssh_sources` | `internal_network` | **проверить до bootstrap** |
| `common_admin_user` | `deploy` | создаётся ролью `common` |
| `common_admin_sudo_nopasswd` | `true` | при необходимости ужесточить |
| `local_backup_keep_days` | `7` | локальное хранение GitLab backup-ов |

## Provisioning в Proxmox VE

Playbook `playbooks/proxmox-provision.yml` создаёт ВМ из cloud-init-шаблона.
Он не обязателен: если ВМ уже существуют, переходите сразу к `site.yml`.

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
proxmox_gateway: "10.10.10.1"
proxmox_nameservers:
  - "10.10.10.1"
  - "1.1.1.1"
```

Далее — список `proxmox_vms` с `name`, `vmid`, `cores`, `memory`, `disk`,
`ip`. IP перечисленных ВМ должны совпадать с inventory.

`pg03` намеренно отсутствует в `proxmox_vms`: она находится во втором
облаке и создаётся средствами этого облака. Добавьте её в inventory и
подготовьте SSH-доступ, но не пытайтесь создать её этим playbook-ом.

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

# Всё, кроме Docker
ansible-playbook playbooks/site.yml --skip-tags docker --ask-vault-pass

# Только GitLab на одном хосте
ansible-playbook playbooks/site.yml --tags gitlab --limit gitlab01 --ask-vault-pass

# Проверить конфигурацию без изменений
ansible-playbook playbooks/site.yml --check --diff --ask-vault-pass
```

Основные теги: `common`, `bootstrap`, `postgres`, `postgres_primary`,
`postgres_replica`, `postgres_cascading`, `valkey`, `gitlab`, `docker`,
`docker_prod`, `docker_test`, `elk`, `logging`, `filebeat`, `nginx`,
`maintenance`, `rclone`, `provision`, `proxmox`.

`site.yml` запускает bootstrap первым, поэтому на свежих ВМ достаточно одной
команды. Если нужен только bootstrap, запускайте `bootstrap.yml` отдельно.

## Что настраивается

### common (все хосты)

- пакеты: `curl`, `jq`, `chrony`, `fail2ban`, `ufw`, `unattended-upgrades`,
  `qemu-guest-agent`, `rsyslog`, `logrotate` и др.;
- пользователь `deploy`, группа `sudo`, SSH-ключи из vault;
- SSH hardening: только ключи, `PermitRootLogin prohibit-password`,
  ограничение попыток, drop-in `00-ansible-hardening.conf`;
- UFW: входящие по умолчанию запрещены, SSH — из
  `common_firewall_ssh_sources`, сервисные порты — из group vars;
- fail2ban для SSH;
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
- `pg_hba.conf`: peer для локальных, SCRAM для внутренней сети и
  `replication` только для непосредственных downstream-реплик;
- пользователь `replicator` с правом `REPLICATION` создаётся на primary и
  попадает на реплики вместе с базовой копией;
- топология задаётся картой `postgres_replication_topology`:
  `pg01` → `pg02` → `pg03`;
- physical slots создаются на непосредственном upstream:
  `replica_pg02` на `pg01`, `replica_pg03` на `pg02`;
- `pg02` — одновременно standby и upstream для `pg03`. Поэтому на нём
  включены `max_wal_senders`, `max_replication_slots` и `hot_standby`, а
  `pg_hba.conf` и UFW разрешают `:5432` только из внутренней сети и от
  `pg03`;
- `pg03` подключается не к `pg01`, а к адресу `postgres_replication_address`
  из `host_vars/pg02.yml`. Для межоблачной сети это публичный IP, NAT или
  VPN-адрес; источник `pg03` задаётся в
  `group_vars/postgres_cascading.yml` (`postgres_replication_source_cidr`);
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
- bind на `127.0.0.1` и приватный IP;
- AOF `everysec`, RDB snapshots;
- UFW: порт `6379` только из внутренней сети;
- проверка `PING` с паролем.

`valkey_maxmemory` по умолчанию пуст (без лимита). Для кэша задайте,
например, `"2gb"` и политику `allkeys-lru`. Для очередей/данных, которые
нельзя терять, `noeviction` безопаснее, но запись может начать падать при
заполнении памяти. Учитывайте, что Valkey и PostgreSQL делят RAM одного
хоста.

### GitLab CE

- установка из официального репозитория GitLab;
- `external_url` = `https://gitlab.<domain>`;
- GitLab за nginx: встроенный nginx слушает `:80`, TLS завершается на
  `nginx01`;
- `trusted_proxies` — адрес `nginx01`;
- начальный пароль root из vault;
- ежедневный backup в `/var/opt/gitlab/backups` с копированием
  `gitlab.rb` и `gitlab-secrets.json`;
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
> необходимости: привязывайте их к `127.0.0.1` или внутреннему адресу,
> используйте reverse proxy и отдельно проверяйте `iptables -L DOCKER-USER`.
> Для строгой фильтрации добавьте `ufw-docker` или настройте `DOCKER-USER`
> вручную.

### Elastic Stack 9.x

- Elasticsearch, Kibana, Logstash из репозитория Elastic 9.x;
- single-node Elasticsearch, security enabled, HTTP TLS выключен, потому что
  Elasticsearch слушает только `127.0.0.1`;
- heap 50% RAM (не более 31 ГБ);
- Kibana слушает приватный IP, доступна через nginx;
- Logstash beats input `0.0.0.0:5044`, firewall — из внутренней сети;
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

- TLS-терминация для `gitlab.<domain>` и `kibana.<domain>`;
- HTTP → HTTPS redirect;
- proxy для GitLab (включая WebSocket/Upgrade) и Kibana;
- self-signed сертификат по умолчанию (SAN: GitLab, Kibana, домен);
- поддержка custom-сертификата;
- `client_max_body_size 0` для загрузки артефактов GitLab.

Порты `80` и `443` открыты в UFW. Upstream-порты GitLab (`80`) и Kibana
(`5601`) доступны только с `nginx01`.

## TLS и DNS

По умолчанию `nginx_tls_mode: "selfsigned"`:

- создаётся RSA-ключ 4096 бит;
- сертификат самоподписанный, срок 825 дней;
- браузеры покажут предупреждение.

Для production:

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

DNS:

- `gitlab.<domain>` → IP `nginx01`;
- `kibana.<domain>` → IP `nginx01`;
- для GitLab SSH — `gitlab.<domain>` → IP `gitlab01` (или отдельное имя),
  если нужен clone по SSH.

Для теста без DNS добавьте записи в `/etc/hosts` на рабочей машине.

Let's Encrypt автоматически не настраивается: в nginx есть ACME webroot, но
certbot не устанавливается. Используйте custom-сертификат, внутренний CA или
добавьте certbot отдельной ролью.

## Резервное копирование

| Что | Где | Когда | Хранение |
|---|---|---|---|
| PostgreSQL WAL-G (full) | два S3: `s3://db-backup/...` и `s3://<second-bucket>/...` | воскресенье 02:00 | 4 full + diffs в каждом S3 |
| PostgreSQL WAL-G (diff) | те же два S3 | ежедневно 03:00 | в цепочке full |
| GitLab backup | `gitlab01:/var/opt/gitlab/backups` | ежедневно 02:30 | 7 дней |
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

`gitlab-backup create` создаёт архив, рядом сохраняются `gitlab.rb` и
`gitlab-secrets.json`. Для восстановления нужны совместимая версия GitLab и
секреты. Официальная процедура: остановить сервисы, восстановить архив,
вернуть `gitlab-secrets.json`, выполнить `gitlab-ctl reconfigure`.

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
- PostgreSQL SCRAM для TCP, peer для локальных;
- self-signed/custom TLS на внешнем периметре;
- unattended-upgrades;
- `StrictHostKeyChecking=accept-new` для первичного подключения к новым ВМ.

Что важно учесть:

- `common_admin_sudo_nopasswd: true` — удобно, но повышает последствия
  компрометации ключа. Для строгих требований поставьте `false`.
- PostgreSQL и Valkey общаются по внутренней сети **без TLS**. Если сеть не
  доверенная, настройте TLS для PostgreSQL и Valkey.
- Elasticsearch HTTP TLS выключен, потому что слушает loopback. Kibana
  доступна по HTTP с приватного IP; снаружи — только через nginx.
- GitLab и Kibana не должны быть доступны напрямую из интернета. UFW
  разрешает их порты только с `nginx01`.
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
```

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

# Elastic Stack
curl -u elastic 'http://127.0.0.1:9200/_cluster/health?pretty'
curl -I "http://$(hostname -I | awk '{print $1}'):5601/api/status"

# nginx
sudo nginx -t
curl -kI https://gitlab.<domain>/
curl -kI https://kibana.<domain>/

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
| Потеряли SSH после bootstrap | `common_firewall_ssh_sources` не содержит вашу сеть; используйте консоль Proxmox и исправьте UFW |
| `Host key verification failed` | сменился ключ ВМ; удалите старый fingerprint из `known_hosts` |
| `community.*` collection not found | `ansible-galaxy collection install -r requirements.yml` |
| Elasticsearch не стартует | `vm.max_map_count`, memory lock, heap, `journalctl -u elasticsearch` |
| Kibana 401/502 | пароль `kibana_system`, `server.publicBaseUrl`, доступность Elasticsearch |
| GitLab долго не поднимается | `gitlab-ctl reconfigure` может идти минутами; смотрите `gitlab-ctl status` |
| Реплика не догоняет | слот на непосредственном upstream, `pg_stat_replication`, `.pgpass`, `pg_hba`, firewall |
| Роль отклоняет существующую реплику | upstream/slot в `postgres_replication_topology` не совпадает с `SHOW primary_conninfo` / `SHOW primary_slot_name`; пересоберите реплику или обновите конфигурацию вручную |
| `pg03` не подключается к `pg02` | `postgres_replication_address` на `pg02`, NAT/VPN, `postgres_replication_source_cidr`, UFW и `pg_hba` на `pg02`, `wal_status` слота `replica_pg03` |
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
- **Proxmox VE** — опциональный гипервизор для первого облака. `pg03`
  находится во втором облаке и этим репозиторием не создаётся.
- **Нет HA**: GitLab, nginx, ELK, Valkey и maintenance — одиночные хосты.
  PostgreSQL имеет primary, реплику первого уровня и каскадную реплику, но
  без автоматического failover.
- **Межоблачная репликация асинхронная.** `pg03` зависит от доступности
  `pg02`; при потере `pg02` автоматического переключения на `pg01` нет.
  Задержка и стоимость трафика зависят от канала между облаками.
- **TLS для PostgreSQL не настроен.** Если `pg02` и `pg03` связываются через
  публичную сеть, используйте VPN/private peering либо добавьте SSL-сертификаты
  и `sslmode` в `primary_conninfo`; иначе трафик репликации не шифруется.
- **`pg03` — единственная реплика во втором облаке.** Если `pg02` пересобран
  или потерян, `pg03`, возможно, потребуется пересобрать; проверяйте
  `pg_replication_slots` и `pg_stat_wal_receiver`.
- **ELK single-node**: нет кластера Elasticsearch, нет реплик шардов.
  Snapshot/restore индексов не настроен; при необходимости добавьте
  snapshot repository в S3 и ILM-политику. ILM/retention по умолчанию тоже
  не настроены, поэтому индексы будут расти до ручной очистки.
- **Valkey**: AOF/RDB хранятся локально на `pg01`; централизованного backup
  нет. Для важных данных настройте копирование dump-ов отдельно.
- **Нет управления DNS** и автоматического Let's Encrypt.
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

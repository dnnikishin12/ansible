SHELL := /bin/bash
VENV ?= .venv
VAULT_ARGS ?=
ANSIBLE := $(VENV)/bin/ansible
ANSIBLE_PLAYBOOK := $(VENV)/bin/ansible-playbook
ANSIBLE_LINT := $(VENV)/bin/ansible-lint
PLAYBOOKS := $(wildcard playbooks/*.yml)

.PHONY: help deps lint syntax inventory ping check provision bootstrap site verify verify-postgres gitlab postgres postgres-tls docker elk filebeat nginx maintenance vault-edit clean

help:
	@echo "Available targets:"
	@echo "  deps        Create venv, install Python packages and Ansible collections"
	@echo "  lint        Run yamllint and ansible-lint"
	@echo "  syntax      Run ansible-playbook --syntax-check for all playbooks"
	@echo "  inventory   Print the parsed inventory graph"
	@echo "  ping        Check SSH connectivity to every host"
	@echo "  check       Dry-run the full site playbook (--check --diff)"
	@echo "  provision   Create/update VMs in Proxmox VE (optional, not in site)"
	@echo "  bootstrap   Base OS configuration (users, SSH, firewall, NTP)"
	@echo "  site        Full configuration of all services"
	@echo "  verify      Post-deploy health checks"
	@echo "  verify-postgres PostgreSQL replication, TLS and WAL-G checks only"
	@echo "  gitlab      Configure the GitLab VM"
	@echo "  postgres    Configure PostgreSQL primary, first-level/cascading replicas and Valkey"
	@echo "  postgres-tls Check and renew PostgreSQL TLS certificates only"
	@echo "  docker      Configure Docker hosts"
	@echo "  elk         Configure Elasticsearch, Logstash and Kibana"
	@echo "  filebeat    Configure Filebeat log shipping"
	@echo "  nginx       Configure the reverse proxy"
	@echo "  maintenance Configure rclone and backup jobs"
	@echo "  vault-edit  Edit the encrypted vault file"
	@echo "  clean       Remove the venv and local cache"
	@echo ""
	@echo "Pass --ask-vault-pass with: make <target> VAULT_ARGS=--ask-vault-pass"
	@echo "Or export ANSIBLE_VAULT_PASSWORD_FILE=.vault_pass"

$(VENV)/bin/ansible:
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install --upgrade pip
	$(VENV)/bin/pip install -r requirements.txt
	$(VENV)/bin/ansible-galaxy collection install -r requirements.yml

deps: $(VENV)/bin/ansible

lint: deps
	$(VENV)/bin/yamllint .
	$(ANSIBLE_LINT) playbooks roles

syntax: deps
	@for pb in $(PLAYBOOKS); do \
		echo "==> $$pb"; \
		$(ANSIBLE_PLAYBOOK) --syntax-check "$$pb" || exit 1; \
	done

inventory: deps
	$(ANSIBLE)-inventory --graph

ping: deps
	$(ANSIBLE) all -m ansible.builtin.ping $(VAULT_ARGS)

check: deps
	$(ANSIBLE_PLAYBOOK) playbooks/site.yml --check --diff $(VAULT_ARGS)

provision: deps
	$(ANSIBLE_PLAYBOOK) playbooks/proxmox-provision.yml $(VAULT_ARGS)

bootstrap: deps
	$(ANSIBLE_PLAYBOOK) playbooks/bootstrap.yml $(VAULT_ARGS)

site: deps
	$(ANSIBLE_PLAYBOOK) playbooks/site.yml $(VAULT_ARGS)

verify: deps
	$(ANSIBLE_PLAYBOOK) playbooks/verify.yml $(VAULT_ARGS)

verify-postgres: deps
	$(ANSIBLE_PLAYBOOK) playbooks/verify.yml --tags verify_postgres $(VAULT_ARGS)

gitlab: deps
	$(ANSIBLE_PLAYBOOK) playbooks/gitlab.yml $(VAULT_ARGS)

postgres: deps
	$(ANSIBLE_PLAYBOOK) playbooks/postgres.yml $(VAULT_ARGS)

postgres-tls: deps
	$(ANSIBLE_PLAYBOOK) playbooks/postgres.yml --tags postgres_tls $(VAULT_ARGS)

docker: deps
	$(ANSIBLE_PLAYBOOK) playbooks/docker.yml $(VAULT_ARGS)

elk: deps
	$(ANSIBLE_PLAYBOOK) playbooks/elk.yml $(VAULT_ARGS)

filebeat: deps
	$(ANSIBLE_PLAYBOOK) playbooks/filebeat.yml $(VAULT_ARGS)

nginx: deps
	$(ANSIBLE_PLAYBOOK) playbooks/nginx.yml $(VAULT_ARGS)

maintenance: deps
	$(ANSIBLE_PLAYBOOK) playbooks/maintenance.yml $(VAULT_ARGS)

vault-edit: deps
	$(ANSIBLE) vault edit inventories/production/group_vars/all/vault.yml

clean:
	rm -rf .cache $(VENV)

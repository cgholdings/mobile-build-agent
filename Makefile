# mobile-build-agent — operational Makefile.
# `make` or `make help` lists targets. Non-sudo targets manage the agent; `harden-*` need sudo.

SHELL := /bin/bash
export PATH := /opt/homebrew/bin:$(PATH)

# this file's own dir (portable — works from any clone path). No trailing comment: Make would keep the space.
AGENT_DIR  := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
UID_N     := $(shell id -u)
USER_N    := $(shell id -un)
WORKSPACE  ?= $(HOME)/build-workspace
AGENT_NAME ?= $(shell scutil --get LocalHostName 2>/dev/null || hostname -s)
# render a __PLACEHOLDER__ template to stdout ('|' delimiter so paths' '/' and Make's '#' comment don't clash)
RENDER = sed -e 's|__AGENT_DIR__|$(AGENT_DIR)|g' -e 's|__WORKSPACE__|$(WORKSPACE)|g' -e 's|__AGENT_NAME__|$(AGENT_NAME)|g'
PY312     := /opt/homebrew/opt/python@3.12/bin/python3.12
VENV      := $(AGENT_DIR)/.venv
PY        := $(VENV)/bin/python
GUI       := gui/$(UID_N)
BUILD_SVC := com.cgholdings.buildagent
VAULT_SVC := com.cgholdings.vault-agent
LA        := $(HOME)/Library/LaunchAgents
BROKER    := rabbitmq.tech.cgholdings.internal
VAULT_ADDR_ := https://vault.tech.cgholdings.internal

.DEFAULT_GOAL := help
.PHONY: help deps image firebase-cli secret-id config install uninstall \
        start stop restart start-vault status logs logs-vault logs-fb verify reachability \
        bake-versions bake-android harden-all harden-filevault harden-autologin harden-power \
        bridge-install bridge-status bridge-uninstall scratch scratch-clean clean

help: ## Show this help
	@echo "mobile-build-agent — make targets:"; echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n",$$1,$$2}'
	@echo; echo "First-time (no sudo):  make deps image install start verify"
	@echo "Headless auto-start:   make harden-all   (needs sudo — see GO-LIVE.md step 2-4)"

# ---- one-time setup -----------------------------------------------------------
deps: ## Create the Python venv and install dependencies
	$(PY312) -m venv $(VENV)
	$(VENV)/bin/pip install --quiet --upgrade pip
	$(VENV)/bin/pip install --quiet -r $(AGENT_DIR)/requirements.txt
	@$(PY) -c "import pika,yaml,paramiko;print('deps OK')"

image: ## Build the base VM image if missing (FORCE=1 to rebuild — ~45 min)
	@if tart list 2>/dev/null | grep -q mobile-builder-base && [ -z "$(FORCE)" ]; then \
	  echo "mobile-builder-base already exists — skipping (make image FORCE=1 to rebuild)"; \
	else bash $(AGENT_DIR)/provision-base-image.sh; fi

firebase-cli: ## Bake the firebase CLI into the base image (needed for Firebase publishing)
	bash $(AGENT_DIR)/fb-update.sh

bake-versions: ## Cache pinned Flutter + Ruby (+ cocoapods/bundler/fastlane gems) into the image. FV=3.44.4 RV=4.0.5
	bash $(AGENT_DIR)/bake-versions.sh $(FV) $(RV)

bake-android: ## Bake Android SDK platform+build-tools into the existing image. API=35 BT=35.0.0
	bash $(AGENT_DIR)/bake-android.sh $(API) $(BT)

secret-id: ## Unwrap the Vault secret_id.  Usage: make secret-id WRAP=hvs.XXXX
	@test -n "$(WRAP)" || { echo "Usage: make secret-id WRAP=<wrapping_token>"; exit 1; }
	VAULT_ADDR=$(VAULT_ADDR_) VAULT_CACERT=$(AGENT_DIR)/vault/platform-ca.crt \
	  vault unwrap -field=secret_id '$(WRAP)' > $(AGENT_DIR)/secrets/vault_secret_id
	@chmod 600 $(AGENT_DIR)/secrets/vault_secret_id && echo "secret_id written"

config: ## Render config.yaml + vault-agent.hcl from templates (config.yaml only if missing)
	@if [ -f $(AGENT_DIR)/config.yaml ]; then echo "config.yaml exists — leaving as-is"; \
	 else $(RENDER) $(AGENT_DIR)/config.example.yaml > $(AGENT_DIR)/config.yaml; \
	      echo "config.yaml created (name=$(AGENT_NAME) workspace=$(WORKSPACE))"; fi
	@$(RENDER) $(AGENT_DIR)/vault-agent.hcl.tmpl > $(AGENT_DIR)/vault-agent.hcl
	@echo "vault-agent.hcl rendered"

# ---- launchd services ---------------------------------------------------------
install: config ## Render + load both LaunchAgents (Vault Agent + build agent)
	@mkdir -p $(AGENT_DIR)/logs $(LA)
	$(RENDER) $(AGENT_DIR)/$(VAULT_SVC).plist.tmpl > $(LA)/$(VAULT_SVC).plist
	$(RENDER) $(AGENT_DIR)/$(BUILD_SVC).plist.tmpl > $(LA)/$(BUILD_SVC).plist
	-launchctl bootout $(GUI)/$(VAULT_SVC) 2>/dev/null
	-launchctl bootout $(GUI)/$(BUILD_SVC) 2>/dev/null
	launchctl bootstrap $(GUI) $(LA)/$(VAULT_SVC).plist
	launchctl bootstrap $(GUI) $(LA)/$(BUILD_SVC).plist
	@sleep 6 && $(MAKE) -s status

uninstall: ## Stop and remove both LaunchAgents
	-launchctl bootout $(GUI)/$(BUILD_SVC) 2>/dev/null
	-launchctl bootout $(GUI)/$(VAULT_SVC) 2>/dev/null
	-rm -f $(LA)/$(VAULT_SVC).plist $(LA)/$(BUILD_SVC).plist
	@echo "uninstalled"

start: ## Start/restart both services
	-launchctl kickstart -k $(GUI)/$(VAULT_SVC)
	-launchctl kickstart -k $(GUI)/$(BUILD_SVC)
	@sleep 4 && $(MAKE) -s status
restart: start ## Alias for start
start-vault: ## Restart only Vault Agent (e.g. after editing vault-agent.hcl)
	launchctl kickstart -k $(GUI)/$(VAULT_SVC)

stop: ## Stop both services
	-launchctl bootout $(GUI)/$(BUILD_SVC) 2>/dev/null
	-launchctl bootout $(GUI)/$(VAULT_SVC) 2>/dev/null
	@echo "stopped"

# ---- observe ------------------------------------------------------------------
status: ## Show service + agent status
	@echo "== launchd =="; launchctl list | grep cgholdings || echo "  (no services loaded)"
	@echo "== build agent =="; tail -2 $(AGENT_DIR)/logs/agent.out.log 2>/dev/null || echo "  (no log)"
	@echo "== vault agent =="; tail -1 $(AGENT_DIR)/logs/vault-agent.err.log 2>/dev/null | sed 's/^/  /' || echo "  (no log)"
	@echo "== vault agent renders =="; for f in vault/platform-ca.crt vault/rabbitmq.env vault/token; do \
	  test -s $(AGENT_DIR)/$$f && echo "  ok   $$f" || echo "  MISS $$f"; done

logs: ## Tail the build-agent log
	tail -f $(AGENT_DIR)/logs/agent.out.log
logs-vault: ## Tail the Vault Agent log
	tail -f $(AGENT_DIR)/logs/vault-agent.err.log
logs-fb: ## Tail the firebase-CLI image-update log
	tail -f $(AGENT_DIR)/logs/fb-update.log

verify: ## Run readiness checks (venv, image, broker, secrets, services)
	@echo "venv:";   test -x $(PY) && echo "  ok" || echo "  MISSING (make deps)"
	@echo "image:";  tart list 2>/dev/null | grep -q mobile-builder-base && echo "  ok" || echo "  MISSING (make image)"
	@echo "broker:"; nc -vz -G 6 $(BROKER) 5671 >/dev/null 2>&1 && echo "  reachable" || echo "  UNREACHABLE (VPN?)"
	@echo "vault seeds:"; for f in vault/platform-ca.crt secrets/vault_role_id secrets/vault_secret_id; do \
	  test -s $(AGENT_DIR)/$$f && echo "  ok   $$f" || echo "  MISS $$f"; done
	@$(MAKE) -s status

reachability: ## Check VPN reachability to broker + Vault
	@nc -vz -G 6 $(BROKER) 5671 2>&1 | tail -1
	@nc -vz -G 6 vault.tech.cgholdings.internal 443 2>&1 | tail -1

# ---- headless hardening (SUDO) ------------------------------------------------
harden-all: harden-filevault harden-autologin harden-power ## All headless steps (needs sudo; see GO-LIVE.md)
	@echo "hardened — reboot to confirm auto-start"
harden-filevault: ## Disable FileVault (required for unattended boot — security trade-off)
	sudo fdesetup disable
harden-autologin: ## Enable auto-login for $(USER_N)
	sudo sysadminctl -autologin set -userName $(USER_N)
harden-power: ## Never sleep + auto-restart after outage/hang
	sudo pmset -a sleep 0 disksleep 0 displaysleep 0 powernap 0
	sudo pmset -a autorestart 1
	-sudo systemsetup -setrestartfreeze on

# ---- VM->Vault pf bridge (SUDO; persists across reboot) -----------------------
bridge-install: ## Install the pf VM->Vault bridge LaunchDaemon (root, RunAtLoad)
	$(RENDER) $(AGENT_DIR)/com.cgholdings.vault-bridge.plist.tmpl > /tmp/com.cgholdings.vault-bridge.plist
	sudo cp /tmp/com.cgholdings.vault-bridge.plist /Library/LaunchDaemons/
	sudo chown root:wheel /Library/LaunchDaemons/com.cgholdings.vault-bridge.plist
	sudo chmod 644 /Library/LaunchDaemons/com.cgholdings.vault-bridge.plist
	-sudo launchctl bootout system/com.cgholdings.vault-bridge 2>/dev/null
	sudo launchctl bootstrap system /Library/LaunchDaemons/com.cgholdings.vault-bridge.plist
	@sleep 2 && $(MAKE) -s bridge-status
bridge-status: ## Show the live VM->Vault NAT rules + daemon log
	@sudo pfctl -a cgh-vault-bridge -s nat 2>/dev/null || echo "(anchor empty / pf off)"
	@tail -3 /var/log/cgh-vault-bridge.log 2>/dev/null || echo "(no daemon log yet)"
bridge-uninstall: ## Remove the bridge daemon (NAT rules clear on next pf reload/reboot)
	-sudo launchctl bootout system/com.cgholdings.vault-bridge 2>/dev/null
	-sudo rm -f /Library/LaunchDaemons/com.cgholdings.vault-bridge.plist
	@echo "removed"

# ---- utilities ----------------------------------------------------------------
scratch: ## Boot a throwaway clone of the base image and print SSH details
	tart clone mobile-builder-base scratch
	tart run scratch --no-graphics >/dev/null 2>&1 &
	@for i in $$(seq 1 40); do IP=$$(tart ip scratch 2>/dev/null); [ -n "$$IP" ] && break; sleep 3; done; \
	  echo "ssh -o StrictHostKeyChecking=no admin@$$IP   (password: admin)"; \
	  echo "when done: make scratch-clean"
scratch-clean: ## Stop and delete the throwaway VM
	-tart stop scratch 2>/dev/null; sleep 1; tart delete scratch 2>/dev/null; echo "removed scratch"

clean: ## Prune old per-job workspaces and any stray build VMs
	-rm -rf $(AGENT_DIR)/build-workspace/*/
	-for v in $$(tart list 2>/dev/null | awk '/build-|verify-|scratch|fb-update/{print $$2}'); do tart delete $$v 2>/dev/null; done
	@echo "cleaned"

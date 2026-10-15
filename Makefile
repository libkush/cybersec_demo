SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

VICTIM ?= $(shell cd infra && tofu output -raw victim_public_ip 2>/dev/null)

.PHONY: help init fmt validate plan up down status probe \
        attack-start attack-stop attack-logs \
        ssh-victim ssh-observer

help: ## List available targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

init: ## tofu init
	cd infra && tofu init

fmt: ## tofu fmt -recursive
	tofu fmt -recursive .

validate: ## tofu validate
	cd infra && tofu validate

plan: ## tofu plan
	cd infra && tofu plan

up: ## apply, then wait for every node to finish bootstrapping
	./scripts/up.sh

down: ## destroy the whole lab
	./scripts/down.sh

status: ## health check across all nodes
	./scripts/status.sh

probe: ## live warm-vs-cold connection probe (TUI); override with VICTIM=<ip>
	@test -n "$(VICTIM)" || { echo "could not resolve the victim IP; run 'make up' first or pass VICTIM=<ip>"; exit 1; }
	./tools/keepalive_probe.py --target $(VICTIM)

attack-start: ## start slowloris on every attacker
	./scripts/attack.sh start

attack-stop: ## stop slowloris on every attacker
	./scripts/attack.sh stop

attack-logs: ## tail the slowloris journal on every attacker
	./scripts/attack.sh logs

ssh-victim: ## shell on the victim node
	./scripts/ssh.sh victim

ssh-observer: ## shell on the observer node
	./scripts/ssh.sh observer

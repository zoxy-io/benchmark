# proxy-bench v2 — one linear ramp per proxy, local or Yandex Cloud.
#
#   make up          local: start backend + prometheus + grafana (grafana :3000)
#   make bench       local: full run — every proxy through the identical ramp
#   make smoke       local: 2-minute mini-ramp on haproxy+nginx (plumbing check)
#   make report      render results/latest -> report.html (set PROM_URL for cloud)
#   make down        local: stop everything
#   make cloud-up    terraform apply the 3-VM fleet
#   make cloud-bench rsync + run the full ramp on the fleet
#   make cloud-down  terraform destroy
#
# Knobs live in .env (copy .env.example); PROXIES/MAX_RATE/RAMP_DURATION can be
# overridden per-invocation: make bench PROXIES="zoxy haproxy"

SHELL := bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

TF ?= tofu

.PHONY: help up bench smoke report down cloud-up cloud-bench cloud-down clean

help:
	@sed -n '3,12p' $(MAKEFILE_LIST)

up:
	docker compose --profile monitoring --profile backend up -d --wait
	@echo "grafana: http://localhost:3000  prometheus: http://localhost:9090"

bench: up
	./scripts/run-all.sh

smoke: up
	MAX_RATE=2000 RAMP_DURATION=2m COOLDOWN=5 PROXIES="$${PROXIES:-haproxy nginx}" ./scripts/run-all.sh

report:
	python3 report/report.py results/latest

down:
	docker compose --profile '*' down

cloud-up:
	$(TF) -chdir=cloud init -input=false
	$(TF) -chdir=cloud apply -auto-approve

cloud-bench:
	./scripts/cloud-run.sh

cloud-down:
	$(TF) -chdir=cloud destroy -auto-approve

clean:
	rm -rf results/* .env.cloud monitoring/targets/cloud

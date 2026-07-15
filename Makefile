# proxy-bench — one open-loop linear ramp per proxy on Yandex Cloud.
#
#   make cloud-up    terraform apply the fleet (loadgen + proxy + backend)
#   make cloud-bench build + ramp every proxy (zrk); writes NDJSON + report
#   make report      render results/latest -> report.html
#   make cloud-down  terraform destroy
#   make up / down   local: start/stop backend + prometheus + grafana
#
# Knobs live in .env (copy .env.example); PROXIES / MAX_RATE / RAMP_SECONDS /
# CONNECTIONS override per-invocation: make cloud-bench PROXIES=zoxy

SHELL := bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

TF ?= tofu

.PHONY: help up down report cloud-up cloud-bench cloud-down clean

help:
	@sed -n '3,7p' $(MAKEFILE_LIST)

up:
	docker compose --profile monitoring --profile backend up -d --wait
	@echo "grafana: http://localhost:3000  prometheus: http://localhost:9090"

down:
	docker compose --profile '*' down

cloud-up:
	$(TF) -chdir=cloud init -input=false
	$(TF) -chdir=cloud apply -auto-approve

cloud-bench:
	./scripts/zrk-bench.sh

# uses the prometheus URL recorded in the run's meta.json (override: PROM_URL=...)
report:
	python3 report/report.py results/latest

cloud-down:
	$(TF) -chdir=cloud destroy -auto-approve

clean:
	rm -rf results/* .env.cloud monitoring/targets/cloud

# zoxy-benchmark — one-shot multi-host proxy benchmark on Yandex Cloud.
#
#   make image   build the NixOS qcow2 and push it to Yandex Object Storage
#   make up      terraform apply: VPC + loadgen/proxy/backend/control VMs
#   make bench   run the full matrix against each proxy, collect metrics
#   make report  render tables + plots from the latest results/<ts>/
#   make down    terraform destroy
#   make fmt     format tofu + nix
#
# All heavy lifting lives in scripts/ so the targets stay declarative.

SHELL := bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

TF        ?= tofu
TF_DIR    := terraform
PROXIES   ?= zoxy haproxy envoy traefik caddy

.PHONY: all image up bench report down fmt clean help

help:
	@sed -n '3,12p' $(MAKEFILE_LIST)

image:
	./scripts/build-image.sh          # nix build .#image + aws s3 cp to the bucket

up:
	$(TF) -chdir=$(TF_DIR) init -input=false
	$(TF) -chdir=$(TF_DIR) apply -auto-approve
	$(TF) -chdir=$(TF_DIR) output -json > $(TF_DIR)/inventory.json
	@echo "fleet up — inventory written to $(TF_DIR)/inventory.json"

bench:
	./scripts/run.sh --proxies "$(PROXIES)"

report:
	./scripts/report.py results/latest

down:
	$(TF) -chdir=$(TF_DIR) destroy -auto-approve

fmt:
	$(TF) -chdir=$(TF_DIR) fmt
	nix fmt 2>/dev/null || true

clean:
	rm -rf result result-* $(TF_DIR)/inventory.json

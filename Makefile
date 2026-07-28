# proxy-bench — one open-loop linear ramp per proxy on Yandex Cloud.
#
# The benchmark itself runs as an unattended nightly (.github/workflows/
# nightly.yml): CI creates an ephemeral fleet with no public IPs, the loadgen
# drives itself, results come back through Object Storage, and the fleet is
# destroyed. These targets are the local/manual half of that.
#
#   make build       build the bench binary (static musl)
#   make test        bench unit tests
#   make gate        prove the measurement port against the old Python (from git)
#   make report      render results/latest -> report.json + report.html
#   make up / down   local: start/stop the backend origin
#
# Ramp parameters are NOT knobs any more — they are compiled into
# bench/src/profile.zig as the c1k and c10k profiles, because eleven env vars
# with silent fallbacks is how a real run ended up with TIMEOUT_S=0 against a
# documented 1 and nothing noticed.

SHELL := bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

ZIG ?= zig
ZIG_TARGET ?= x86_64-linux-musl
# The vendored copies of the pinned zrk/zio packages, so a build needs no network.
ZIG_PKG ?= zig-pkg
PROFILE ?= c1k
RUN ?= results/latest

.PHONY: help build test gate report up down clean

help:
	@sed -n '8,13p' $(MAKEFILE_LIST)

build:
	cd bench && $(ZIG) build -Doptimize=ReleaseFast -Dtarget=$(ZIG_TARGET) --system $(ZIG_PKG)
	@echo "built bench/zig-out/bin/bench ($(ZIG_TARGET))"

test:
	cd bench && $(ZIG) build test --system $(ZIG_PKG) --summary all

# The gate that proved the measurement port: diff `bench report` against the OLD
# report/report.py over real run directories. Those .py files were deleted once
# the port was proven, so the reference is extracted from the last commit that
# carried them — the gate stays runnable forever without the dead Python living
# in the tree. It stubs Prometheus (report.py crashes without one, and that fleet
# is gone) and works on copies, so archived runs are never modified.
GATE_REF ?= 18a78b1
gate:
	tmp=$$(mktemp -d)
	trap 'rm -rf "$$tmp"' EXIT
	for f in report.py charts.py hdr.py; do
	  git show $(GATE_REF):report/$$f > "$$tmp/$$f"
	done
	BENCH_REPORT_PY="$$tmp" python3 bench/tools/gate.py $(wildcard results/zrk-2026*)

report:
	cd bench && $(ZIG) build --system $(ZIG_PKG)
	bench/zig-out/bin/bench report $(RUN) --profile $(PROFILE)

# The origin alone — enough to poke at a proxy by hand. There is no monitoring
# profile any more: Prometheus and Grafana are gone, and the driver samples the
# proxy's cAdvisor directly into each run's artifacts.
up:
	docker compose --profile backend up -d --wait

down:
	docker compose --profile '*' down

clean:
	rm -rf results/* .env.cloud bench/zig-out bench/.zig-cache

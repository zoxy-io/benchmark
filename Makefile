# proxy-bench — one open-loop linear ramp per proxy on Yandex Cloud.
#
# The benchmark itself runs as an unattended nightly (.github/workflows/
# nightly.yml): CI creates an ephemeral fleet with no public IPs, the loadgen
# drives itself, results come back through Object Storage, and the fleet is
# destroyed. These targets are the local/manual half of that.
#
#>  make build       build the bench binary (static musl)
#>  make test        bench unit tests
#>  make smoke       the CI gate: a ~90s local run of the whole suite
#>  make local       run the benchmark on THIS machine (see the caveat below)
#>  make report      render results/latest -> report.json + report.html
#>  make up / down   local: start/stop the backend origin pool (all four)
#
# Ramp parameters are NOT knobs any more — they are compiled into
# bench/src/profile.zig as the c100, c1k, c1k-tls, c10k and smoke profiles,
# because eleven env vars with silent fallbacks is how a real run ended up with
# TIMEOUT_S=0 against a documented 1 and nothing noticed.
#
# `make local PROFILE=c1k-tls` runs the TLS profile: the suite generates the
# proxies' certificate into ./proxies/tls (gitignored) on first use and every
# proxy grows a TLS listener for that profile only.

SHELL := bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

# These targets run the SAME zig invocations as .github/workflows/ci.yml and
# nightly.yml, deliberately. They used to pass `--system zig-pkg` while CI did
# not — two build paths, one of them untested, pointing at a directory that is
# gitignored and that nothing in the repo ever created. Zig quietly fell back
# to the global cache, which is why nobody noticed the flag did nothing.

ZIG ?= zig
ZIG_TARGET ?= x86_64-linux-musl
# SIMD for the load generator. A named target alone implies a BASELINE cpu, and
# `bench` embeds zrk — so without this the thing generating the load was pure
# SSE2 (measured: zero ymm, zero zmm) while the proxies it measures are compiled
# for the host. A loadgen that cannot keep up understates every proxy.
#
# NOT `native`: this binary is compiled on the CI runner and executed on the
# loadgen VM, which are different machines. Baking in the runner's cpu features
# risks SIGILL on the VM and would take a whole night with it. x86_64_v3 (AVX2,
# FMA, BMI2) is satisfied by every current x86_64 server including the fleet's
# Ice Lake, so it is safe to cross-compile for.
#
# x86_64_v4 would add AVX-512, which Ice Lake does have — but AMD EPYC before
# Genoa does not, so raising this is a deliberate bet on the platform the VMs
# land on, not a free upgrade.
ZIG_CPU ?= x86_64_v3
PROFILE ?= c1k
RUN ?= results/latest
LOCAL_PROXIES ?= zoxy

.PHONY: help build test smoke local report up down clean

# Keyed off the `#>` marker rather than a line range: `sed -n '8,13p'` printed
# whatever happened to be on those lines, so adding a comment anywhere above
# silently turned `make help` into something else.
help:
	@grep '^#>' $(MAKEFILE_LIST) | cut -c4-

build:
	cd bench && $(ZIG) build -Doptimize=ReleaseFast -Dtarget=$(ZIG_TARGET) -Dcpu=$(ZIG_CPU)
	@echo "built bench/zig-out/bin/bench ($(ZIG_TARGET) cpu=$(ZIG_CPU))"

test:
	cd bench && $(ZIG) build test --summary all


# A whole run against this machine's docker daemon — no cloud, no ssh, ~6 min
# for one profile. NOT a benchmark result: the generator shares CPU, cache and
# memory bandwidth with the proxy it is measuring, and the fleet's network is
# replaced by loopback, which removes a network ceiling the cloud path sits
# near. It exists to iterate on the harness, a proxy config or the report
# without paying cloud time. Everything downstream knows — the run records
# fleet=local, the report is banner-marked, and `bench index` keeps it out of
# the trend.
local: build
	bench/zig-out/bin/bench suite --local --profile $(PROFILE) \
	  --proxies $(LOCAL_PROXIES) --runid local-$$(date -u +%Y%m%d-%H%M%S)

# What .github/workflows/ci.yml's `smoke` job runs, so a failure there can be
# reproduced here in one command. The `smoke` profile is a real ramp (30s,
# 200 -> 5000 req/s) sized for a machine that is also hosting the proxy and the
# origin pool. nginx and haproxy only: both are stock images, so nothing is
# compiled. It exercises the harness, not the proxies — bring-up, the warm
# probe, the ramp, cAdvisor identity, teardown, report. It is NOT a measurement
# and profile.zig has a test asserting it can never become one.
smoke: build
	bench/zig-out/bin/bench suite --local --profile smoke \
	  --proxies nginx,haproxy --runid smoke-$$(date -u +%Y%m%d-%H%M%S)

report:
	cd bench && $(ZIG) build
	bench/zig-out/bin/bench report $(RUN) --profile $(PROFILE)

# The origin alone — enough to poke at a proxy by hand. There is no monitoring
# profile any more: Prometheus and Grafana are gone, and the driver samples the
# proxy's cAdvisor directly into each run's artifacts.
up:
	docker compose --profile backend up -d --wait

down:
	docker compose --profile '*' down

clean:
	rm -rf results/* bench/zig-out bench/.zig-cache

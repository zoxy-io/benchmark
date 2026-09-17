# proxy-bench — one open-loop linear ramp per proxy on Yandex Cloud.
# The real run is the nightly (.github/workflows/nightly.yml); these targets
# are the local/manual half.
#
#>  make build       build the bench binary (static musl)
#>  make test        bench unit tests
#>  make smoke       the CI gate: a ~90s local run of the whole suite
#>  make local       run the benchmark on THIS machine (see the caveat below)
#>  make report      render results/latest -> report.json + report.html
#>  make up / down   local: start/stop the backend origin pool (all four)
#
# Ramp parameters are profiles compiled into bench/src/profile.zig, not env
# knobs. `make local PROFILE=c1k-tls` runs the TLS profile.

SHELL := bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

# Same zig invocations as .github/workflows/ci.yml and nightly.yml.

ZIG ?= zig
ZIG_TARGET ?= x86_64-linux-musl
# SIMD for the loadgen (it embeds zrk), but not `native`: built on the CI
# runner, run on the VM. x86_64_v4 would exclude pre-Genoa EPYC.
ZIG_CPU ?= x86_64_v3
PROFILE ?= c1k
RUN ?= results/latest
LOCAL_PROXIES ?= zoxy

.PHONY: help build test smoke local report up down clean

# Keyed off the `#>` marker, so edits above cannot shift the help text.
help:
	@grep '^#>' $(MAKEFILE_LIST) | cut -c4-

build:
	cd bench && $(ZIG) build -Doptimize=ReleaseFast -Dtarget=$(ZIG_TARGET) -Dcpu=$(ZIG_CPU)
	@echo "built bench/zig-out/bin/bench ($(ZIG_TARGET) cpu=$(ZIG_CPU))"

test:
	cd bench && $(ZIG) build test --summary all


# Full run against local docker, ~6 min per profile. Not a benchmark result
# (shared CPU, loopback): recorded as fleet=local and kept out of the trend.
local: build
	bench/zig-out/bin/bench suite --local --profile $(PROFILE) \
	  --proxies $(LOCAL_PROXIES) --runid local-$$(date -u +%Y%m%d-%H%M%S)

# Reproduces ci.yml's `smoke` job: harness only, stock images, never a
# measurement (profile.zig asserts it).
smoke: build
	bench/zig-out/bin/bench suite --local --profile smoke \
	  --proxies nginx,haproxy --runid smoke-$$(date -u +%Y%m%d-%H%M%S)

report:
	cd bench && $(ZIG) build
	bench/zig-out/bin/bench report $(RUN) --profile $(PROFILE)

# The origin pool alone, for poking at a proxy by hand.
up:
	docker compose --profile backend up -d --wait

down:
	docker compose --profile '*' down

clean:
	rm -rf results/* bench/zig-out bench/.zig-cache

# zoxy has no published image or release binaries — build from source at a
# pinned ref. ReleaseSafe matches upstream's ship configuration (TigerStyle).
#
# The BUILD always runs natively on the build host and Zig cross-compiles to
# the target when they differ — emulating the compiler is both slow and
# broken (zig segfaults under Rosetta). The libxev rewrite has no vendored
# OpenSSL, so the image itself is no longer x86_64-only.
#
# NOTE: the container must run under seccomp-iouring.json (wired in compose):
# Docker's default seccomp profile denies io_uring_* since engine 25.0, and
# zoxy's event loop (libxev's Linux backend) is io_uring.
FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS build
ARG ZOXY_REF=main
ARG ZIG_VERSION=0.16.0
ARG BUILDARCH
ARG TARGETARCH
# Benchmark-only override of zoxy's compile-time relay-buffer pool (the L4
# concurrency cap). LEGACY on phase-1: the L7 path is bounded instead by the
# comptime-derived conn_slots_max (~1020) plus the shared upstream keep-alive
# pool, and relay_buffers_max is no longer a numeric literal (`= conn_slots_max`)
# — so the sed guard below fails loudly if this is set against a phase-1 ref.
# Leave EMPTY for L7 runs (the default); kept only for L4-listener A/B builds.
# Empty = upstream default; the image tag carries the value when set.
ARG RELAY_BUFFERS_MAX=
# Benchmark-only override of the compile-time upstream-pool ceiling (default
# 1024). conn_slots_max is a HARDCODED literal derived from this value (via
# the shared io_uring completion-queue budget — more upstream slots leaves
# less queue for conn slots) and asserted self-consistent at comptime, so
# both must be set together to the exact correct pair or the build fails
# loudly rather than silently drifting. Leave EMPTY for the compiled default.
ARG UPSTREAM_SLOTS_MAX=
ARG CONN_SLOTS_MAX=
# Benchmark-only override of the max L7 request/response head (default 8KiB;
# also floors the upstream buffer, upstream_bytes >= head_bytes_max). Smaller
# heads shrink the per-conn-slot and per-upstream-slot memory footprint —
# less to touch per event-loop pass at a given pool size. Value is a KiB
# coefficient (the source literal is `N * 1024`); comptime-asserted >= 1024
# bytes, i.e. N >= 1. A request/response head over the new bound gets a
# 414/431/torn-down exchange instead of served — fine for this bench's plain
# GETs and small canned bodies, not a safe default for arbitrary traffic.
ARG HEAD_BYTES_MAX_KIB=

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN case "$BUILDARCH" in \
        amd64) zigarch=x86_64 ;; \
        arm64) zigarch=aarch64 ;; \
        *) echo "unsupported build arch: $BUILDARCH" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zigarch}-linux-${ZIG_VERSION}.tar.xz" \
       | tar -xJ -C /opt \
    && ln -s /opt/zig-*/zig /usr/local/bin/zig

# Cache-bust keyed on what $ZOXY_REF currently POINTS AT, not on its name.
#
# The nightly builds `main` on purpose — the whole point is to catch a zoxy
# regression the morning after it lands. But a bare `git clone` layer caches on
# the command string, and "main" never changes as a string, so every subsequent
# build would reuse the first checkout and the benchmark would quietly measure a
# frozen commit forever while reporting it as main.
#
# `ADD` of a URL re-fetches on every build and busts the cache exactly when its
# CONTENT changes — so the clone is reused while main is unchanged and redone
# the moment it moves. Cheap and precise, where --no-cache would also throw away
# the zig toolchain download.
ADD https://api.github.com/repos/zoxy-io/zoxy/commits/$ZOXY_REF /tmp/zoxy-head.json

RUN git clone https://github.com/zoxy-io/zoxy /src \
    && git -C /src checkout "$ZOXY_REF" \
    && git -C /src rev-parse HEAD > /zoxy-commit \
    && echo "built zoxy $ZOXY_REF -> $(cat /zoxy-commit)"

WORKDIR /src
# Benchmark override: bump the relay-buffer pool (only the declaration line,
# not the formula/assert references). Fail loudly if the line moved.
RUN if [ -n "$RELAY_BUFFERS_MAX" ]; then \
        grep -qE 'relay_buffers_max: u32 = [0-9]+' src/constants.zig \
          || { echo "relay_buffers_max decl not found — constants.zig changed" >&2; exit 1; }; \
        sed -i -E "s/(relay_buffers_max: u32 = )[0-9]+/\1${RELAY_BUFFERS_MAX}/" src/constants.zig; \
        echo "patched: $(grep -E 'pub const relay_buffers_max' src/constants.zig)"; \
    fi

# Both or neither: upstream_slots_max and conn_slots_max are asserted
# self-consistent at comptime (see constants.zig's comptime block), so a
# lone override just moves the build failure from "clear mismatch" to
# "confusing partial patch". zig build below is the actual correctness
# check — this only guards against patching a moved/renamed declaration.
RUN if [ -n "$UPSTREAM_SLOTS_MAX" ] || [ -n "$CONN_SLOTS_MAX" ]; then \
        if [ -z "$UPSTREAM_SLOTS_MAX" ] || [ -z "$CONN_SLOTS_MAX" ]; then \
            echo "UPSTREAM_SLOTS_MAX and CONN_SLOTS_MAX must be set together" >&2; exit 1; \
        fi; \
        grep -qE 'upstream_slots_max: u32 = [0-9]+' src/constants.zig \
          || { echo "upstream_slots_max decl not found — constants.zig changed" >&2; exit 1; }; \
        grep -qE 'conn_slots_max: u32 = [0-9]+' src/constants.zig \
          || { echo "conn_slots_max decl not found — constants.zig changed" >&2; exit 1; }; \
        sed -i -E "s/(upstream_slots_max: u32 = )[0-9]+/\1${UPSTREAM_SLOTS_MAX}/" src/constants.zig; \
        sed -i -E "s/(conn_slots_max: u32 = )[0-9]+/\1${CONN_SLOTS_MAX}/" src/constants.zig; \
        echo "patched: $(grep -E 'pub const upstream_slots_max|pub const conn_slots_max' src/constants.zig)"; \
    fi

RUN if [ -n "$HEAD_BYTES_MAX_KIB" ]; then \
        grep -qE 'head_bytes_max: u32 = [0-9]+ \* 1024' src/constants.zig \
          || { echo "head_bytes_max decl not found — constants.zig changed" >&2; exit 1; }; \
        sed -i -E "s/(head_bytes_max: u32 = )[0-9]+( \* 1024)/\1${HEAD_BYTES_MAX_KIB}\2/" src/constants.zig; \
        echo "patched: $(grep -E 'pub const head_bytes_max' src/constants.zig)"; \
    fi

# Optimize mode. Default ReleaseFast for PARITY with the other proxies, which
# all ship fully optimized (pingora `cargo build --release`, haproxy/nginx/envoy
# release) — ReleaseSafe keeps Zig's bounds/overflow/alignment checks on the hot
# path, a per-op CPU tax the others don't pay, which would handicap zoxy in a
# performance comparison. Set ZOXY_OPTIMIZE=ReleaseSafe to bench zoxy's actual
# TigerStyle ship configuration instead.
ARG ZOXY_OPTIMIZE=ReleaseFast
# Same-arch: plain native build (native CPU features — what the cloud fleet
# gets). Cross: baseline target — fine for the local smoke tier, not for
# quotable numbers.
# BASELINE cpu target, always — never `-mcpu=native`.
#
# The comparison includes haproxy, which ships as the stock upstream image and is
# therefore compiled for a generic x86-64 baseline with no AVX at all. Building
# zoxy with the host's AVX2/AVX-512 while haproxy runs SSE2 would hand zoxy a
# large advantage that has nothing to do with its proxying, so every proxy here
# targets the same generic baseline — which is also what a package or registry
# image gives you in practice.
#
# The effective target is RECORDED either way. `bench suite` reads it into
# profile.json, so if this ever drifts back to native the artifact says so rather
# than the run completing and the number simply being wrong.
# Built exactly as zoxy's own release workflow builds it:
#
#   zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast
#
# That means the benchmark measures the artifact users actually download, and it
# settles the CPU-parity question for free: a named target implies a BASELINE cpu
# model, matching haproxy's stock upstream image (a generic x86-64 build with no
# AVX at all). Building zoxy with the host's AVX2/AVX-512 while haproxy runs SSE2
# would be a large advantage that has nothing to do with proxying.
#
# Static musl also removes the system-OpenSSL link that made a native build
# awkward to pin to a baseline cpu.
#
# The effective target is RECORDED, so if this ever drifts the artifact says so
# rather than the run completing with a quietly incomparable number.
RUN case "$TARGETARCH" in \
        amd64) ztarget=x86_64-linux-musl ;; \
        arm64) ztarget=aarch64-linux-musl ;; \
        *) echo "unsupported target arch: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && zig build -Doptimize=$ZOXY_OPTIMIZE -Dtarget="$ztarget" \
    && echo "release-parity $ZOXY_OPTIMIZE $ztarget (baseline cpu)" > /zoxy-build

FROM debian:bookworm-slim
COPY --from=build /src/zig-out/bin/zoxy /usr/local/bin/zoxy
COPY --from=build /zoxy-commit /etc/zoxy/zoxy-commit
COPY --from=build /zoxy-build /etc/zoxy/build-info
# zoxy (libxev) rejects hostname endpoints — the entrypoint resolves the
# `backend` upstream once at container start and renders the IP literal into
# /etc/zoxy/config.json from the mounted template (see entrypoint.sh).
# NOTE: with a moving ZOXY_REF like libxev the git clone layer is cached;
# rebuild with --no-cache (or pin a commit sha) to pick up upstream commits.
COPY entrypoint.sh /usr/local/bin/zoxy-entrypoint
ENTRYPOINT ["/usr/local/bin/zoxy-entrypoint"]

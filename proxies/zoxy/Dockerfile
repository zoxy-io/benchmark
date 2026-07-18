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

RUN git clone https://github.com/zoxy-io/zoxy /src \
    && git -C /src checkout "$ZOXY_REF" \
    && git -C /src rev-parse HEAD > /zoxy-commit

WORKDIR /src
# Benchmark override: bump the relay-buffer pool (only the declaration line,
# not the formula/assert references). Fail loudly if the line moved.
RUN if [ -n "$RELAY_BUFFERS_MAX" ]; then \
        grep -qE 'relay_buffers_max: u32 = [0-9]+' src/constants.zig \
          || { echo "relay_buffers_max decl not found — constants.zig changed" >&2; exit 1; }; \
        sed -i -E "s/(relay_buffers_max: u32 = )[0-9]+/\1${RELAY_BUFFERS_MAX}/" src/constants.zig; \
        echo "patched: $(grep -E 'pub const relay_buffers_max' src/constants.zig)"; \
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
RUN if [ "$BUILDARCH" = "$TARGETARCH" ]; then \
        zig build -Doptimize=$ZOXY_OPTIMIZE; \
    else \
        case "$TARGETARCH" in \
            amd64) ztarget=x86_64-linux-gnu ;; \
            arm64) ztarget=aarch64-linux-gnu ;; \
            *) echo "unsupported target arch: $TARGETARCH" >&2; exit 1 ;; \
        esac \
        && zig build -Doptimize=$ZOXY_OPTIMIZE -Dtarget="$ztarget"; \
    fi

FROM debian:bookworm-slim
COPY --from=build /src/zig-out/bin/zoxy /usr/local/bin/zoxy
COPY --from=build /zoxy-commit /etc/zoxy/zoxy-commit
# zoxy (libxev) rejects hostname endpoints — the entrypoint resolves the
# `backend` upstream once at container start and renders the IP literal into
# /etc/zoxy/config.json from the mounted template (see entrypoint.sh).
# NOTE: with a moving ZOXY_REF like libxev the git clone layer is cached;
# rebuild with --no-cache (or pin a commit sha) to pick up upstream commits.
COPY entrypoint.sh /usr/local/bin/zoxy-entrypoint
ENTRYPOINT ["/usr/local/bin/zoxy-entrypoint"]

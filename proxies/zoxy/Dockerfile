# zoxy has no published image or release binaries — build from source at a
# pinned ref. ReleaseSafe matches upstream's ship configuration (TigerStyle).
#
# The BUILD always runs natively on the build host and Zig cross-compiles to
# the target when they differ — emulating the compiler is both slow and
# broken (zig segfaults under Rosetta).
#
# phase-3a-ztls (TLS termination, PR landing 2026-07-25) makes every zoxy
# build link libcrypto: the ztls engine is a Zig protocol layer over
# libcrypto primitives (`zoxy_module.linkSystemLibrary("crypto")` in
# build.zig, unconditional — a plain L4/L7 build pays for it too). This
# reverses the prior "no vendored OpenSSL" state: both the build stage
# (headers+lib to link against) and the runtime stage (the .so to dlopen)
# now need libssl installed — see below. Cross-arch (BUILDARCH != TARGETARCH)
# is UNTESTED against this dependency: apt only installs libssl-dev for the
# build host's arch, not the target's, so a foreign-arch TLS build would need
# dpkg multiarch (`libssl-dev:$TARGETARCH`) to link correctly — the cloud
# fleet always builds native (image built on the VM it runs on), so this
# hasn't been exercised.
#
# base image is debian:trixie-slim, NOT bookworm: ztls (zoxy-io/ztls fork,
# branch deterministic-ecdsa) calls OSSL_SIGNATURE_PARAM_NONCE_TYPE for its
# RFC 6979 deterministic-nonce signing path, an OpenSSL 3.2+ constant.
# bookworm's libssl-dev is 3.0.20 — build fails with "cimport has no member
# named OSSL_SIGNATURE_PARAM_NONCE_TYPE". trixie ships 3.5.6. Both stages
# must match (build links against trixie's libcrypto.so.3, so the runtime
# stage needs trixie's libssl3 too, not bookworm's).
#
# NOTE: the container must run under seccomp-iouring.json (wired in compose):
# Docker's default seccomp profile denies io_uring_* since engine 25.0, and
# zoxy's event loop (libxev's Linux backend) is io_uring.
FROM --platform=$BUILDPLATFORM debian:trixie-slim AS build
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
    && apt-get install -y --no-install-recommends ca-certificates curl git xz-utils libssl-dev \
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

FROM debian:trixie-slim
# libssl3: runtime libcrypto for the ztls engine (phase-3a-ztls links it
# unconditionally — see the build-stage comment above). Must be trixie, same
# reason as the build stage: bookworm's OpenSSL is too old for this ztls fork.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libssl3 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/zig-out/bin/zoxy /usr/local/bin/zoxy
COPY --from=build /zoxy-commit /etc/zoxy/zoxy-commit
# zoxy (libxev) rejects hostname endpoints — the entrypoint resolves the
# `backend` upstream once at container start and renders the IP literal into
# /etc/zoxy/config.json from the mounted template (see entrypoint.sh).
# NOTE: with a moving ZOXY_REF like libxev the git clone layer is cached;
# rebuild with --no-cache (or pin a commit sha) to pick up upstream commits.
COPY entrypoint.sh /usr/local/bin/zoxy-entrypoint
ENTRYPOINT ["/usr/local/bin/zoxy-entrypoint"]

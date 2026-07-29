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
# The effective cpu model is RECORDED. `bench suite` reads it into profile.json,
# so the report can state what each proxy was actually compiled for instead of
# leaving it to be guessed.
#
# Static musl, as zoxy's own release workflow builds it, but with SIMD ENABLED:
#
#   zig build -Dtarget=x86_64-linux-musl -Dcpu=<model> -Doptimize=ReleaseFast
#
# zoxy ships SIMD-enabled binaries, so a baseline build would measure something
# no user runs. `native` matches the host the benchmark runs on; pin ZOXY_CPU to
# a concrete model (e.g. `icelake_server`, `x86_64_v3`) for a build that is
# reproducible off this machine.
#
# This deliberately gives up the CPU parity a baseline build bought against
# haproxy's stock upstream image, which is a generic x86-64 build with no AVX.
# zoxy and pingora are compiled here and get the host's AVX2/AVX-512; haproxy
# does not. That asymmetry is REAL and must be read with the numbers, not
# forgotten — build-info records the effective model for every proxy so the
# report can state it rather than leaving it to be discovered.
#
# Static musl also removes the system-OpenSSL link that made a native build
# awkward to pin.
ARG ZOXY_CPU=native
RUN case "$TARGETARCH" in \
        amd64) ztarget=x86_64-linux-musl ;; \
        arm64) ztarget=aarch64-linux-musl ;; \
        *) echo "unsupported target arch: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && zig build -Doptimize=$ZOXY_OPTIMIZE -Dtarget="$ztarget" -Dcpu="$ZOXY_CPU" \
    && echo "release-parity $ZOXY_OPTIMIZE $ztarget cpu=$ZOXY_CPU (SIMD)" > /zoxy-build

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

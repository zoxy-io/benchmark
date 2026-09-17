# zoxy publishes no image. ZOXY_FLAVOUR (set by `bench` from profile.zig's
# `zoxy_ref`) picks the build:
#   release  published tarball for tag $ZOXY_REF, sha256-verified; the binary
#            users download (ReleaseSafe/ReleaseFast static musl, x86_64_v3).
#   source   git clone + `zig build` at $ZOXY_REF, for branches/PRs/commits.
#            Slower and network-fragile (run 30749146321 lost zoxy).
# Must run under seccomp-iouring.json: Docker's default profile denies io_uring.
ARG ZOXY_FLAVOUR=source

# ------------------------------------------------------------------ release --
# busybox only: wget, sha256sum and tar are in the base.
FROM alpine:3 AS build-release
ARG ZOXY_REF
ARG TARGETARCH
WORKDIR /dl
# Asset arch names are Zig's (x86_64/aarch64), not Docker's.
# The grep is required: busybox `sha256sum -c` passes an empty checksum file.
# Commit and optimize mode are read from the artifact, never asserted (a
# ReleaseSafe binary was once labelled ReleaseFast, zoxy 1573c16). ReleaseSafe
# binaries contain safety-check panic strings. `tr` range is spelled out:
# busybox `tr -c '[:print:]'` silently matches nothing. Check: v0.1.0 reads
# ReleaseFast, v0.2.1 ReleaseSafe.
RUN set -eu; \
    v="${ZOXY_REF#v}"; \
    case "$TARGETARCH" in \
        amd64) zarch=x86_64 ;; \
        arm64) zarch=aarch64 ;; \
        *) echo "unsupported target arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    tgz="zoxy-$v-$zarch-linux.tar.gz"; \
    base="https://github.com/zoxy-io/zoxy/releases/download/v$v"; \
    wget -q "$base/$tgz"; \
    wget -q "$base/SHA256SUMS.txt"; \
    grep -F " $tgz" SHA256SUMS.txt > sum.txt; \
    sha256sum -c sum.txt; \
    mkdir -p /out; \
    tar xzf "$tgz" -C /out zoxy; \
    wget -qO /out/zoxy-commit --header 'Accept: application/vnd.github.sha' \
        "https://api.github.com/repos/zoxy-io/zoxy/commits/v$v"; \
    if tr -c '\040-\176' '\n' < /out/zoxy \
        | grep -q -e 'index out of bounds' -e 'reached unreachable code' \
                  -e 'integer overflow'; then \
        mode=ReleaseSafe; \
    else \
        mode=ReleaseFast; \
    fi; \
    echo "upstream release v$v $zarch-linux $mode cpu=x86_64_v3 (SIMD, sha256-verified, mode read from the artifact)" \
        > /out/build-info

# ------------------------------------------------------------------- source --
# Build natively and let Zig cross-compile (zig segfaults under emulation).
# Toolchain image from proxies/zig; `bench suite` ensures it exists.
FROM --platform=$BUILDPLATFORM zoxy-bench/zig:0.16.0 AS build-source
ARG ZOXY_REF=main
ARG BUILDARCH
ARG TARGETARCH

# Bust the clone cache when $ZOXY_REF's commit changes, not its name, so `main`
# is never silently frozen.
ADD https://api.github.com/repos/zoxy-io/zoxy/commits/$ZOXY_REF /tmp/zoxy-head.json

RUN git clone https://github.com/zoxy-io/zoxy /src \
    && git -C /src checkout "$ZOXY_REF" \
    && git -C /src rev-parse HEAD > /zoxy-commit \
    && echo "built zoxy $ZOXY_REF -> $(cat /zoxy-commit)"

WORKDIR /src
# Default ReleaseFast, like the other proxies; upstream releases ship
# ReleaseSafe (~13% slower on c1k). ZOXY_OPTIMIZE=ReleaseSafe gives a
# controlled A/B. The mode is recorded from this argument.
ARG ZOXY_OPTIMIZE=ReleaseFast
# Static musl with SIMD. ZOXY_CPU=native matches the host (cross builds get a
# baseline, smoke tier only); `x86_64_v3` matches the release flavour.
# Not CPU-matched with stock haproxy (generic x86-64): build-info records the
# model and `bench suite` puts it in profile.json.
ARG ZOXY_CPU=native
RUN case "$TARGETARCH" in \
        amd64) ztarget=x86_64-linux-musl ;; \
        arm64) ztarget=aarch64-linux-musl ;; \
        *) echo "unsupported target arch: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && zig build -Doptimize=$ZOXY_OPTIMIZE -Dtarget="$ztarget" -Dcpu="$ZOXY_CPU" \
    && mkdir -p /out \
    && cp /src/zig-out/bin/zoxy /out/zoxy \
    && cp /zoxy-commit /out/zoxy-commit \
    && echo "release-parity $ZOXY_OPTIMIZE $ztarget cpu=$ZOXY_CPU (SIMD)" > /out/build-info

# ------------------------------------------------------------------ runtime --
# Both flavours produce the same /out files; `bench` records zoxy-commit and
# build-info in profile.json.
FROM build-${ZOXY_FLAVOUR} AS build

FROM debian:bookworm-slim
COPY --from=build /out/zoxy /usr/local/bin/zoxy
COPY --from=build /out/zoxy-commit /etc/zoxy/zoxy-commit
COPY --from=build /out/build-info /etc/zoxy/build-info
# Entrypoint resolves backends to IP literals and renders config.json.
COPY entrypoint.sh /usr/local/bin/zoxy-entrypoint
ENTRYPOINT ["/usr/local/bin/zoxy-entrypoint"]

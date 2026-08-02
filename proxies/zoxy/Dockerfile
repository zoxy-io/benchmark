# zoxy publishes no image, so this builds one — from an upstream RELEASE
# TARBALL or from source at a ref. `ZOXY_FLAVOUR` picks which, and `bench` sets
# it from the ref it was asked for (profile.zig's `zoxy_ref`):
#
#   release   the published tarball for tag $ZOXY_REF, sha256-verified against
#             that release's own SHA256SUMS.txt. Seconds, no toolchain, no
#             dependency fetch — and it measures precisely the binary a user
#             downloads, which is the same standing the stock haproxy, nginx and
#             envoy images have in this comparison.
#   source    git clone + `zig build` at $ZOXY_REF. The only way to bench a
#             branch, a PR, or a commit that has not shipped. Costs 90-180s on
#             the fleet, needs the proxies/zig toolchain image, and fetches four
#             git dependencies over the fleet's NAT egress — a transient failure
#             in any of that loses zoxy for the night, which is what happened to
#             run 30749146321.
#
# The flavours are closer than they look: upstream's release workflow builds
# ReleaseFast static musl with -Dcpu=x86_64_v3, so a release binary differs from
# the default source build only in cpu model (v3 vs this host's `native`).
#
# BuildKit builds only the stages the target actually needs, so `release` never
# resolves the zig toolchain image and `source` never pulls alpine.
#
# NOTE: the container must run under seccomp-iouring.json (wired in compose):
# Docker's default seccomp profile denies io_uring_* since engine 25.0, and
# zoxy's event loop (libxev's Linux backend) is io_uring.
ARG ZOXY_FLAVOUR=source

# ------------------------------------------------------------------ release --
# busybox only — wget, sha256sum and tar are all in the base, so there is no apk
# step and the sole network dependency is github.com.
FROM alpine:3 AS build-release
ARG ZOXY_REF
ARG TARGETARCH
WORKDIR /dl
# The arch names on the release assets are Zig's (x86_64/aarch64), not Docker's
# (amd64/arm64) — the same translation the source stage does for -Dtarget, for
# the same reason: this image is built for whatever host it lands on.
#
# `sha256sum -c` is the gate. `grep` supplies its input and fails the build when
# the asset is not listed at all, which matters more than it looks: an empty
# checksum file is something busybox's `-c` accepts quietly, so without the grep
# a renamed or missing asset would verify "successfully" against nothing.
#
# The commit is RESOLVED, not asserted — `bench` compares it against its own
# resolution of the same ref to decide whether the build is stale, and two
# copies of a build argument would agree by construction rather than by fact.
# For a tag these are the same answer twice; a tag that MOVED between the two
# calls is the case this still catches.
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
    echo "upstream release v$v $zarch-linux ReleaseFast cpu=x86_64_v3 (SIMD, sha256-verified)" \
        > /out/build-info

# ------------------------------------------------------------------- source --
# The BUILD always runs natively on the build host and Zig cross-compiles to
# the target when they differ — emulating the compiler is both slow and
# broken (zig segfaults under Rosetta). The libxev rewrite has no vendored
# OpenSSL, so the image itself is no longer x86_64-only.
#
# The toolchain comes from proxies/zig, built and cached separately — it is a
# pure function of ZIG_VERSION and arch, where this image is not. See that
# Dockerfile for why the curl-per-run it replaces was a bad idea. `bench suite`
# guarantees this image exists before building zoxy from source.
FROM --platform=$BUILDPLATFORM zoxy-bench/zig:0.16.0 AS build-source
ARG ZOXY_REF=main
ARG BUILDARCH
ARG TARGETARCH

# Cache-bust keyed on what $ZOXY_REF currently POINTS AT, not on its name.
#
# Building `main` is the point of this flavour — to catch a zoxy regression the
# morning after it lands. But a bare `git clone` layer caches on the command
# string, and "main" never changes as a string, so every subsequent build would
# reuse the first checkout and the benchmark would quietly measure a frozen
# commit forever while reporting it as main.
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
# Optimize mode. Default ReleaseFast, which is BOTH what upstream's release
# workflow ships and what the other proxies here are (pingora `cargo build
# --release`, haproxy/nginx/envoy release builds). ReleaseSafe keeps Zig's
# bounds/overflow/alignment checks on the hot path, a per-op CPU tax the others
# don't pay; set ZOXY_OPTIMIZE=ReleaseSafe to measure that deliberately.
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
# reproducible off this machine — `x86_64_v3` is exactly what the release
# flavour above gets, and is the setting that makes the two comparable.
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
    && mkdir -p /out \
    && cp /src/zig-out/bin/zoxy /out/zoxy \
    && cp /zoxy-commit /out/zoxy-commit \
    && echo "release-parity $ZOXY_OPTIMIZE $ztarget cpu=$ZOXY_CPU (SIMD)" > /out/build-info

# ------------------------------------------------------------------ runtime --
# Both flavours land the same three files in /out, so nothing below this line
# knows which one ran. `bench` reads the last two off the container and puts
# them in profile.json, so every night's numbers carry the provenance of the
# binary that produced them.
FROM build-${ZOXY_FLAVOUR} AS build

FROM debian:bookworm-slim
COPY --from=build /out/zoxy /usr/local/bin/zoxy
COPY --from=build /out/zoxy-commit /etc/zoxy/zoxy-commit
COPY --from=build /out/build-info /etc/zoxy/build-info
# zoxy (libxev) rejects hostname endpoints — the entrypoint resolves the
# `backend` upstream once at container start and renders the IP literal into
# /etc/zoxy/config.json from the mounted template (see entrypoint.sh).
COPY entrypoint.sh /usr/local/bin/zoxy-entrypoint
ENTRYPOINT ["/usr/local/bin/zoxy-entrypoint"]

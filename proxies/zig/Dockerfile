# The Zig toolchain as its own image, so a nightly stops re-downloading it.
#
# zoxy has no published binary, so it is built from source and that needs a Zig
# the distros do not carry (0.16.0). It used to be fetched with curl inside
# zoxy's own build: 55 MB from ziglang.org, on every run, with no verification
# and no retry — a third-party dependency in the critical path of an unattended
# job. It cost run #21 a whole profile when tar met a truncated stream.
#
# Splitting it out fixes both halves. The toolchain is a pure function of
# ZIG_VERSION and the architecture, so unlike zoxy's floating-`main` source build
# it caches perfectly: `bench-image-cache` keeps it in Object Storage and the
# download happens only when the version is deliberately bumped.
#
# git and ca-certificates live here too, because zoxy's build stage clones from
# GitHub and there is no reason for that apt round-trip to repeat either.
FROM debian:bookworm-slim

ARG ZIG_VERSION=0.16.0
# From ziglang.org/download/index.json, alongside the tarball it describes.
# amd64 only: it is the sole architecture the fleet runs, and a checksum that is
# absent is better than one that is wrong. An arm64 build (local smoke tier only)
# skips the check rather than silently trusting a value nobody verified.
ARG ZIG_SHA256_AMD64=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    case "$TARGETARCH" in \
        amd64) zigarch=x86_64; want="$ZIG_SHA256_AMD64" ;; \
        arm64) zigarch=aarch64; want="" ;; \
        *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors --connect-timeout 20 \
        -o /tmp/zig.tar.xz \
        "https://ziglang.org/download/${ZIG_VERSION}/zig-${zigarch}-linux-${ZIG_VERSION}.tar.xz"; \
    if [ -n "$want" ]; then \
        echo "$want  /tmp/zig.tar.xz" | sha256sum -c -; \
    else \
        echo "no checksum pinned for $TARGETARCH — skipping verification" >&2; \
    fi; \
    tar -xJf /tmp/zig.tar.xz -C /opt; \
    rm -f /tmp/zig.tar.xz; \
    ln -s /opt/zig-*/zig /usr/local/bin/zig; \
    zig version

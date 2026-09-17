# Zig toolchain as its own image so it caches (bench-image-cache) instead of
# being downloaded from ziglang.org on every run (run #21 lost a profile to a
# truncated tarball). git/ca-certificates are for zoxy's clone.
FROM debian:bookworm-slim

ARG ZIG_VERSION=0.16.0
# From ziglang.org/download/index.json. amd64 only (the fleet's arch); arm64
# (local smoke) skips the check rather than trust an unverified value.
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

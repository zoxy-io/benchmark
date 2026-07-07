# zoxy has no published image or release binaries — build from source at a
# pinned ref. ReleaseSafe matches upstream's ship configuration (TigerStyle).
#
# The image is always linux/amd64 (upstream's vendored OpenSSL is x86_64-only
# and the cloud fleet is x86_64). The BUILD runs natively on whatever the
# build host is and Zig cross-compiles — emulating the compiler is both slow
# and broken (zig segfaults under Rosetta).
#
# NOTE: the container must run under seccomp-iouring.json (wired in compose):
# Docker's default seccomp profile denies io_uring_* since engine 25.0, and
# zoxy's data path is io_uring.
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

RUN git clone https://github.com/zoxy-io/zoxy /src \
    && git -C /src checkout "$ZOXY_REF" \
    && git -C /src rev-parse HEAD > /zoxy-commit

WORKDIR /src
# Same-arch: plain native build (native CPU features — what the cloud fleet
# gets). Cross: baseline x86_64 — fine for the local smoke tier, not for
# quotable numbers.
RUN if [ "$BUILDARCH" = "$TARGETARCH" ]; then \
        zig build -Doptimize=ReleaseSafe; \
    else \
        zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu; \
    fi

FROM debian:bookworm-slim
COPY --from=build /src/zig-out/bin/zoxy /usr/local/bin/zoxy
COPY --from=build /zoxy-commit /etc/zoxy/zoxy-commit
# zoxy resolves hostname endpoints itself, once at parse time (startup /
# SIGHUP reload) — `backend:9000` works like it does for the other proxies.
# NOTE: with ZOXY_REF=main the git clone layer is cached; rebuild with
# --no-cache (or pin a commit sha) to pick up new upstream commits.
ENTRYPOINT ["/usr/local/bin/zoxy", "/etc/zoxy/config.json"]

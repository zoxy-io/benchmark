# zoxy has no published image or release binaries — build from source at a
# pinned ref. ReleaseSafe matches upstream's ship configuration (TigerStyle).
#
# NOTE: the container must run under seccomp-iouring.json (wired in compose):
# Docker's default seccomp profile denies io_uring_* since engine 25.0, and
# zoxy's data path is io_uring.
FROM debian:bookworm-slim AS build
ARG ZOXY_REF=main
ARG ZIG_VERSION=0.16.0
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN case "$TARGETARCH" in \
        amd64) zigarch=x86_64 ;; \
        arm64) zigarch=aarch64 ;; \
        *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zigarch}-linux-${ZIG_VERSION}.tar.xz" \
       | tar -xJ -C /opt \
    && ln -s /opt/zig-*/zig /usr/local/bin/zig

RUN git clone https://github.com/zoxy-io/zoxy /src \
    && git -C /src checkout "$ZOXY_REF" \
    && git -C /src rev-parse HEAD > /zoxy-commit

WORKDIR /src
RUN zig build -Doptimize=ReleaseSafe
RUN zig-out/bin/zoxy --version > /zoxy-version 2>&1 || echo unknown > /zoxy-version

FROM debian:bookworm-slim
COPY --from=build /src/zig-out/bin/zoxy /usr/local/bin/zoxy
COPY --from=build /zoxy-commit /zoxy-version /etc/zoxy/
COPY entrypoint.sh /entrypoint.sh
# zoxy config takes literal IPv4 endpoints (src/config.zig: Ip4Address, no
# DNS); the entrypoint resolves the `backend` hostname once and renders it in.
ENTRYPOINT ["/entrypoint.sh"]

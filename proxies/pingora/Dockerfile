# Minimal HTTP/1.1 reverse proxy built on Pingora (src/main.rs).
# Build deps cover both TLS backends; main.rs uses `add_tls`, so a missing
# backend fails here at build time rather than at the first TLS ramp.
FROM rust:1.85-bookworm AS build
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       cmake clang libclang-dev libssl-dev pkg-config perl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Cargo.toml ./
COPY src ./src
# compose passes PINGORA_TARGET_CPU=native (how it ships); this default is for
# bare `docker build`. Not CPU-matched with stock haproxy: recorded in
# build-info -> profile.json. Part of the bench-image-cache key.
ARG PINGORA_TARGET_CPU=x86-64
# Recorded so the build target is checkable from run artifacts.
RUN RUSTFLAGS="-C target-cpu=${PINGORA_TARGET_CPU}" cargo build --release \
    && strip target/release/pingora-http \
    && echo "release target-cpu=${PINGORA_TARGET_CPU}" > /pingora-build

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends libssl3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/target/release/pingora-http /usr/local/bin/pingora-http
COPY --from=build /pingora-build /etc/pingora/build-info
# LISTEN / UPSTREAM come from compose env; worker threads are hardcoded to 1.
ENTRYPOINT ["/usr/local/bin/pingora-http"]

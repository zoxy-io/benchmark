# Pingora is a framework, not a ready-made proxy — we build a tiny L7 (HTTP/1.1
# reverse-proxy) binary on it (src/main.rs). Pinned Rust for reproducibility;
# the Pingora version lives in Cargo.toml. Build deps cover both TLS backends
# pingora may pull (openssl via libssl-dev/pkg-config, boringssl via
# cmake/clang) so the crate resolves regardless of the default feature — even
# though this proxy never does TLS.
FROM rust:1.85-bookworm AS build
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       cmake clang libclang-dev libssl-dev pkg-config perl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Cargo.toml ./
COPY src ./src
# Compile for the BUILD host's exact CPU — native SIMD (AVX2 + AVX-512 on the
# Icelake proxy VM), parity with zoxy, which zig builds `-mcpu=native` in this
# same spot. The image is built on the very VM it runs on, so native is both
# safe and fair. Set PINGORA_TARGET_CPU=x86-64 for a generic/baseline build.
ARG PINGORA_TARGET_CPU=native
RUN RUSTFLAGS="-C target-cpu=${PINGORA_TARGET_CPU}" cargo build --release \
    && strip target/release/pingora-http

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends libssl3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/target/release/pingora-http /usr/local/bin/pingora-http
# LISTEN / UPSTREAM come from compose env; worker threads are hardcoded to 1.
ENTRYPOINT ["/usr/local/bin/pingora-http"]

# Pingora is a framework, not a ready-made proxy — we build a tiny L4 (TCP
# passthrough) binary on it (src/main.rs). Pinned Rust for reproducibility; the
# Pingora version lives in Cargo.toml. Build deps cover both TLS backends
# pingora may pull (openssl via libssl-dev/pkg-config, boringssl via
# cmake/clang) so the crate resolves regardless of the default feature — even
# though this L4 proxy never does TLS.
FROM rust:1.85-bookworm AS build
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       cmake clang libclang-dev libssl-dev pkg-config perl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Cargo.toml ./
COPY src ./src
RUN cargo build --release && strip target/release/pingora-l4

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends libssl3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/target/release/pingora-l4 /usr/local/bin/pingora-l4
# LISTEN / UPSTREAM come from compose env; worker threads are hardcoded to 1.
ENTRYPOINT ["/usr/local/bin/pingora-l4"]

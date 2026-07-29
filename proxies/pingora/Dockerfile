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
# NATIVE by default from compose, which passes PINGORA_TARGET_CPU=native — zoxy
# and pingora are both built for the host CPU because that is how they ship, and
# measuring a baseline build would measure something no user runs. The ARG
# default below is only what a bare `docker build` with no compose gets.
#
# haproxy is the stock upstream image and stays a generic x86-64 build, so this
# comparison is NOT CPU-matched. That asymmetry is deliberate and recorded: the
# effective model goes into /etc/pingora/build-info, `bench suite` reads it into
# profile.json, and each SIMD-built proxy gets a note saying the stock images it
# is compared against are generic builds.
#
# It is also part of the image cache key (bench-image-cache), because a `native`
# build is only valid on the model that produced it.
ARG PINGORA_TARGET_CPU=x86-64
# Recorded for the same reason zoxy records its target: the comparison is only
# fair if both were built for the same CPU, and that has to be checkable from the
# run's artifacts rather than inferred from a Dockerfile.
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

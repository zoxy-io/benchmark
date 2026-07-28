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
# Generic x86-64 baseline, NOT native. The comparison includes haproxy, which is
# the stock upstream image and therefore a baseline build with no AVX at all —
# giving pingora and zoxy the host's AVX2/AVX-512 while haproxy runs SSE2 would
# be a large, one-sided advantage that has nothing to do with proxying.
#
# Baseline is also the honest default for this comparison: it is what a package
# or a registry image actually gives you. Set PINGORA_TARGET_CPU=native to
# measure peak achievable performance instead — but then build haproxy from
# source too, or the numbers are not comparable.
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

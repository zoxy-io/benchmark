#!/usr/bin/env bash
# Render every shipped profile through the production entrypoint, then ask the
# actual release binary to validate it. No listeners, io_uring or live origins.
# Run from anywhere: ZOXY_REF=v1.0.1 bash proxies/zoxy/check-configs.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

: "${ZOXY_REF:?set ZOXY_REF to the release tag to check}"
export ZOXY_REF ZOXY_FLAVOUR=release

# Put bind-mounted files under the repo: macOS Docker VMs may not share /tmp.
tls=$(mktemp -d "$PWD/.zoxy-config-check.XXXXXX")
trap 'rm -rf "$tls"' EXIT
# Match suite.ensureTlsMaterial: PKCS#8 and named curves also work on LibreSSL.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 \
    -pkeyopt ec_param_enc:named_curve -out "$tls/bench.key" >/dev/null 2>&1
openssl req -new -x509 -key "$tls/bench.key" -out "$tls/bench.crt" \
    -days 1 -subj /CN=bench-proxy -batch >/dev/null 2>&1

docker compose -f compose.yaml --profile zoxy build zoxy

check() {
    local profile=$1
    shift
    echo "--- zoxy $ZOXY_REF config: $profile"
    # Clear optional tuning between checks, including inherited shell values.
    # Numeric loopback endpoints need no running Docker DNS/backend services.
    env ZOXY_CONN_SLOTS= ZOXY_UPSTREAM_SLOTS= ZOXY_TLS_ENGINES= \
        ZOXY_H2_CONNECTIONS= ZOXY_H2_STREAMS= PROXY_TLS_PORT= PROXY_H2= "$@" \
        docker compose -f compose.yaml --profile zoxy run --rm -T --no-deps \
        -e BACKENDS=127.0.0.1:9000,127.0.0.2:9000,127.0.0.3:9000,127.0.0.4:9000 \
        -v "$tls:/etc/bench/tls:ro" zoxy --check
}

# Keep values aligned with bench/src/profile.zig; its unit tests assert the
# HTTP/2 keys and that only HTTP/2 profiles set them.
check c100
check smoke
check c1k ZOXY_CONN_SLOTS=1386 ZOXY_UPSTREAM_SLOTS=5544
check c10k ZOXY_CONN_SLOTS=11457 ZOXY_UPSTREAM_SLOTS=11457
check c1k-tls ZOXY_CONN_SLOTS=1386 ZOXY_UPSTREAM_SLOTS=5544 \
    ZOXY_TLS_ENGINES=1024 PROXY_TLS_PORT=8443
check c1k-h2 ZOXY_CONN_SLOTS=1386 ZOXY_UPSTREAM_SLOTS=5544 \
    ZOXY_TLS_ENGINES=1024 PROXY_TLS_PORT=8443 PROXY_H2=on \
    ZOXY_H2_CONNECTIONS=1024 ZOXY_H2_STREAMS=1386

#!/bin/sh
# Drop nginx's TLS server block when PROXY_TLS_PORT is unset (plaintext turn),
# so plaintext profiles carry no idle TLS listener; envoy does the same. Off h3
# turns (PROXY_H3 unset), drop the TLS server's QUIC lines, marked `@H3@`.
# Runs after 20-envsubst-on-templates.sh; must be executable or it is skipped.
set -eu

conf=/etc/nginx/nginx.conf

if [ -z "${PROXY_TLS_PORT:-}" ]; then
    sed -i '/@TLS_BEGIN@/,/@TLS_END@/d' "$conf"
    echo "25-tls.sh: no PROXY_TLS_PORT — plaintext only"
    exit 0
fi

if [ -n "${PROXY_H3:-}" ]; then
    echo "25-tls.sh: TLS listener on ${PROXY_TLS_PORT}, QUIC on the same UDP port"
else
    sed -i '/@H3@/d' "$conf"
    echo "25-tls.sh: TLS listener on ${PROXY_TLS_PORT}"
fi

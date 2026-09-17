#!/bin/sh
# Drop nginx's TLS server block when PROXY_TLS_PORT is unset (plaintext turn),
# so plaintext profiles carry no idle TLS listener; envoy does the same.
# Runs after 20-envsubst-on-templates.sh; must be executable or it is skipped.
set -eu

conf=/etc/nginx/nginx.conf

if [ -n "${PROXY_TLS_PORT:-}" ]; then
    echo "25-tls.sh: TLS listener on ${PROXY_TLS_PORT}"
    exit 0
fi

sed -i '/@TLS_BEGIN@/,/@TLS_END@/d' "$conf"
echo "25-tls.sh: no PROXY_TLS_PORT — plaintext only"

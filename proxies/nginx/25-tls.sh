#!/bin/sh
# Drop nginx's TLS server block on a plaintext turn.
#
# The official image's hook (20-envsubst-on-templates.sh, which has already run
# by the time this does — the directory is executed in name order) substitutes
# variables into the template; it cannot leave a block out. So nginx.conf keeps
# both server blocks and this removes the TLS one whenever `bench` did not set
# PROXY_TLS_PORT, which it sets only for a TLS profile.
#
# Why it is removed rather than simply left bound and unused: an idle TLS
# listener would put an extra socket and a parsed certificate into every
# plaintext profile's measurement, and the plaintext numbers are a trend going
# back months. envoy's template carries the same @TLS_BEGIN@/@TLS_END@ markers
# and its entrypoint does the same thing, for the same reason.
#
# Mounted into /docker-entrypoint.d, the same mechanism the origin's
# 10-gen-bodies.sh already uses. It must be executable or the image skips it
# with "Ignoring ... not executable".
set -eu

conf=/etc/nginx/nginx.conf

if [ -n "${PROXY_TLS_PORT:-}" ]; then
    echo "25-tls.sh: TLS listener on ${PROXY_TLS_PORT}"
    exit 0
fi

sed -i '/@TLS_BEGIN@/,/@TLS_END@/d' "$conf"
echo "25-tls.sh: no PROXY_TLS_PORT — plaintext only"

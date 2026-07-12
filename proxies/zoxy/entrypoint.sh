#!/bin/sh
# zoxy (libxev) does no DNS by design — config endpoints must be IP literals
# (config.zig rejects hostnames structurally). The benchmark's upstream is
# the hostname `backend` (compose service DNS locally, extra_hosts entry in
# cloud), so resolve it HERE, once, before zoxy starts, and render the
# literal into the config. The retry loop also absorbs the DNS-registration
# blip that used to race proxies at startup — by the time zoxy runs, the
# address is a literal and can never miss.
set -eu

BACKEND=${BACKEND:-backend:9000}
host=${BACKEND%:*}
port=${BACKEND##*:}

ip=""
for i in $(seq 1 40); do # ~20s ceiling; compose gates backend healthy first
    ip=$(getent ahostsv4 "$host" | head -n1 | cut -d' ' -f1) || ip=""
    [ -n "$ip" ] && break
    echo "zoxy-entrypoint: waiting for '$host' to resolve ($i/40)" >&2
    sleep 0.5
done
if [ -z "$ip" ]; then
    echo "zoxy-entrypoint: cannot resolve upstream '$host' — is backend up?" >&2
    exit 1
fi

sed "s/@BACKEND_ADDR@/$ip:$port/" /etc/zoxy/config.template.json \
    > /etc/zoxy/config.json
exec /usr/local/bin/zoxy /etc/zoxy/config.json

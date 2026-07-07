#!/bin/sh
# zoxy parses upstream endpoints as literal IPv4 (no DNS). Resolve `backend`
# once — docker DNS locally, extra_hosts entry in cloud — and render the
# config. The other proxies resolve the same name themselves at startup, so
# every proxy dials the same address through the same mechanism.
set -eu

TMPL=${ZOXY_CONFIG_TMPL:-/etc/zoxy/config.tmpl.json}
BACKEND_HOST=${BACKEND_HOST:-backend}

ip=$(getent hosts "$BACKEND_HOST" | awk '{print $1; exit}')
if [ -z "$ip" ]; then
    echo "fatal: cannot resolve backend host '$BACKEND_HOST'" >&2
    exit 1
fi

sed "s/@BACKEND@/$ip/g" "$TMPL" > /tmp/config.json
exec /usr/local/bin/zoxy /tmp/config.json

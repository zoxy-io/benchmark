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

# Optional c10k knobs: config.zig's `limits.conn_slots`/`limits.upstream_slots`
# default to 1386/1024 (~32 MiB); omitting a key or passing `{}` is identical
# to leaving it at its compiled default (all `Limits` fields default; see
# constants.zig's upstream_slots_default, deliberately NOT tracking the
# compiled ceiling — a deployment opts up explicitly, here). Neither set =>
# `{}`, today's default behavior, byte-for-byte. relay_buffers isn't set on
# purpose — it defaults to conn_slots when omitted.
fields=""
if [ -n "${ZOXY_CONN_SLOTS:-}" ]; then
    fields="\"conn_slots\": ${ZOXY_CONN_SLOTS}"
fi
if [ -n "${ZOXY_UPSTREAM_SLOTS:-}" ]; then
    [ -n "$fields" ] && fields="$fields, "
    fields="${fields}\"upstream_slots\": ${ZOXY_UPSTREAM_SLOTS}"
fi
LIMITS="{${fields}}"

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

sed -e "s/@BACKEND_ADDR@/$ip:$port/" -e "s/@LIMITS@/$LIMITS/" \
    /etc/zoxy/config.template.json > /etc/zoxy/config.json

# One event loop per PROCESS (no thread/worker knob), capped to 1 CPU and pinned
# to core 0 by the cloud overlay: run a SINGLE zoxy, exec'd so it stays PID 1.
exec /usr/local/bin/zoxy /etc/zoxy/config.json

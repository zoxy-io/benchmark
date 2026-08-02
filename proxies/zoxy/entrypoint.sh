#!/bin/sh
# zoxy (libxev) does no DNS by design — config endpoints must be IP literals
# (config.zig rejects hostnames structurally). The benchmark's upstream is a
# four-node pool addressed by hostname (`backend0`..`backend3` — compose service
# DNS locally, extra_hosts entries in cloud), so resolve them HERE, once, before
# zoxy starts, and render the literals into the config. The retry loop also
# absorbs the DNS-registration blip that used to race proxies at startup — by
# the time zoxy runs, every address is a literal and can never miss.
#
# The cluster pins "pick": "rr" (config.template.json). zoxy's own default is
# p2c, which would very likely serve it better under load — but every proxy in
# this comparison round-robins, and the run is meant to measure proxies rather
# than endpoint-pick policies.
set -eu

BACKENDS=${BACKENDS:-backend0:9000,backend1:9000,backend2:9000,backend3:9000}

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

# Every member, in the order given: a JSON array of "ip:port" string literals.
# All-or-nothing — a pool member that silently dropped out would leave zoxy
# round-robining across three backends while every other proxy uses four, which
# is a throughput difference that looks exactly like a proxy difference.
addrs=""
for entry in $(echo "$BACKENDS" | tr ',' ' '); do
    host=${entry%:*}
    port=${entry##*:}

    ip=""
    for i in $(seq 1 40); do # ~20s ceiling; compose gates backends healthy first
        ip=$(getent ahostsv4 "$host" | head -n1 | cut -d' ' -f1) || ip=""
        [ -n "$ip" ] && break
        echo "zoxy-entrypoint: waiting for '$host' to resolve ($i/40)" >&2
        sleep 0.5
    done
    if [ -z "$ip" ]; then
        echo "zoxy-entrypoint: cannot resolve upstream '$host' — is it up?" >&2
        exit 1
    fi

    [ -n "$addrs" ] && addrs="$addrs, "
    addrs="$addrs\"$ip:$port\""
done

# PROXY_PORT varies per (profile, proxy) turn on the cloud fleet — see
# compose.yaml's x-proxy-common for why — always set by compose (defaulting
# to 8080), never literally unset.
#
# `|` as the sed delimiter for the address list: the replacement contains `/`
# in neither the IPs nor the quotes, but it is a comma-joined list that will
# grow if the pool does, and a `/` sneaking in would turn a config error into a
# sed syntax error. The other two stay on `/` — they are a bare integer and a
# brace-delimited JSON object.
sed -e "s|@BACKEND_ADDRS@|$addrs|" -e "s/@LIMITS@/$LIMITS/" -e "s/@PORT@/${PROXY_PORT:-8080}/" \
    /etc/zoxy/config.template.json > /etc/zoxy/config.json

# One event loop per PROCESS (no thread/worker knob), capped to 1 CPU and pinned
# to core 0 by the cloud overlay: run a SINGLE zoxy, exec'd so it stays PID 1.
#
# Stdout is deliberately NOT redirected, even though every proxy here logs to
# /tmp/access.log: zoxy opens that file itself (`access_log.sink: "file"` in
# config.template.json), so stdout carries only the startup banner — the memory
# budget and resolved slot ceilings — which is what `docker logs` shows the
# harness when a container fails to start. Redirecting would take that with it.
exec /usr/local/bin/zoxy /etc/zoxy/config.json

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

# zoxy is one event loop per PROCESS (no thread/worker knob) — its horizontal
# scale-out story is N processes that all bind :8080 with SO_REUSEPORT, letting
# the kernel spread new connections across them (XevIo.zig sets REUSEPORT before
# bind). ZOXY_WORKERS (= PROXY_CPUS in compose) picks the count so the container
# can actually spend its whole cpu quota; the relay-buffer connection cap is
# per-process, so N workers = N x cap total. ZOXY_WORKERS=1 (default) is exactly
# the old single-process behavior, exec'd so zoxy stays PID 1.
workers=${ZOXY_WORKERS:-1}
if [ "$workers" -le 1 ]; then
    exec /usr/local/bin/zoxy /etc/zoxy/config.json
fi

# N>1: supervise the workers. Forward SIGTERM/SIGINT so `docker stop` triggers
# each loop's graceful drain (§8) instead of a hard kill, and if ANY worker
# exits, tear the rest down and fail loud rather than silently running degraded
# (a half-capacity proxy would quietly skew the benchmark).
pids=""
term() { kill -TERM $pids 2>/dev/null || true; }
trap term TERM INT

i=1
while [ "$i" -le "$workers" ]; do
    /usr/local/bin/zoxy /etc/zoxy/config.json &
    pids="$pids $!"
    i=$((i + 1))
done
echo "zoxy-entrypoint: $workers workers on :8080 (SO_REUSEPORT), pids:$pids" >&2

# dash's `wait` has no -n; poll for the first exit, then collapse the fleet.
while true; do
    for p in $pids; do
        kill -0 "$p" 2>/dev/null || { echo "zoxy-entrypoint: worker $p exited — stopping all" >&2; term; wait; exit 1; }
    done
    sleep 1
done

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

# Pin one worker per core. A single event loop is latency-sensitive to being
# migrated between cores or transiently sharing a core with another loop while a
# third sits idle (that scheduler jitter, not SO_REUSEPORT imbalance, is what
# left zoxy at ~1.5 of 2 cores). A fixed 1:1 loop→core assignment removes the
# migration and keeps cache locality. We pin to the container's cpuSET (the
# cores compose granted via `cpuset`), read from cgroup v2 (fallback: the
# process affinity mask). If workers > cores we round-robin; if taskset is
# missing we run unpinned. util-linux (taskset) is Essential in Debian.
cpulist=$(cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null \
          || awk '/Cpus_allowed_list/{print $2}' /proc/self/status 2>/dev/null)
cpus=""                                   # expand "0-3,6" -> "0 1 2 3 6"
oIFS=$IFS; IFS=','
for part in $cpulist; do
    case "$part" in
        *-*) lo=${part%-*}; hi=${part#*-}; c=$lo
             while [ "$c" -le "$hi" ]; do cpus="$cpus $c"; c=$((c + 1)); done ;;
        ?*)  cpus="$cpus $part" ;;
    esac
done
IFS=$oIFS
set -- $cpus; ncpu=$#                      # positional params hold the cpu list
have_taskset=false; command -v taskset >/dev/null 2>&1 && [ "$ncpu" -gt 0 ] && have_taskset=true

i=1
while [ "$i" -le "$workers" ]; do
    if $have_taskset; then
        eval "cpu=\${$(( (i - 1) % ncpu + 1 ))}"   # round-robin over the cpuset
        taskset -c "$cpu" /usr/local/bin/zoxy /etc/zoxy/config.json &
    else
        /usr/local/bin/zoxy /etc/zoxy/config.json &
    fi
    pids="$pids $!"
    i=$((i + 1))
done
if $have_taskset; then
    echo "zoxy-entrypoint: $workers workers on :8080 (SO_REUSEPORT), pinned to cpus:$cpus, pids:$pids" >&2
else
    echo "zoxy-entrypoint: $workers workers on :8080 (SO_REUSEPORT), UNPINNED (no taskset/cpuset), pids:$pids" >&2
fi

# dash's `wait` has no -n; poll for the first exit, then collapse the fleet.
while true; do
    for p in $pids; do
        kill -0 "$p" 2>/dev/null || { echo "zoxy-entrypoint: worker $p exited — stopping all" >&2; term; wait; exit 1; }
    done
    sleep 1
done

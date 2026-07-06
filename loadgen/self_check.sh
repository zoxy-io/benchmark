#!/usr/bin/env bash
# The fleet-scale version of zoxy/bench's "zoxy CPU %" sanity line. Given a run
# window, ask Prometheus what each host's CPU looked like, and VOID the cell if
# a generator or a backend saturated before the proxy did — because then the
# number measures the generator/backend, not the proxy.
#
# Two things this deliberately gets right:
#   * It checks BOTH the host average and the busiest single core. A
#     single-threaded bottleneck (one nginx worker, k6's event loop) can cap
#     throughput while the host average looks idle.
#   * It fails CLOSED: if Prometheus can't answer, the cell is void, not "ok".
#
#   self_check.sh PROM_URL START_EPOCH END_EPOCH PROXY_IP "BE_IP ..." "LG_IP ..."
#
# Prints:  ok  |  void:<reason>
set -euo pipefail

PROM=$1 START=$2 END=$3 PROXY=$4 BACKENDS=$5 LOADGENS=$6
WIN="$(( END - START ))s"
SAT=0.85       # host-average busy fraction that counts as "saturated"
CORE_SAT=0.90  # busiest-single-core busy fraction that counts as "saturated"
PROXY_HOT=0.95

q() { # PromQL at END -> value, or empty on any failure
  curl -sfG "$PROM/api/v1/query" \
    --data-urlencode "query=$1" \
    --data-urlencode "time=$END" \
  | jq -r '.data.result[0].value[1] // empty' 2>/dev/null || true
}
busy_avg()  { q "1 - avg(rate(node_cpu_seconds_total{mode=\"idle\",instance=~\"$1:9100\"}[$WIN]))"; }
busy_core() { q "max(1 - rate(node_cpu_seconds_total{mode=\"idle\",instance=~\"$1:9100\"}[$WIN]))"; }
gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }
need() { # fail closed on missing data
  if [ -z "$1" ]; then echo "void:selfcheck no CPU data for $2 (prometheus unreachable or empty window)"; exit 0; fi
}

proxy_busy=$(busy_avg "$PROXY"); need "$proxy_busy" "proxy $PROXY"

for ip in $LOADGENS; do
  a=$(busy_avg "$ip");  need "$a" "loadgen $ip"
  c=$(busy_core "$ip"); need "$c" "loadgen $ip"
  if ! gt "$proxy_busy" "$PROXY_HOT"; then
    if gt "$a" "$SAT"; then
      echo "void:generator $ip saturated (avg ${a}) while proxy only ${proxy_busy}"; exit 0
    fi
    if gt "$c" "$CORE_SAT"; then
      echo "void:generator $ip core-saturated (busiest core ${c}) while proxy only ${proxy_busy}"; exit 0
    fi
  fi
done

for ip in $BACKENDS; do
  a=$(busy_avg "$ip");  need "$a" "backend $ip"
  c=$(busy_core "$ip"); need "$c" "backend $ip"
  if gt "$a" "$SAT"; then
    echo "void:backend $ip saturated (avg ${a})"; exit 0
  fi
  if gt "$c" "$CORE_SAT"; then
    echo "void:backend $ip core-saturated (busiest core ${c})"; exit 0
  fi
done

echo "ok"

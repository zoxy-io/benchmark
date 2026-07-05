#!/usr/bin/env bash
# The fleet-scale version of zoxy/bench's "zoxy CPU %" sanity line. Given a run
# window, ask Prometheus what each host's CPU busy-fraction was, and VOID the
# cell if a generator or a backend saturated before the proxy did — because then
# the number measures the generator/backend, not the proxy.
#
#   self_check.sh PROM_URL START_EPOCH END_EPOCH PROXY_IP "BE_IP ..." "LG_IP ..."
#
# Prints:  ok  |  void:<reason>
set -euo pipefail

PROM=$1 START=$2 END=$3 PROXY=$4 BACKENDS=$5 LOADGENS=$6
WIN="$(( END - START ))s"
SAT=0.85   # a host is "saturated" above this busy fraction
PROXY_HOT=0.95

busy() { # busy fraction for <ip> over the window, evaluated at END
  curl -sfG "$PROM/api/v1/query" \
    --data-urlencode "query=1 - avg(rate(node_cpu_seconds_total{mode=\"idle\",instance=~\"$1:9100\"}[$WIN]))" \
    --data-urlencode "time=$END" \
  | jq -r '.data.result[0].value[1] // "0"'
}
gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }

proxy_busy=$(busy "$PROXY")

for ip in $LOADGENS; do
  b=$(busy "$ip")
  if gt "$b" "$SAT" && ! gt "$proxy_busy" "$PROXY_HOT"; then
    echo "void:generator $ip saturated (${b}) while proxy only ${proxy_busy}"; exit 0
  fi
done

for ip in $BACKENDS; do
  b=$(busy "$ip")
  if gt "$b" "$SAT"; then
    echo "void:backend $ip saturated (${b})"; exit 0
  fi
done

echo "ok"

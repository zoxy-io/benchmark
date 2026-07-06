#!/usr/bin/env bash
# Runs one k6 arrival-rate cell on THIS loadgen host. Writes a local summary
# JSON — stamped with this host's start/end epoch, so the orchestrator's
# Prometheus windows use fleet clocks and exclude ssh/jump overhead — and (if a
# Prometheus remote-write URL is given) streams native histograms to the
# control node for cross-host aggregation.
#
#   run-k6.sh TARGET REQ_PATH RATE DURATION MAX_VUS OUT_JSON [PROM_RW_URL]
set -euo pipefail

TARGET=$1 REQ_PATH=$2 RATE=$3 DURATION=$4 MAX_VUS=$5 OUT=$6 PROM=${7:-}
here=$(cd "$(dirname "$0")" && pwd)

# make the local summary carry the tail, not just p90/p95
export K6_SUMMARY_TREND_STATS="avg,min,med,p(90),p(99),p(99.9),max"

args=(run --quiet --summary-export="$OUT"
  -e TARGET="$TARGET" -e REQ_PATH="$REQ_PATH" -e RATE="$RATE"
  -e DURATION="$DURATION" -e MAX_VUS="$MAX_VUS")

if [ -n "$PROM" ]; then
  export K6_PROMETHEUS_RW_SERVER_URL="$PROM"          # http://<control>:9090/api/v1/write
  export K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM=true
  args+=(--out experimental-prometheus-rw)
fi

start=$(date +%s)
rc=0
k6 "${args[@]}" "$here/scenario.js" || rc=$?
end=$(date +%s)

# stamp the measured window into the summary for the orchestrator/self-check
if [ -s "$OUT" ]; then
  jq --argjson s "$start" --argjson e "$end" \
    '. + {bench_start: $s, bench_end: $e}' "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
fi
exit "$rc"

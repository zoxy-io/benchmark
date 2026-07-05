#!/usr/bin/env bash
# wrk2 cross-check on THIS loadgen host: HTTP/1.1 (plaintext or over TLS), open
# loop at a fixed rate, CO-corrected latency (Gil Tene's HdrHistogram). Used for
# the h1-tls protocol and as a sanity check on k6's h1 peak. Emits a small JSON.
#
#   run-wrk2.sh URL RATE DURATION THREADS CONNS OUT_JSON
set -euo pipefail

URL=$1 RATE=$2 DURATION=$3 THREADS=$4 CONNS=$5 OUT=$6

raw=$(wrk2 -t"$THREADS" -c"$CONNS" -d"$DURATION" -R"$RATE" --latency "$URL" 2>&1) || true
printf '%s\n' "$raw" >&2   # keep full output in the run log

# Requests/sec + a few HdrHistogram percentiles (values keep their ms/us/s unit).
get_pct() { awk -v p="$1" '$0 ~ ("^ *"p"%") {print $2; exit}' <<<"$raw"; }
rps=$(awk '/Requests\/sec/ {print $2; exit}' <<<"$raw")

jq -n \
  --arg url "$URL" --argjson rate "$RATE" \
  --arg rps "${rps:-0}" \
  --arg p50  "$(get_pct 50.000)" \
  --arg p90  "$(get_pct 90.000)" \
  --arg p99  "$(get_pct 99.000)" \
  --arg p999 "$(get_pct 99.900)" \
  '{tool:"wrk2", url:$url, target_rate:$rate, achieved_rps:($rps|tonumber),
    latency:{p50:$p50, p90:$p90, p99:$p99, p999:$p999}}' > "$OUT"

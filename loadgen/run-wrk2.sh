#!/usr/bin/env bash
# wrk2 cell on THIS loadgen host: HTTP/1.1 (plaintext or over TLS), open loop at
# a fixed rate, CO-corrected latency (Gil Tene's HdrHistogram). Used for the
# h1-tls protocol and as a cross-check replay of k6's h1 peaks. Emits a small
# JSON including the error fraction (non-2xx/3xx + socket errors) and this
# host's start/end epoch, so the orchestrator can void bad cells and query
# Prometheus over the true window.
#
#   run-wrk2.sh URL RATE DURATION THREADS CONNS OUT_JSON
set -euo pipefail

URL=$1 RATE=$2 DURATION=$3 THREADS=$4 CONNS=$5 OUT=$6

start=$(date +%s)
raw=$(wrk2 -t"$THREADS" -c"$CONNS" -d"$DURATION" -R"$RATE" --latency "$URL" 2>&1) || true
end=$(date +%s)
printf '%s\n' "$raw" >&2   # keep full output in the run log

# Requests/sec + a few HdrHistogram percentiles (values keep their ms/us/s unit).
get_pct() { awk -v p="$1" '$0 ~ ("^ *"p"%") {print $2; exit}' <<<"$raw"; }
rps=$(awk '/Requests\/sec/ {print $2; exit}' <<<"$raw")
reqs=$(awk '/requests in/ {print $1; exit}' <<<"$raw")
non2xx=$(awk '/Non-2xx or 3xx responses:/ {print $NF; exit}' <<<"$raw")
# "Socket errors: connect X, read Y, write Z, timeout W"
sockerr=$(awk '/Socket errors:/ {gsub(/,/,""); print $4+$6+$8+$10; exit}' <<<"$raw")
# no completed requests at all = total failure, not zero errors
errfrac=$(awk -v t="${reqs:-0}" -v n="${non2xx:-0}" -v s="${sockerr:-0}" \
  'BEGIN{ print (t>0) ? (n+s)/t : 1 }')

jq -n \
  --arg url "$URL" --argjson rate "$RATE" \
  --arg rps "${rps:-0}" --arg reqs "${reqs:-0}" \
  --argjson errfrac "$errfrac" \
  --argjson s "$start" --argjson e "$end" \
  --arg p50  "$(get_pct 50.000)" \
  --arg p90  "$(get_pct 90.000)" \
  --arg p99  "$(get_pct 99.000)" \
  --arg p999 "$(get_pct 99.900)" \
  '{tool:"wrk2", url:$url, target_rate:$rate, achieved_rps:($rps|tonumber),
    requests:($reqs|tonumber), error_fraction:$errfrac,
    bench_start:$s, bench_end:$e,
    latency:{p50:$p50, p90:$p90, p99:$p99, p999:$p999}}' > "$OUT"

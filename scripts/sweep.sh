#!/usr/bin/env bash
# Closed-loop throughput-vs-CONCURRENCY sweep. For each proxy, hold N concurrent
# connections (k6 constant-vus, each VU loops request->response) for SWEEP_DUR,
# at several N levels. Throughput/latency/CPU are thus measured as a FUNCTION of
# concurrency instead of at one arbitrary VU pool — revealing each proxy's sweet
# spot and how it degrades past it. Complements scripts/run-all.sh: the single
# open-loop ramp is the "overload/spike" view, this sweep is the "how fast vs
# how many clients" view. Connections == N (bounded), the way a fixed client
# population behaves — not the runaway pile-up an open-loop ramp drives at
# saturation. Single loadgen (closed-loop is light; throughputs stay < one k6's
# ceiling). Keep max N < zoxy's 1024 relay-buffer cap so nobody sheds.
#
# Driven the same two ways as run-all.sh:
#   local:  ./scripts/sweep.sh
#   cloud:  DRIVER=sweep.sh make cloud-sweep   (cloud-run.sh hands off here)
set -euo pipefail
cd "$(dirname "$0")/.."

KNOBS=(PROXIES SWEEP_NS SWEEP_DUR REQ_PATH COOLDOWN MODE RUNID PROXY_CPUS PROXY_MEM PROM_TARGETS)
for k in "${KNOBS[@]}"; do [[ -n ${!k+x} ]] && eval "_saved_$k=\${$k}"; done
if [[ -f .env ]]; then set -a; source .env; set +a; fi
for k in "${KNOBS[@]}"; do saved="_saved_$k"; [[ -n ${!saved+x} ]] && eval "export $k=\${$saved}"; done

MODE=${MODE:-local}
PROXIES=${PROXIES:-"zoxy haproxy envoy traefik nginx pingora"}
SWEEP_NS=${SWEEP_NS:-"50 100 200 400 600 800 1000"}
SWEEP_DUR=${SWEEP_DUR:-30s}
COOLDOWN=${COOLDOWN:-15}
REQ_PATH=${REQ_PATH:-/1k}
RUNID=${RUNID:-sweep-$(date -u +%Y%m%d-%H%M%S)}
REMOTE_DIR=${REMOTE_DIR:-bench}

RESULTS="results/$RUNID"; mkdir -p "$RESULTS"
[[ $MODE == cloud ]] && ssh -o BatchMode=yes "$LOADGEN_SSH" "mkdir -p $REMOTE_DIR/results/$RUNID"

# ---- mode plumbing (mirrors run-all.sh) --------------------------------------
compose_proxy() { if [[ $MODE == cloud ]]; then ssh -o BatchMode=yes "$PROXY_SSH" "cd $REMOTE_DIR && docker compose -f compose.yaml -f compose.cloud.yaml $*"; else docker compose "$@"; fi; }
compose_loadgen() { if [[ $MODE == cloud ]]; then ssh -o BatchMode=yes "$LOADGEN_SSH" "cd $REMOTE_DIR && docker compose -f compose.yaml -f compose.cloud.yaml $*"; else docker compose "$@"; fi; }
probe() { if [[ $MODE == cloud ]]; then ssh -o BatchMode=yes "$LOADGEN_SSH" "curl -fsS -o /dev/null --max-time 2 '$1'"; else curl -fsS -o /dev/null --max-time 2 "$1"; fi; }
target_for() { local p=$1; if [[ $MODE == cloud ]]; then [[ $p == direct ]] && echo "http://${BACKEND_IP}:9000" || echo "http://${PROXY_IP}:8080"; else [[ $p == direct ]] && echo "http://backend:9000" || echo "http://$p:8080"; fi; }
probe_url_for() { local p=$1; if [[ $MODE == cloud ]]; then target_for "$p" | sed "s|\$|$REQ_PATH|"; else [[ $p == direct ]] && echo "http://localhost:9000$REQ_PATH" || echo "http://localhost:8080$REQ_PATH"; fi; }
zoxy_state() { compose_proxy ps -a --format json zoxy 2>/dev/null | jq -r 'if type=="array" then (.[0].State // "") else (.State // "") end' 2>/dev/null || true; }

# ---- metadata ----------------------------------------------------------------
ns_json=$(printf '%s\n' $SWEEP_NS | jq -R 'tonumber' | jq -s .)
jq -n --arg runid "$RUNID" --arg mode "$MODE" --arg req_path "$REQ_PATH" \
  --arg dur "$SWEEP_DUR" --argjson ns "$ns_json" \
  --arg cpus "${PROXY_CPUS:-1}" --arg mem "${PROXY_MEM:-512m}" \
  '{runid:$runid, mode:$mode, req_path:$req_path, sweep_duration:$dur, ns:$ns,
    proxy_cpus:$cpus, proxy_mem:$mem, sweep:{}, versions:{}}' > "$RESULTS/runs.json"

record_point() { # proxy n start end
  jq --arg p "$1" --arg n "$2" --arg s "$3" --arg e "$4" \
    '.sweep[$p][$n] = {start:$s, end:$e}' "$RESULTS/runs.json" > "$RESULTS/runs.json.tmp" && mv "$RESULTS/runs.json.tmp" "$RESULTS/runs.json"
}
record_version() { # proxy
  local p=$1 img
  [[ $p == direct ]] && return 0
  img=$(compose_proxy images --format json "$p" 2>/dev/null | jq -r 'if type=="array" then .[0] else . end | "\(.Repository):\(.Tag)@\(.ID)"' || echo unknown)
  jq --arg p "$p" --arg img "$img" '.versions[$p] = $img' "$RESULTS/runs.json" > "$RESULTS/runs.json.tmp" && mv "$RESULTS/runs.json.tmp" "$RESULTS/runs.json"
}

# ---- the sweep ---------------------------------------------------------------
echo ">>> sweep runid=$RUNID mode=$MODE proxies=[$PROXIES] Ns=[$SWEEP_NS] dur=$SWEEP_DUR"
for p in $PROXIES; do
  echo ">>> [$p] starting"
  [[ $p != direct ]] && compose_proxy --profile "$p" up -d --wait
  if [[ $p == zoxy ]]; then
    [[ "$(zoxy_state)" == running ]] || { echo "fatal: zoxy not running (seccomp/io_uring/backend)"; compose_proxy logs --tail 10 zoxy >&2 || true; exit 1; }
  fi
  url=$(probe_url_for "$p")
  for i in $(seq 1 30); do probe "$url" && break; [[ $i == 30 ]] && { echo "fatal: [$p] never served 200 at $url"; exit 1; }; sleep 1; done
  record_version "$p"
  tgt="$(target_for "$p")"
  for N in $SWEEP_NS; do
    echo ">>> [$p] n=$N (${SWEEP_DUR} closed-loop)"
    start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    compose_loadgen run --rm \
      -e TARGET="$tgt" -e RUNID="$RUNID" -e PROXY="$p" -e VUS="$N" -e N="$N" -e DURATION="$SWEEP_DUR" \
      k6 run --out experimental-prometheus-rw \
      --tag "testid=$RUNID" --tag "proxy=$p" --tag "n=$N" /scripts/saturate.js || true
    end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    record_point "$p" "$N" "$start" "$end"
    sleep 3 # brief settle so a point's TIME_WAIT/CPU doesn't bleed into the next
  done
  if [[ $p != direct ]]; then compose_proxy --profile "$p" stop "$p"; compose_proxy --profile "$p" rm -f "$p" >/dev/null; fi
  echo ">>> [$p] done; cooling ${COOLDOWN}s"; sleep "$COOLDOWN"
done

[[ $MODE == cloud ]] && { rsync -a "$LOADGEN_SSH:$REMOTE_DIR/results/$RUNID/" "$RESULTS/" || true; }
ln -sfn "$RUNID" results/latest
echo ">>> sweep done: $RESULTS  (render: python3 report/sweep.py $RESULTS)"

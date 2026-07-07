#!/usr/bin/env bash
# The whole benchmark: for each proxy — start it, wait until it proxies,
# run the identical k6 ramp, stop it, cool down. Works in two modes:
#
#   local (default)  everything in one compose project on this machine
#   cloud            proxy services driven over SSH on the proxy VM, k6 on the
#                    loadgen VM (set MODE=cloud + PROXY_SSH/LOADGEN_SSH/
#                    PROXY_IP/BACKEND_IP — scripts/cloud-run.sh does this)
#
# The special proxy name `direct` ramps against the backend itself — the
# calibration run: its saturation point must exceed MAX_RATE, or the origin
# (not the proxy) is your bottleneck and the whole run is invalid.
set -euo pipefail
cd "$(dirname "$0")/.."

# .env provides defaults but must NOT clobber explicit overrides
# (e.g. `make smoke` passes MAX_RATE/PROXIES through the environment)
KNOBS=(PROXIES MAX_RATE RAMP_DURATION WARM_RATE MAX_VUS REQ_PATH COOLDOWN MODE RUNID PROXY_CPUS PROXY_MEM PROM_TARGETS)
for k in "${KNOBS[@]}"; do [[ -n ${!k+x} ]] && eval "_saved_$k=\${$k}"; done
if [[ -f .env ]]; then set -a; source .env; set +a; fi
for k in "${KNOBS[@]}"; do
    saved="_saved_$k"
    [[ -n ${!saved+x} ]] && eval "export $k=\${$saved}"
done

MODE=${MODE:-local}
PROXIES=${PROXIES:-"zoxy haproxy envoy traefik caddy"}
COOLDOWN=${COOLDOWN:-60}
REQ_PATH=${REQ_PATH:-/1k}
RUNID=${RUNID:-$(date -u +%Y%m%d-%H%M%S)}
REMOTE_DIR=${REMOTE_DIR:-bench}

RESULTS="results/$RUNID"
mkdir -p "$RESULTS"

# ---- mode plumbing -----------------------------------------------------------
compose_proxy() { # compose command on the machine hosting the proxy
    if [[ $MODE == cloud ]]; then
        # shellcheck disable=SC2029
        ssh -o BatchMode=yes "$PROXY_SSH" "cd $REMOTE_DIR && docker compose -f compose.yaml -f compose.cloud.yaml $*"
    else
        docker compose "$@"
    fi
}
compose_loadgen() { # compose command on the machine hosting k6/prometheus
    if [[ $MODE == cloud ]]; then
        # shellcheck disable=SC2029
        ssh -o BatchMode=yes "$LOADGEN_SSH" "cd $REMOTE_DIR && docker compose -f compose.yaml -f compose.cloud.yaml $*"
    else
        docker compose "$@"
    fi
}
probe() { # HTTP 200 check, executed where k6 will run
    if [[ $MODE == cloud ]]; then
        ssh -o BatchMode=yes "$LOADGEN_SSH" "curl -fsS -o /dev/null --max-time 2 '$1'"
    else
        curl -fsS -o /dev/null --max-time 2 "$1"
    fi
}

target_for() {
    local p=$1
    if [[ $MODE == cloud ]]; then
        if [[ $p == direct ]]; then echo "http://${BACKEND_IP}:9000"; else echo "http://${PROXY_IP}:8080"; fi
    else
        if [[ $p == direct ]]; then echo "http://backend:9000"; else echo "http://$p:8080"; fi
    fi
}
probe_url_for() {
    local p=$1
    if [[ $MODE == cloud ]]; then
        target_for "$p" | sed "s|\$|$REQ_PATH|"
    else
        # k6 resolves service names inside the compose network; the host probe
        # goes through the published ports instead
        if [[ $p == direct ]]; then echo "http://localhost:9000$REQ_PATH"; else echo "http://localhost:8080$REQ_PATH"; fi
    fi
}

# ---- run metadata ------------------------------------------------------------
jq -n \
    --arg runid "$RUNID" --arg mode "$MODE" --arg req_path "$REQ_PATH" \
    --arg max_rate "${MAX_RATE:-20000}" --arg ramp "${RAMP_DURATION:-8m}" \
    --arg warm_rate "${WARM_RATE:-100}" --arg max_vus "${MAX_VUS:-2000}" \
    --arg cpus "${PROXY_CPUS:-2}" --arg mem "${PROXY_MEM:-512m}" \
    '{runid:$runid, mode:$mode, req_path:$req_path,
      max_rate:($max_rate|tonumber), ramp_duration:$ramp,
      warm_rate:($warm_rate|tonumber), max_vus:($max_vus|tonumber),
      proxy_cpus:$cpus, proxy_mem:$mem, runs:{}}' > "$RESULTS/runs.json"

record_run() { # proxy start end aborted
    jq --arg p "$1" --arg s "$2" --arg e "$3" --argjson a "$4" \
        '.runs[$p] = {start:$s, end:$e, aborted:$a}' \
        "$RESULTS/runs.json" > "$RESULTS/runs.json.tmp" && mv "$RESULTS/runs.json.tmp" "$RESULTS/runs.json"
}

record_version() { # proxy
    local p=$1 img
    [[ $p == direct ]] && return 0
    img=$(compose_proxy images --format json "$p" 2>/dev/null | jq -r 'if type=="array" then .[0] else . end | "\(.Repository):\(.Tag)@\(.ID)"' || echo unknown)
    jq --arg p "$p" --arg img "$img" '.versions[$p] = $img' \
        "$RESULTS/runs.json" > "$RESULTS/runs.json.tmp" && mv "$RESULTS/runs.json.tmp" "$RESULTS/runs.json"
}

# ---- the loop ------------------------------------------------------------------
echo ">>> runid=$RUNID mode=$MODE proxies=[$PROXIES] ramp=0->${MAX_RATE:-20000}req/s over ${RAMP_DURATION:-8m}"

for p in $PROXIES; do
    echo ">>> [$p] starting"
    if [[ $p != direct ]]; then
        compose_proxy --profile "$p" up -d --wait
    fi

    url=$(probe_url_for "$p")
    for i in $(seq 1 30); do
        if probe "$url"; then break; fi
        [[ $i == 30 ]] && { echo "fatal: [$p] never served 200 at $url" >&2; exit 1; }
        sleep 1
    done

    # zoxy's data path is io_uring; if the seccomp profile is wrong it dies at
    # startup (io_uring_setup -> EPERM). Fail loudly rather than benchmark a corpse.
    if [[ $p == zoxy ]]; then
        state=$(compose_proxy ps --format json zoxy | jq -r 'if type=="array" then .[0].State else .State end')
        [[ $state == running ]] || { echo "fatal: zoxy is '$state' — check seccomp-iouring.json wiring" >&2; exit 1; }
    fi

    record_version "$p"

    echo ">>> [$p] ramping (warmup 30s + ${RAMP_DURATION:-8m})"
    start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    aborted=false
    compose_loadgen run --rm \
        -e TARGET="$(target_for "$p")" -e RUNID="$RUNID" -e PROXY="$p" \
        k6 run --out experimental-prometheus-rw \
        --tag "testid=$RUNID" --tag "proxy=$p" /scripts/ramp.js || aborted=true
    end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    record_run "$p" "$start" "$end" "$aborted"
    $aborted && echo ">>> [$p] k6 aborted early (dead-proxy valve or error) — window recorded anyway"

    if [[ $p != direct ]]; then
        compose_proxy --profile "$p" stop "$p"
        compose_proxy --profile "$p" rm -f "$p" >/dev/null
    fi

    echo ">>> [$p] done; cooling down ${COOLDOWN}s"
    sleep "$COOLDOWN"
done

# cloud mode: k6 wrote its summaries on the loadgen VM; pull them next to runs.json
if [[ $MODE == cloud ]]; then
    rsync -a "$LOADGEN_SSH:$REMOTE_DIR/results/$RUNID/" "$RESULTS/" || true
fi

ln -sfn "$RUNID" results/latest
echo ">>> all done: $RESULTS  (render with: make report)"

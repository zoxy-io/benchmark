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
PROXIES=${PROXIES:-"zoxy haproxy envoy traefik nginx pingora"}
COOLDOWN=${COOLDOWN:-60}
REQ_PATH=${REQ_PATH:-/1k}
RUNID=${RUNID:-$(date -u +%Y%m%d-%H%M%S)}
REMOTE_DIR=${REMOTE_DIR:-bench}

RESULTS="results/$RUNID"
mkdir -p "$RESULTS"
# cloud: k6 runs on the loadgen VM and writes its per-run summary into the
# results/$RUNID bind mount there. k6's handleSummary does not create the
# directory, and the mkdir above only made it on this driver host — so create
# it on the loadgen too, or the end-of-test summary write fails (ENOENT).
if [[ $MODE == cloud ]]; then
    ssh -o BatchMode=yes "$LOADGEN_SSH" "mkdir -p $REMOTE_DIR/results/$RUNID"
    [[ -n ${LOADGEN2_SSH:-} ]] && ssh -o BatchMode=yes "$LOADGEN2_SSH" "mkdir -p $REMOTE_DIR/results/$RUNID"
fi

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
# One k6 on one loadgen VM (cloud, multi-loadgen fan-out). Args: ssh_host lg
# rate vus prom_url. Reads loop vars $p / $RUNID / $K6_TARGET. Values are all
# shell-safe tokens (URLs, numbers, service names) so no remote quoting needed.
# MAX_RATE and MAX_VUS are the per-loadgen SHARE (caller divides by loadgen
# count) so the COMBINED offered rate and concurrency equal MAX_RATE / MAX_VUS
# regardless of how many loadgens run.
launch_k6() {
    # shellcheck disable=SC2029
    ssh -o BatchMode=yes "$1" "cd $REMOTE_DIR && docker compose -f compose.yaml -f compose.cloud.yaml run --rm \
-e TARGET=$K6_TARGET -e RUNID=$RUNID -e PROXY=$p -e LG=$2 -e MAX_RATE=$3 -e MAX_VUS=$4 -e K6_PROMETHEUS_RW_SERVER_URL=$5 \
k6 run --out experimental-prometheus-rw --tag testid=$RUNID --tag proxy=$p --tag lg=$2 /scripts/ramp.js"
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

zoxy_state() { # echo zoxy's container State ("" if absent); never errors
    compose_proxy ps -a --format json zoxy 2>/dev/null \
        | jq -r 'if type=="array" then (.[0].State // "") else (.State // "") end' 2>/dev/null || true
}
bring_up() { # proxy — start it. No zoxy DNS special-case anymore: zoxy (libxev)
    # does no DNS at all; its container entrypoint resolves `backend` (with
    # retries) and renders the IP literal into the config before exec'ing zoxy.
    compose_proxy --profile "$1" up -d --wait
}

# ---- run metadata ------------------------------------------------------------
# An existing runs.json (explicit RUNID: re-ramping one proxy into a prior run)
# is kept — record_run/record_version merge into it. The ramp knobs are the
# caller's responsibility to keep identical; they are what makes that valid.
if [[ ! -f $RESULTS/runs.json ]]; then
    jq -n \
        --arg runid "$RUNID" --arg mode "$MODE" --arg req_path "$REQ_PATH" \
        --arg max_rate "${MAX_RATE:-20000}" --arg ramp "${RAMP_DURATION:-8m}" \
        --arg warm_rate "${WARM_RATE:-100}" --arg max_vus "${MAX_VUS:-400}" \
        --arg cpus "${PROXY_CPUS:-1}" --arg mem "${PROXY_MEM:-512m}" \
        '{runid:$runid, mode:$mode, req_path:$req_path,
          max_rate:($max_rate|tonumber), ramp_duration:$ramp,
          warm_rate:($warm_rate|tonumber), max_vus:($max_vus|tonumber),
          proxy_cpus:$cpus, proxy_mem:$mem, runs:{}}' > "$RESULTS/runs.json"
fi

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
        bring_up "$p"
    fi

    # zoxy's event loop is io_uring (libxev) and it has no fallback: with a
    # broken seccomp profile it fails at init and the process EXITS (unlike
    # the old per-worker rewrite, nothing keeps running). It also exits if the
    # entrypoint could not resolve the backend. Either way a non-running
    # container here is fatal — fail loudly rather than benchmark a corpse.
    if [[ $p == zoxy ]]; then
        state=$(zoxy_state)
        if [[ $state != running ]]; then
            echo "fatal: zoxy is '${state:-absent}'. Causes: seccomp-iouring.json not" >&2
            echo "  applied (io_uring denied), kernel too old, or the entrypoint could" >&2
            echo "  not resolve the backend. Last log lines:" >&2
            compose_proxy logs --tail 10 zoxy >&2 || true
            exit 1
        fi
    fi

    url=$(probe_url_for "$p")
    for i in $(seq 1 30); do
        if probe "$url"; then break; fi
        if [[ $i == 30 ]]; then
            echo "fatal: [$p] never served 200 at $url — last log lines:" >&2
            [[ $p != direct ]] && compose_proxy --profile "$p" logs --tail 10 "$p" >&2 || true
            exit 1
        fi
        sleep 1
    done


    record_version "$p"

    echo ">>> [$p] ramping (warmup 30s + ${RAMP_DURATION:-8m})"
    start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    aborted=false
    K6_TARGET="$(target_for "$p")"
    if [[ $MODE == cloud && -n ${LOADGEN2_SSH:-} ]]; then
        # Fan out across two loadgens, each getting HALF of MAX_RATE and MAX_VUS
        # so the COMBINED offered rate and concurrency equal MAX_RATE / MAX_VUS
        # (the report axis and the sweet-spot concurrency are totals, not
        # per-loadgen). Distinct lg tag; loadgen2's k6 remote-writes to the
        # primary's prometheus (LOADGEN_PRIV), the primary's to localhost.
        lg_rate=$(( ${MAX_RATE:-20000} / 2 ))
        lg_vus=$(( ${MAX_VUS:-400} / 2 ))
        echo ">>> [$p] 2 loadgens x ${lg_rate}req/s, ${lg_vus} VUs (combined ${MAX_RATE:-20000}req/s, ${MAX_VUS:-400} VUs)"
        launch_k6 "$LOADGEN_SSH"  1 "$lg_rate" "$lg_vus" "http://127.0.0.1:9090/api/v1/write" & pid1=$!
        launch_k6 "$LOADGEN2_SSH" 2 "$lg_rate" "$lg_vus" "http://$LOADGEN_PRIV:9090/api/v1/write" & pid2=$!
        wait "$pid1" || aborted=true
        wait "$pid2" || aborted=true
    else
        compose_loadgen run --rm \
            -e TARGET="$K6_TARGET" -e RUNID="$RUNID" -e PROXY="$p" -e LG=1 \
            k6 run --out experimental-prometheus-rw \
            --tag "testid=$RUNID" --tag "proxy=$p" --tag "lg=1" /scripts/ramp.js || aborted=true
    fi
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

# cloud mode: k6 wrote its summaries on each loadgen VM; pull them next to
# runs.json (each loadgen has only its own lg<N> files, so both merge cleanly)
if [[ $MODE == cloud ]]; then
    rsync -a "$LOADGEN_SSH:$REMOTE_DIR/results/$RUNID/" "$RESULTS/" || true
    [[ -n ${LOADGEN2_SSH:-} ]] && rsync -a "$LOADGEN2_SSH:$REMOTE_DIR/results/$RUNID/" "$RESULTS/" || true
fi

ln -sfn "$RUNID" results/latest
echo ">>> all done: $RESULTS  (render with: make report)"

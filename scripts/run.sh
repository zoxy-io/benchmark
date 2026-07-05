#!/usr/bin/env bash
# One-shot benchmark driver. Assumes `make up` has stood up the fleet and written
# terraform/inventory.json. For each proxy it deploys a rendered config, finds
# the peak arrival rate the proxy can sustain (while generators+backends keep
# headroom), then measures latency at fractions of that peak — recording every
# cell's window so the metrics come from Prometheus, not guesswork.
#
#   scripts/run.sh [--proxies "zoxy haproxy ..."] [--matrix scenarios/matrix.yaml]
#
# Load ALWAYS travels the internal network. Only `control` has a public IP; the
# orchestrator SSHes to it directly and reaches proxy/loadgen by their internal
# IPs through control as a jump host (see lib.sh). Proxy ports are never exposed
# externally. The orchestrator drives loadgens over SSH and reads their JSON back.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

MATRIX=scenarios/matrix.yaml
PROXIES=""
while [ $# -gt 0 ]; do
  case $1 in
    --proxies) PROXIES=$2; shift 2 ;;
    --matrix)  MATRIX=$2; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --- matrix knobs -----------------------------------------------------------
m() { yq "$1" "$MATRIX"; }
[ -n "$PROXIES" ] || PROXIES=$(m '.proxies | join(" ")')
mapfile -t BODIES         < <(m '.bodies[]')
mapfile -t BACKEND_COUNTS < <(m '.backend_counts[]')
mapfile -t FRACTIONS      < <(m '.load.latency_fractions[]')
WARMUP=$(m '.load.warmup')
PEAK_DUR=$(m '.load.peak_duration')
MEAS_DUR=$(m '.load.measure_duration')
REPEATS=$(m '.load.repeats')
START_RATE=$(m '.load.peak_search.start_rate')
FACTOR=$(m '.load.peak_search.factor')
MAX_RATE=$(m '.load.peak_search.max_rate')
KEEPUP=$(m '.load.peak_search.keepup_ratio')
WRK_CONNS=$(m '.wrk2.connections')
MAXVUS=4000

# --- inventory --------------------------------------------------------------
PROXY_INT=$(int_ip proxy)
CONTROL_INT=$(int_ip control); CONTROL_EXT=$(ext_ip control)
BASTION="bench@$CONTROL_EXT"   # sole public host; lib.sh reaches the rest via -J
mapfile -t BACKEND_INT < <(role_int_ips backend)
mapfile -t LOADGEN_INT < <(role_int_ips loadgen)
NPROC=$(sshx "$PROXY_INT" nproc | tr -d '[:space:]')
WRK_THREADS=$NPROC
log "fleet: proxy=$PROXY_INT control=$CONTROL_INT backends=[${BACKEND_INT[*]}] loadgens=[${LOADGEN_INT[*]}] nproc=$NPROC"

RUN="results/$(date +%Y-%m-%dT%H-%M-%S)"
mkdir -p "$RUN/cells" "$RUN/config"
ln -sfn "$(basename "$RUN")" results/latest
CELLS="$RUN/cells.jsonl"; : > "$CELLS"

CURRENT_PROXY=""
cleanup() { [ -n "$CURRENT_PROXY" ] && sshx "$PROXY_INT" "sudo systemctl stop $CURRENT_PROXY" 2>/dev/null || true; }
trap cleanup EXIT

# --- setup: ship loadgen scripts, start Prometheus --------------------------
setup() {
  log "distributing loadgen scripts"
  local h
  for h in "${LOADGEN_INT[@]}"; do scp_dir_to "$h" '~/' loadgen; done
  scp_dir_to "$CONTROL_EXT" '~/' loadgen   # control runs self_check.sh

  log "rendering + starting Prometheus on control"
  local nodes=""
  for ip in "$PROXY_INT" "$CONTROL_INT" "${BACKEND_INT[@]}" "${LOADGEN_INT[@]}"; do
    nodes+="\"$ip:9100\","
  done
  nodes=${nodes%,}
  sed -e "s|@@NODE_TARGETS@@|$nodes|" -e "s|@@PROXY_IP@@|$PROXY_INT|" \
    metrics/prometheus.yml.tmpl > "$RUN/prometheus.yml"
  scp_to "$CONTROL_EXT" /etc/prometheus/prometheus.yml "$RUN/prometheus.yml"
  sshx "$CONTROL_EXT" "sudo systemctl restart bench-prometheus"
  sleep 2
}

wait_ready() { # proxy tls_mode
  local url; [ "$2" = tls ] && url="https://$PROXY_INT:8443/64" || url="http://$PROXY_INT:8080/64"
  for _ in $(seq 1 50); do
    sshx "$CONTROL_EXT" "curl -ksf -o /dev/null '$url'" && return 0
    sleep 0.2
  done
  log "WARN: $1 not ready at $url"; return 1
}

deploy_proxy() { # proxy tls_mode nbackends
  local proxy=$1 tls_mode=$2 nb=$3
  local subset=("${BACKEND_INT[@]:0:$nb}") eps=()
  local ip; for ip in "${subset[@]}"; do eps+=("$ip:9000"); done
  local rdir="$RUN/config/${proxy}_${tls_mode}_${nb}b"; rm -rf "$rdir"
  mapfile -t files < <(scripts/render-config.sh "$proxy" "$tls_mode" "$NPROC" "$rdir" "${eps[@]}")
  local etc; etc=$(proxy_etc "$proxy")
  local f; for f in "${files[@]}"; do scp_to "$PROXY_INT" "$etc/$(basename "$f")" "$f"; done
  CURRENT_PROXY=$proxy
  sshx "$PROXY_INT" "sudo systemctl restart $proxy"
  wait_ready "$proxy" "$tls_mode"
}

# run_cell PROTO REQPATH RATE DURATION TAG -> echoes "achieved_rps start end"
run_cell() {
  local proto=$1 reqpath=$2 rate=$3 dur=$4 tag=$5
  local dir="$RUN/cells/$tag"; mkdir -p "$dir"
  local scheme port
  case $proto in h1) scheme=http; port=8080 ;; *) scheme=https; port=8443 ;; esac
  local per=$(( rate / ${#LOADGEN_INT[@]} )); (( per < 1 )) && per=1
  local i=0 pids=() start end
  start=$(date +%s)
  for lg in "${LOADGEN_INT[@]}"; do
    local remote="/tmp/cell_${tag}_$i.json"
    if [ "$proto" = h1-tls ]; then
      sshx "$lg" "bash ~/loadgen/run-wrk2.sh '$scheme://$PROXY_INT:$port$reqpath' $per '$dur' $WRK_THREADS $WRK_CONNS '$remote' >/tmp/cell_${tag}_$i.log 2>&1" &
    else
      sshx "$lg" "bash ~/loadgen/run-k6.sh '$scheme://$PROXY_INT:$port' '$reqpath' $per '$dur' $MAXVUS '$remote' 'http://$CONTROL_INT:9090/api/v1/write' >/tmp/cell_${tag}_$i.log 2>&1" &
    fi
    pids+=($!); i=$((i+1))
  done
  for p in "${pids[@]}"; do wait "$p" || true; done
  end=$(date +%s)

  local total=0 j=0 r
  for lg in "${LOADGEN_INT[@]}"; do
    scp_from "$lg" "/tmp/cell_${tag}_$j.json" "$dir/gen_$j.json" 2>/dev/null || echo '{}' > "$dir/gen_$j.json"
    if [ "$proto" = h1-tls ]; then r=$(jq -r '.achieved_rps // 0' "$dir/gen_$j.json")
    else r=$(jq -r '.metrics.http_reqs.rate // 0' "$dir/gen_$j.json"); fi
    total=$(awk -v a="$total" -v b="$r" 'BEGIN{printf "%.0f", a+b}')
    j=$((j+1))
  done
  echo "$total $start $end"
}

self_check() { # start end -> ok|void:...
  sshx "$CONTROL_EXT" "bash ~/loadgen/self_check.sh http://localhost:9090 $1 $2 $PROXY_INT '${BACKEND_INT[*]}' '${LOADGEN_INT[*]}'" 2>/dev/null || echo ok
}

find_peak() { # proxy proto reqpath -> echoes peak_rps
  local proxy=$1 proto=$2 reqpath=$3 rate=$START_RATE best=0 res ach start end chk keep
  while awk -v r="$rate" -v mx="$MAX_RATE" 'BEGIN{exit !(r<=mx)}'; do
    res=$(run_cell "$proto" "$reqpath" "$rate" "$PEAK_DUR" "peak_${proxy}_${proto}_${reqpath#/}_$rate")
    read -r ach start end <<<"$res"
    chk=$(self_check "$start" "$end")
    keep=$(awk -v a="$ach" -v r="$rate" -v k="$KEEPUP" 'BEGIN{print (a>=k*r)?1:0}')
    log "  peak probe $proxy/$proto$reqpath target=$rate achieved=$ach check=$chk"
    if [ "$keep" = 1 ] && [ "$chk" = ok ]; then
      best=$ach
      rate=$(awk -v r="$rate" -v f="$FACTOR" 'BEGIN{printf "%.0f", r*f}')
    else
      break
    fi
  done
  echo "$best"
}

record() { # kind proxy tls_mode proto body nb frac target ach start end check tag
  jq -nc --arg kind "$1" --arg proxy "$2" --arg tls "$3" --arg proto "$4" \
    --arg body "$5" --argjson nb "$6" --arg frac "$7" --argjson target "$8" \
    --argjson ach "$9" --argjson start "${10}" --argjson end "${11}" --arg check "${12}" \
    --arg tag "${13:-}" \
    '{kind:$kind,proxy:$proxy,tls_mode:$tls,proto:$proto,body:$body,backends:$nb,
      fraction:($frac|tonumber),target_rate:$target,achieved_rps:$ach,
      start:$start,end:$end,check:$check,tag:$tag}' >> "$CELLS"
}

# --- the sweep --------------------------------------------------------------
run_proxy() {
  local proxy=$1
  log "==== $proxy ===="
  local tls_mode protos proto body nb peak frac rate rep res ach start end chk
  for tls_mode in plain tls; do
    [ "$tls_mode" = plain ] && protos=(h1) || protos=(h1-tls h2)
    for nb in "${BACKEND_COUNTS[@]}"; do
      deploy_proxy "$proxy" "$tls_mode" "$nb" || { log "deploy failed, skipping"; continue; }
      for proto in "${protos[@]}"; do
        for body in "${BODIES[@]}"; do
          # warm up (discarded)
          run_cell "$proto" "/$body" "$START_RATE" "$WARMUP" "warmup_${proxy}_${proto}_${body}" >/dev/null
          peak=$(find_peak "$proxy" "$proto" "/$body")
          log "  PEAK $proxy/$proto/$body/${nb}b = $peak req/s"
          record peak "$proxy" "$tls_mode" "$proto" "$body" "$nb" 1.0 "${peak:-0}" "${peak:-0}" 0 0 ok ""
          for frac in "${FRACTIONS[@]}"; do
            rate=$(awk -v p="$peak" -v f="$frac" 'BEGIN{printf "%.0f", p*f}')
            (( rate < 1 )) && continue
            for rep in $(seq 1 "$REPEATS"); do
              local tag="meas_${proxy}_${proto}_${body}_${nb}b_${frac}_$rep"
              res=$(run_cell "$proto" "/$body" "$rate" "$MEAS_DUR" "$tag")
              read -r ach start end <<<"$res"
              chk=$(self_check "$start" "$end")
              record measure "$proxy" "$tls_mode" "$proto" "$body" "$nb" "$frac" "$rate" "$ach" "$start" "$end" "$chk" "$tag"
            done
          done
        done
      done
      sshx "$PROXY_INT" "sudo systemctl stop $proxy"; CURRENT_PROXY=""
    done
  done
}

main() {
  setup
  local p; for p in $PROXIES; do run_proxy "$p"; done
  log "snapshotting Prometheus"
  metrics/snapshot.sh "bench@$CONTROL_EXT" "$RUN" || log "snapshot failed (continuing)"
  cp "$MATRIX" "$RUN/matrix.yaml"; cp "$INVENTORY" "$RUN/inventory.json" 2>/dev/null || true
  log "done -> $RUN  (run 'make report')"
}
main

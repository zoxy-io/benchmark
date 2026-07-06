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
# Re-exec under bash if launched by another shell (your login shell may be zsh,
# which lacks `mapfile` and some array semantics this script relies on).
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
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
SETTLE=$(m '.load.settle // 5')
ERRMAX=$(m '.load.max_error_rate // 0.001')
WRK_CONNS=$(m '.wrk2.connections')
MAXVUS=1000   # per-generator VU/connection guardrail (see loadgen/scenario.js)

# --- inventory --------------------------------------------------------------
PROXY_INT=$(int_ip proxy)
CONTROL_INT=$(int_ip control); CONTROL_EXT=$(ext_ip control)
BASTION="bench@$CONTROL_EXT"   # sole public host; lib.sh reaches the rest via -J
mapfile -t BACKEND_INT < <(role_int_ips backend)
mapfile -t LOADGEN_INT < <(role_int_ips loadgen)
# fail fast if the matrix asks for more backends than the fleet has — otherwise
# a "3 backend" cell silently runs against fewer and gets mislabeled
for nb in "${BACKEND_COUNTS[@]}"; do
  if (( nb > ${#BACKEND_INT[@]} )); then
    log "FATAL: matrix wants $nb backends but the fleet has ${#BACKEND_INT[@]} — align scenarios/matrix.yaml backend_counts with terraform backend_count"
    exit 1
  fi
done
# --- preflight: prove SSH works before anything else, with actionable hints ---
_pre=$(mktemp)
if ! sshx "$CONTROL_EXT" true 2>"$_pre"; then
  log "FATAL: cannot SSH to control ($CONTROL_EXT) as 'bench'."
  log "  ssh: $(tail -1 "$_pre")"
  log "  Point SSH_KEY at the private key matching terraform's ssh_public_key, e.g."
  log "    SSH_KEY=~/.ssh/zoxy_bench make bench     (or: ssh-add ~/.ssh/zoxy_bench)"
  rm -f "$_pre"; exit 1
fi
if ! sshx "$PROXY_INT" true 2>"$_pre"; then
  log "FATAL: SSH to control works, but the jump to proxy ($PROXY_INT) fails."
  log "  ssh: $(tail -1 "$_pre")"
  log "  The same key must authorize 'bench' on every host (terraform sets it fleet-wide)."
  rm -f "$_pre"; exit 1
fi
rm -f "$_pre"

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

# run_cell PROTO REQPATH RATE DURATION TAG [TOOL] -> echoes "achieved_rps start end verdict"
# TOOL defaults by protocol (h1/h2 -> k6, h1-tls -> wrk2); pass "wrk2" to force
# the cross-check tool on an h1 cell. verdict is ok | void:<reason> — an error
# fraction above ERRMAX or any dropped k6 iteration (coordinated omission)
# voids the cell at the source, so a proxy fast-failing 502s can't post a peak.
# start/end prefer the generators' own stamps (fleet clocks, no ssh overhead).
run_cell() {
  local proto=$1 reqpath=$2 rate=$3 dur=$4 tag=$5 tool=${6:-}
  if [ -z "$tool" ]; then case $proto in h1-tls) tool=wrk2 ;; *) tool=k6 ;; esac; fi
  local dir="$RUN/cells/$tag"; mkdir -p "$dir"
  local scheme port
  case $proto in h1) scheme=http; port=8080 ;; *) scheme=https; port=8443 ;; esac
  local n=${#LOADGEN_INT[@]}
  local base=$(( rate / n )) rem=$(( rate % n ))
  local i=0 pids=() start end per
  start=$(date +%s)
  for lg in "${LOADGEN_INT[@]}"; do
    per=$base; (( i < rem )) && per=$(( per + 1 )); (( per < 1 )) && per=1
    local remote="/tmp/cell_${tag}_$i.json"
    if [ "$tool" = wrk2 ]; then
      sshx "$lg" "bash ~/loadgen/run-wrk2.sh '$scheme://$PROXY_INT:$port$reqpath' $per '$dur' $WRK_THREADS $WRK_CONNS '$remote' >/tmp/cell_${tag}_$i.log 2>&1" &
    else
      sshx "$lg" "bash ~/loadgen/run-k6.sh '$scheme://$PROXY_INT:$port' '$reqpath' $per '$dur' $MAXVUS '$remote' 'http://$CONTROL_INT:9090/api/v1/write' >/tmp/cell_${tag}_$i.log 2>&1" &
    fi
    pids+=($!); i=$((i+1))
  done
  for p in "${pids[@]}"; do wait "$p" || true; done
  end=$(date +%s)

  local total=0 j=0 r e d maxerr=0 dropped=0 gstart="" gend="" bs be
  for lg in "${LOADGEN_INT[@]}"; do
    scp_from "$lg" "/tmp/cell_${tag}_$j.json" "$dir/gen_$j.json" 2>/dev/null || echo '{}' > "$dir/gen_$j.json"
    if [ "$tool" = wrk2 ]; then
      r=$(jq -r '.achieved_rps // 0' "$dir/gen_$j.json")
      e=$(jq -r '.error_fraction // 0' "$dir/gen_$j.json")
      d=0
    else
      r=$(jq -r '.metrics.http_reqs.rate // 0' "$dir/gen_$j.json")
      e=$(jq -r '.metrics.http_req_failed.value // 0' "$dir/gen_$j.json")
      d=$(jq -r '.metrics.dropped_iterations.count // 0' "$dir/gen_$j.json")
    fi
    bs=$(jq -r '.bench_start // empty' "$dir/gen_$j.json")
    be=$(jq -r '.bench_end // empty' "$dir/gen_$j.json")
    if [ -n "$bs" ] && { [ -z "$gstart" ] || [ "$bs" -lt "$gstart" ]; }; then gstart=$bs; fi
    if [ -n "$be" ] && { [ -z "$gend" ] || [ "$be" -gt "$gend" ]; }; then gend=$be; fi
    total=$(awk -v a="$total" -v b="$r" 'BEGIN{printf "%.0f", a+b}')
    maxerr=$(awk -v a="$maxerr" -v b="$e" 'BEGIN{print (b>a)?b:a}')
    dropped=$(awk -v a="$dropped" -v b="$d" 'BEGIN{printf "%.0f", a+b}')
    j=$((j+1))
  done
  local verdict=ok
  if awk -v e="$maxerr" -v m="$ERRMAX" 'BEGIN{exit !(e>m)}'; then
    verdict="void:error-rate($maxerr)"
  elif [ "$dropped" -gt 0 ]; then
    verdict="void:dropped-iterations($dropped)"
  fi
  echo "$total ${gstart:-$start} ${gend:-$end} $verdict"
}

self_check() { # start end -> ok|void:...   (fails CLOSED: no answer = void)
  local out
  out=$(sshx "$CONTROL_EXT" "bash ~/loadgen/self_check.sh http://localhost:9090 $1 $2 $PROXY_INT '${BACKEND_INT[*]}' '${LOADGEN_INT[*]}'" 2>/dev/null) || out=""
  if [ -n "$out" ]; then echo "$out"; else echo "void:selfcheck-unavailable"; fi
}

# find_peak proxy proto reqpath -> echoes peak_rps
# Geometric climb (×FACTOR) to bracket saturation, then a short bisection so
# the peak is known to ~10%, not "somewhere below 1.5× the last passing rate".
find_peak() {
  local proxy=$1 proto=$2 reqpath=$3
  local rate=$START_RATE best=0 lo=0 hi="" mid _i
  local res ach start end verdict chk keep
  probe() { # RATE -> 0 if the proxy sustained it cleanly (sets ach)
    res=$(run_cell "$proto" "$reqpath" "$1" "$PEAK_DUR" "peak_${proxy}_${proto}_${reqpath#/}_$1")
    read -r ach start end verdict <<<"$res"
    chk=$(self_check "$start" "$end")
    if [ "$verdict" != ok ]; then chk=$verdict; fi
    keep=$(awk -v a="$ach" -v r="$1" -v k="$KEEPUP" 'BEGIN{print (a>=k*r)?1:0}')
    log "  peak probe $proxy/$proto$reqpath target=$1 achieved=$ach check=$chk"
    [ "$keep" = 1 ] && [ "$chk" = ok ]
  }
  while awk -v r="$rate" -v mx="$MAX_RATE" 'BEGIN{exit !(r<=mx)}'; do
    if probe "$rate"; then
      best=$ach; lo=$rate
      rate=$(awk -v r="$rate" -v f="$FACTOR" 'BEGIN{printf "%.0f", r*f}')
    else
      hi=$rate; break
    fi
  done
  if [ -n "$hi" ]; then
    for _i in 1 2 3; do
      awk -v l="$lo" -v h="$hi" 'BEGIN{exit !((h-l)/h > 0.10)}' || break
      mid=$(( (lo + hi) / 2 ))
      if probe "$mid"; then best=$ach; lo=$mid; else hi=$mid; fi
    done
  fi
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
  local tls_mode protos proto body nb peak frac rate rep res ach start end chk verdict xtag
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
          if [ "$proto" = h1 ] && [ "${peak:-0}" -gt 0 ]; then
            # replay the k6-found peak with wrk2 — same cell, different tool —
            # so tool disagreement is visible in the report instead of latent
            xtag="xcheck_${proxy}_${body}_${nb}b"
            res=$(run_cell h1 "/$body" "$peak" "$MEAS_DUR" "$xtag" wrk2)
            read -r ach start end verdict <<<"$res"
            chk=$(self_check "$start" "$end")
            if [ "$verdict" != ok ]; then chk=$verdict; fi
            record crosscheck "$proxy" "$tls_mode" h1 "$body" "$nb" 1.0 "$peak" "$ach" "$start" "$end" "$chk" "$xtag"
            log "  cross-check wrk2@peak: achieved=$ach check=$chk"
          fi
          sleep "$SETTLE"   # drain backlogs/TIME_WAIT after deliberately saturating the proxy
          for frac in "${FRACTIONS[@]}"; do
            rate=$(awk -v p="$peak" -v f="$frac" 'BEGIN{printf "%.0f", p*f}')
            (( rate < 1 )) && continue
            for rep in $(seq 1 "$REPEATS"); do
              local tag="meas_${proxy}_${proto}_${body}_${nb}b_${frac}_$rep"
              res=$(run_cell "$proto" "/$body" "$rate" "$MEAS_DUR" "$tag")
              read -r ach start end verdict <<<"$res"
              chk=$(self_check "$start" "$end")
              if [ "$verdict" != ok ]; then chk=$verdict; fi
              record measure "$proxy" "$tls_mode" "$proto" "$body" "$nb" "$frac" "$rate" "$ach" "$start" "$end" "$chk" "$tag"
            done
          done
        done
      done
      sshx "$PROXY_INT" "sudo systemctl stop $proxy"; CURRENT_PROXY=""
    done
  done
}

# --- provenance: record the exact versions under test ------------------------
unit_bin() { # host unit -> ExecStart binary path
  sshx "$1" "systemctl show -p ExecStart --value '$2'" | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -1
}
collect_versions() {
  log "recording proxy + tool versions -> $RUN/versions.txt"
  local p bin v
  {
    for p in $PROXIES; do
      bin=$(unit_bin "$PROXY_INT" "$p" 2>/dev/null || true)
      v=unknown
      if [ -n "$bin" ]; then
        case $p in
          haproxy)       v=$(sshx "$PROXY_INT" "$bin -v 2>&1 | head -1" || echo unknown) ;;
          envoy)         v=$(sshx "$PROXY_INT" "$bin --version 2>&1 | tail -1" || echo unknown) ;;
          traefik|caddy) v=$(sshx "$PROXY_INT" "$bin version 2>&1 | head -1" || echo unknown) ;;
          *)             v=$(sshx "$PROXY_INT" "$bin --version 2>&1 || $bin -v 2>&1 || true" | head -1 || echo unknown) ;;
        esac
      fi
      printf '%s: %s\n' "$p" "${v:-unknown}"
    done
    bin=$(unit_bin "${BACKEND_INT[0]}" nginx 2>/dev/null || true)
    if [ -n "$bin" ]; then
      printf 'nginx: %s\n' "$(sshx "${BACKEND_INT[0]}" "$bin -v 2>&1" || echo unknown)"
    fi
    printf 'k6: %s\n'   "$(sshx "${LOADGEN_INT[0]}" 'k6 version 2>&1 | head -1' || echo unknown)"
    printf 'wrk2: %s\n' "$(sshx "${LOADGEN_INT[0]}" 'wrk2 -v 2>&1 | head -1' || echo unknown)"
  } > "$RUN/versions.txt"
}

main() {
  setup
  collect_versions
  local p; for p in $PROXIES; do run_proxy "$p"; done
  log "snapshotting Prometheus"
  metrics/snapshot.sh "bench@$CONTROL_EXT" "$RUN" || log "snapshot failed (continuing)"
  cp "$MATRIX" "$RUN/matrix.yaml"; cp "$INVENTORY" "$RUN/inventory.json" 2>/dev/null || true
  log "done -> $RUN  (run 'make report')"
}
main

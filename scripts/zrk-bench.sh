#!/usr/bin/env bash
# Single-loadgen, OPEN-LOOP suite driver: ramps each proxy with zrk
# (loadgen/zrk) and writes per-proxy NDJSON/JSON/HDR + meta.json for
# report/report.py. One 4-core loadgen saturates a 1-CPU proxy under its own
# limit, so there is no second loadgen.
#
#   PROXIES="direct zoxy haproxy" MAX_RATE=160000 make ...  (or run directly)
set -euo pipefail
cd "$(dirname "$0")/.."

TF=${TF:-tofu}; SSH_USER=${SSH_USER:-ubuntu}; REMOTE=${REMOTE_DIR:-bench}
PROXIES=${PROXIES:-"direct zoxy haproxy envoy traefik nginx pingora"}
MAX_RATE=${MAX_RATE:-67000}
RAMP_SECONDS=${RAMP_SECONDS:-300}
START_RATE=${START_RATE:-200}
CONNECTIONS=${CONNECTIONS:-500}    # in-flight cap; the sweet spot — past each proxy's throughput peak, before high-concurrency collapse; well under zoxy's ~1386 conn_slot default
TIMEOUT_S=${TIMEOUT_S:-1}          # per-request WIRE timeout (hung-conn guard). It
                                   # does NOT bound the CO-corrected tail (that's a
                                   # scheduling delay, not wire time); latency
                                   # fairness lives in the report, sampled at a
                                   # common sub-knee REF_RATE. See run.py's note.
ZOXY_REF=${ZOXY_REF:-main}
ZRK_VERSION=${ZRK_VERSION:-0.4.1}  # pinned zrk release (see loadgen/zrk/build.sh)
COOLDOWN=${COOLDOWN:-8}
RUNID=${RUNID:-zrk-$(date -u +%Y%m%d-%H%M%S)}

inv=$($TF -chdir=cloud output -json inventory)
ip() { echo "$inv" | jq -r ".$1.$2 // empty"; }
LG=$(ip loadgen external_ip); PROXY=$(ip proxy external_ip)
LG_PRIV=$(ip loadgen internal_ip)
PROXY_PRIV=$(ip proxy internal_ip); BACKEND_PRIV=$(ip backend internal_ip)
PROM="http://$LG:9090"
RESULTS="results/$RUNID"; mkdir -p "$RESULTS"
ln -sfn "$RUNID" results/latest   # `make report` renders results/latest
COMPOSE="docker compose -f compose.yaml -f compose.cloud.yaml"
PENV="ZOXY_REF=$ZOXY_REF BACKEND_IP=$BACKEND_PRIV"

echo ">>> runid=$RUNID proxies=[$PROXIES] ramp=$START_RATE->${MAX_RATE}rps/${RAMP_SECONDS}s conns=$CONNECTIONS (proxies capped to 1 CPU)"

# --- cloud prometheus targets (file_sd): proxy cAdvisor :8081 for container
# CPU/mem, node_exporter :9100 per host, and the loadgen's live zrk /metrics ----
BACKEND_PUB=$(ip backend external_ip)
mkdir -p monitoring/targets/cloud
cat > monitoring/targets/cloud/zrk.yml <<EOF
- targets: ["$LG_PRIV:8090"]
  labels: { role: loadgen }
EOF
cat > monitoring/targets/cloud/cadvisor.yml <<EOF
- targets: ["$PROXY_PRIV:8081"]
  labels: { role: proxy }
EOF
# zoxy's own admin/metrics listener (config admin.bind :9101); only up during a
# zoxy ramp — file_sd tolerates it being "down" for the other proxies.
cat > monitoring/targets/cloud/zoxy.yml <<EOF
- targets: ["$PROXY_PRIV:9101"]
  labels: { role: proxy, proxy: zoxy }
EOF
cat > monitoring/targets/cloud/node.yml <<EOF
- targets: ["$LG_PRIV:9100"]
  labels: { role: loadgen }
- targets: ["$PROXY_PRIV:9100"]
  labels: { role: proxy }
- targets: ["$BACKEND_PRIV:9100"]
  labels: { role: backend }
EOF

# --- ship the repo to ALL three hosts: the loadgen runs the monitoring stack,
# the proxy is the SUT, the backend is the origin ------------------------------
for h in "$LG" "$PROXY" "$BACKEND_PUB"; do
    rsync -az --delete --exclude .git --exclude results --exclude .env --exclude .env.cloud \
        --exclude 'cloud/.terraform*' --exclude 'cloud/terraform.tfstate*' ./ "$SSH_USER@$h:$REMOTE/"
done

# bring up: monitoring (prometheus/grafana/cadvisor/node) on the loadgen, origin
# on the backend, exporters on the proxy. Non-fatal — a `direct` run (loadgen ->
# backend) needs neither prometheus nor the proxy VM.
ssh -o BatchMode=yes "$SSH_USER@$LG" "cd $REMOTE && PROM_TARGETS=cloud PROM_URL=http://$LG_PRIV:9090 $COMPOSE --profile monitoring up -d" >/dev/null 2>&1 || true
# prometheus.yml is a SINGLE-FILE bind mount and rsync replaces it via a temp file
# + atomic rename (new inode), so a long-lived container keeps the OLD inode — a
# /-/reload just re-reads the stale config and never sees job/scrape-config edits
# (the targets/ DIR mount is fine — file adds there are live). Force-recreate
# prometheus so the mount re-resolves to the current file; the named tsdb volume
# survives the recreate. Do this before the ramp so the run scrapes clean.
ssh -o BatchMode=yes "$SSH_USER@$LG" "cd $REMOTE && PROM_TARGETS=cloud PROM_URL=http://$LG_PRIV:9090 $COMPOSE --profile monitoring up -d --force-recreate prometheus" >/dev/null 2>&1 || true
ssh -o BatchMode=yes "$SSH_USER@$BACKEND_PUB" "cd $REMOTE && $COMPOSE --profile backend up -d --wait" >/dev/null 2>&1 || true
ssh -o BatchMode=yes "$SSH_USER@$PROXY" "cd $REMOTE && $PENV $COMPOSE --profile monitoring up -d cadvisor node_exporter" >/dev/null 2>&1 || true

# fetch the pinned zrk release binary locally (build.sh self-skips if current),
# ship the static binary + orchestrator to the loadgen — nothing built there
echo ">>> fetching zrk release (v$ZRK_VERSION)"
ZRK_VERSION=$ZRK_VERSION ./loadgen/zrk/build.sh
ssh -o BatchMode=yes "$SSH_USER@$LG" 'mkdir -p ~/zrk'
rsync -az --exclude src loadgen/zrk/ "$SSH_USER@$LG:zrk/"

meta="$RESULTS/meta.json"
echo "{\"prom\":\"$PROM\",\"runid\":\"$RUNID\",\"runs\":{}}" > "$meta"

record() { # proxy start end
    python3 - "$meta" "$1" "$2" "$3" "$MAX_RATE" "$RAMP_SECONDS" "$START_RATE" <<'PY'
import json,sys
f,p,s,e,mr,rs,sr=sys.argv[1:8]
m=json.load(open(f))
m["runs"][p]={"start":s,"end":e,"max_rate":int(mr),"ramp_seconds":int(rs),
              "start_rate":int(sr),"loadgens":["lg1"]}
json.dump(m,open(f,"w"),indent=2)
PY
}

for p in $PROXIES; do
    echo ">>> [$p] starting"
    if [[ $p == direct ]]; then
        target="http://$BACKEND_PRIV:9000/1k"
    else
        ssh -o BatchMode=yes "$SSH_USER@$PROXY" "cd $REMOTE && $PENV $COMPOSE --profile $p up -d --build --wait $p" >/dev/null
        target="http://$PROXY_PRIV:8080/1k"
    fi
    # warm probe
    for i in $(seq 1 20); do
        ssh -o BatchMode=yes "$SSH_USER@$LG" "curl -sf -o /dev/null $target" && break
        [[ $i == 20 ]] && { echo "fatal: [$p] never served 200 at $target"; exit 1; }
        sleep 1
    done

    echo ">>> [$p] ramping ${RAMP_SECONDS}s"
    start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    ssh -o BatchMode=yes "$SSH_USER@$LG" "docker run --rm --network host --ulimit nofile=1048576 \
        -v ~/zrk:/w -w /w \
        -e TARGET=$target -e MAX_RATE=$MAX_RATE -e RAMP_SECONDS=$RAMP_SECONDS -e START_RATE=$START_RATE \
        -e CONNECTIONS=$CONNECTIONS -e TIMEOUT_S=$TIMEOUT_S \
        -e OUT=/w/$p.lg1 -e NAME=$p -e RUNID=$RUNID -e METRICS_ADDR=:8090 \
        python:3-alpine python3 /w/run.py" 2>&1 | grep -E 'peak|knee' || true
    end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    for ext in ndjson json hgrm; do
        scp -q "$SSH_USER@$LG:zrk/$p.lg1.$ext" "$RESULTS/" 2>/dev/null || true
    done
    record "$p" "$start" "$end"

    if [[ $p != direct ]]; then
        ssh -o BatchMode=yes "$SSH_USER@$PROXY" "cd $REMOTE && $COMPOSE --profile $p stop $p && $COMPOSE --profile $p rm -f $p" >/dev/null 2>&1 || true
    fi
    echo ">>> [$p] done; cooldown ${COOLDOWN}s"; sleep "$COOLDOWN"
done

echo ">>> render:  PROM_URL=$PROM python3 report/report.py $RESULTS"

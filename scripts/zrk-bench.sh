#!/usr/bin/env bash
# Single-loadgen, OPEN-LOOP suite driver: ramps each proxy with zrk-runner
# (loadgen/zrk-runner — calls zrk's own runner.run in-process, see its
# main.zig) and writes per-proxy NDJSON/JSON/HDR + meta.json for
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
REQ_PATH=${REQ_PATH:-/1k}          # canned response body: /64 /1k /10k /100k (see backend/10-gen-bodies.sh)
THREADS=${THREADS:-4}              # OS threads driving zrk's zio coroutine engine (>=1.0.0;
                                   # replaces std.Io.Threaded's thread-per-connection model).
                                   # Match the loadgen VM's core count (loadgen_cores, default 4
                                   # in cloud/variables.tf), not CONNECTIONS.
TIMEOUT_S=${TIMEOUT_S:-1}          # per-request WIRE timeout (hung-conn guard). It
                                   # does NOT bound the CO-corrected tail (that's a
                                   # scheduling delay, not wire time); latency
                                   # fairness lives in the report, sampled at a
                                   # common sub-knee REF_RATE. See report/report.py's note.
ZOXY_REF=${ZOXY_REF:-main}
ZOXY_CONN_SLOTS=${ZOXY_CONN_SLOTS:-}  # opt-in: zoxy's limits.conn_slots (default
                                   # 1386 when unset); raise toward the compiled
                                   # ceiling (12282 by default, or CONN_SLOTS_MAX
                                   # below if set) to test past it — pair with
                                   # a much higher CONNECTIONS to actually reach it
ZOXY_UPSTREAM_SLOTS=${ZOXY_UPSTREAM_SLOTS:-}  # opt-in: zoxy's limits.upstream_slots
                                   # (default 1024 when unset, deliberately NOT
                                   # tracking its own ceiling — an operator opts
                                   # up explicitly). Raise toward the compiled
                                   # ceiling (8192 by default) for a c10k-scale
                                   # run; 1024 pins and sheds ~1/3 of responses
                                   # at 10k connections, 8192 doesn't (zoxy #107).
UPSTREAM_SLOTS_MAX=${UPSTREAM_SLOTS_MAX:-}  # opt-in build-time override of the
                                   # comptime upstream-pool ceiling (default
                                   # 8192 as of zoxy #107 — this is for pushing
                                   # PAST that, not reaching it; use
                                   # ZOXY_UPSTREAM_SLOTS for that). Shares the
                                   # same io_uring completion-queue budget as
                                   # conn_slots_max, so raising this LOWERS it
                                   # (comptime-asserted self-consistent) - must
                                   # be set together with the matching
                                   # CONN_SLOTS_MAX or the zoxy build fails loudly.
CONN_SLOTS_MAX=${CONN_SLOTS_MAX:-}  # the conn_slots_max that pairs with
                                   # UPSTREAM_SLOTS_MAX above (see
                                   # proxies/zoxy/Dockerfile); e.g. 8192/12282
                                   # is now the compiled default, not an override.
HEAD_BYTES_MAX_KIB=${HEAD_BYTES_MAX_KIB:-}  # opt-in build-time override of
                                   # zoxy's max L7 head size, in KiB (default
                                   # 8; comptime floor 1). Shrinks the per-
                                   # conn/upstream-slot memory footprint (see
                                   # proxies/zoxy/Dockerfile) - fine for this
                                   # bench's small headers, not safe in general.
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
PENV="ZOXY_REF=$ZOXY_REF ZOXY_CONN_SLOTS=$ZOXY_CONN_SLOTS ZOXY_UPSTREAM_SLOTS=$ZOXY_UPSTREAM_SLOTS UPSTREAM_SLOTS_MAX=$UPSTREAM_SLOTS_MAX CONN_SLOTS_MAX=$CONN_SLOTS_MAX HEAD_BYTES_MAX_KIB=$HEAD_BYTES_MAX_KIB BACKEND_IP=$BACKEND_PRIV"

echo ">>> runid=$RUNID proxies=[$PROXIES] ramp=$START_RATE->${MAX_RATE}rps/${RAMP_SECONDS}s conns=$CONNECTIONS threads=$THREADS path=$REQ_PATH (proxies capped to 1 CPU)"

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

# Cross-compile zrk-runner locally (static musl binary — no container, no
# runtime deps) and ship just the binary to the loadgen; nothing built there.
# The zrk/zio versions actually used are pinned in
# loadgen/zrk-runner/build.zig.zon (via `zig fetch --save`), not here.
echo ">>> building zrk-runner"
./loadgen/zrk-runner/build.sh
ssh -o BatchMode=yes "$SSH_USER@$LG" 'mkdir -p ~/zrk'
rsync -az loadgen/zrk-runner/zig-out/bin/zrk-runner "$SSH_USER@$LG:zrk/zrk-runner"

meta="$RESULTS/meta.json"
echo "{\"prom\":\"$PROM\",\"runid\":\"$RUNID\",\"runs\":{}}" > "$meta"

record() { # proxy start end zoxy_commit
    python3 - "$meta" "$1" "$2" "$3" "$MAX_RATE" "$RAMP_SECONDS" "$START_RATE" "${4:-}" <<'PY'
import json,sys
f,p,s,e,mr,rs,sr,zc=sys.argv[1:9]
m=json.load(open(f))
entry={"start":s,"end":e,"max_rate":int(mr),"ramp_seconds":int(rs),
       "start_rate":int(sr),"loadgens":["lg1"]}
if zc:
    entry["zoxy_commit"]=zc  # resolved HEAD from the running image (see
                             # proxies/zoxy/Dockerfile's /etc/zoxy/zoxy-commit),
                             # not the requested ZOXY_REF — a floating ref like
                             # "main" would otherwise leave no record of which
                             # commit actually ran.
m["runs"][p]=entry
json.dump(m,open(f,"w"),indent=2)
PY
}

for p in $PROXIES; do
    echo ">>> [$p] starting"
    if [[ $p == direct ]]; then
        target="http://$BACKEND_PRIV:9000$REQ_PATH"
    else
        ssh -o BatchMode=yes "$SSH_USER@$PROXY" "cd $REMOTE && $PENV $COMPOSE --profile $p up -d --build --wait $p" >/dev/null
        target="http://$PROXY_PRIV:8080$REQ_PATH"
    fi
    # warm probe
    for i in $(seq 1 20); do
        ssh -o BatchMode=yes "$SSH_USER@$LG" "curl -sf -o /dev/null $target" && break
        [[ $i == 20 ]] && { echo "fatal: [$p] never served 200 at $target"; exit 1; }
        sleep 1
    done

    zoxy_commit=""
    if [[ $p == zoxy ]]; then
        zoxy_commit=$(ssh -o BatchMode=yes "$SSH_USER@$PROXY" "docker exec zoxy cat /etc/zoxy/zoxy-commit" 2>/dev/null || echo "")
    fi

    echo ">>> [$p] ramping ${RAMP_SECONDS}s"
    start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # wipe any prior outputs for this proxy first — a genuinely stale result
    # under the same proxy name should never look like this run's data.
    ssh -o BatchMode=yes "$SSH_USER@$LG" "rm -f zrk/$p.lg1.ndjson zrk/$p.lg1.json zrk/$p.lg1.hgrm"
    # zrk-runner statically links musl and runs directly on the host — no
    # container, so no seccomp profile to reconcile with io_uring. nofile
    # needs raising (SSH sessions default low); memlock is already generous
    # on this fleet's images, but the explicit unlimited is cheap insurance
    # against a differently-configured host.
    #
    # Unlike the old subprocess+CLI setup, zrk-runner calls zrk's own
    # `runner.run` in-process and propagates its real error (see zrk's fix
    # for a canceled run silently reporting a truncated success) — so a
    # non-zero exit here is a genuine, meaningful signal, not something to
    # swallow. Capture it via PIPESTATUS (grep's own exit code is irrelevant)
    # and warn rather than silently trusting a bad result.
    set +e
    ssh -o BatchMode=yes "$SSH_USER@$LG" "cd $REMOTE && ulimit -n 1048576; ulimit -l unlimited 2>/dev/null; \
        TARGET=$target MAX_RATE=$MAX_RATE RAMP_SECONDS=$RAMP_SECONDS START_RATE=$START_RATE \
        CONNECTIONS=$CONNECTIONS THREADS=$THREADS TIMEOUT_S=$TIMEOUT_S \
        OUT=~/zrk/$p.lg1 NAME=$p RUNID=$RUNID METRICS_ADDR=:8090 \
        ~/zrk/zrk-runner" 2>&1 | grep -E 'peak|knee|interrupt|zrk: '
    zrk_rc=${PIPESTATUS[0]}
    set -e
    if [[ $zrk_rc -ne 0 ]]; then
        echo ">>> [$p] WARNING: zrk-runner exited $zrk_rc — result may be incomplete, treat with suspicion"
    fi
    end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    for ext in ndjson json hgrm; do
        scp -q "$SSH_USER@$LG:zrk/$p.lg1.$ext" "$RESULTS/" 2>/dev/null || true
    done
    record "$p" "$start" "$end" "$zoxy_commit"

    if [[ $p != direct ]]; then
        ssh -o BatchMode=yes "$SSH_USER@$PROXY" "cd $REMOTE && $COMPOSE --profile $p stop $p && $COMPOSE --profile $p rm -f $p" >/dev/null 2>&1 || true
    fi
    echo ">>> [$p] done; cooldown ${COOLDOWN}s"; sleep "$COOLDOWN"
done

echo ">>> render:  PROM_URL=$PROM python3 report/report.py $RESULTS"

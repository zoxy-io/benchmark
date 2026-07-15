#!/usr/bin/env bash
# Single-big-VM (megabox) suite: loadgen + proxy + backend co-located on ONE VM
# over LOOPBACK, each role pinned to a disjoint cpuset. Measures a proxy's RAW
# relay capacity with the virtualized cross-VM network EXCLUDED — the 3-VM fleet
# is ~half this because of the Yandex SDN per-packet tax (see notes). Traffic
# goes to the megabox's own private IP, which the kernel routes via `lo` (no
# NIC/SDN) yet every proxy's DNS resolves (127.0.0.1 breaks envoy's STRICT_DNS).
#
# Prereqs: make megabox-up  (tofu apply -var megabox=true). Then: make megabox-bench.
#
#   PROXIES="direct zoxy haproxy" PROXY_CPUS=4 MAX_RATE=200000 ./scripts/megabox-bench.sh
set -uo pipefail
cd "$(dirname "$0")/.."

TF=${TF:-tofu}; SSH_USER=${SSH_USER:-ubuntu}; REMOTE=${REMOTE_DIR:-bench}
PROXIES=${PROXIES:-"direct zoxy haproxy envoy traefik nginx pingora"}
PROXY_CPUS=${PROXY_CPUS:-4}
BACKEND_CPUS=${BACKEND_CPUS:-6}    # backend cores (kept off the proxy's cpuset)
MAX_RATE=${MAX_RATE:-200000}
RAMP_SECONDS=${RAMP_SECONDS:-120}
CONNECTIONS=${CONNECTIONS:-2000}   # open connections = in-flight cap (open-loop guard)
THREADS=${THREADS:-}               # zrk worker threads (empty -> loadgen nproc)
TIMEOUT_S=${TIMEOUT_S:-5}
ZOXY_REF=${ZOXY_REF:-main}
ZRK_REF=${ZRK_REF:-e82ac7e}        # pinned zrk build (see loadgen/zrk/build.sh)
RUNID=${RUNID:-megabox-$(date -u +%Y%m%d-%H%M%S)}

inv=$($TF -chdir=cloud output -json inventory)
MB=$(echo "$inv" | jq -r '.megabox.external_ip // empty')
BIP=$(echo "$inv" | jq -r '.megabox.internal_ip // empty')
[ -n "$MB" ] || { echo "no megabox in the fleet — run: make megabox-up"; exit 1; }
sshm() { ssh -o BatchMode=yes "$SSH_USER@$MB" "$@"; }

# --- cpuset layout: proxy | backend | loadgen | OS(reserve 2) ------------------
NC=$(sshm nproc)
P_SET="0-$((PROXY_CPUS - 1))"
B_SET="$PROXY_CPUS-$((PROXY_CPUS + BACKEND_CPUS - 1))"
V_START=$((PROXY_CPUS + BACKEND_CPUS)); V_END=$((NC - 3))   # leave last 2 cores for OS/softirq
[ "$V_START" -le "$V_END" ] || { echo "not enough cores ($NC) for PROXY_CPUS=$PROXY_CPUS + BACKEND_CPUS=$BACKEND_CPUS + loadgen"; exit 1; }
V_SET="$V_START-$V_END"
echo ">>> megabox=$MB ($NC cores)  proxy=$P_SET backend=$B_SET loadgen=$V_SET  ramp $MAX_RATE/${RAMP_SECONDS}s conns=$CONNECTIONS"

RESULTS="results/$RUNID"; mkdir -p "$RESULTS"; ln -sfn "$RUNID" results/latest
META="$RESULTS/meta.json"
echo "{\"prom\":\"http://$MB:9090\",\"runid\":\"$RUNID\",\"runs\":{}}" > "$META"
COMPOSE="docker compose -f compose.yaml -f compose.cloud.yaml"
PENV="ZOXY_REF=$ZOXY_REF PROXY_CPUS=$PROXY_CPUS PROXY_CPUSET=$P_SET BACKEND_IP=$BIP PROM_TARGETS=cloud PROM_URL=http://$BIP:9090"

# --- ship repo, build zrk, monitoring targets -> the megabox, roles up ---------
rsync -az --delete --exclude .git --exclude results --exclude .env --exclude .env.cloud \
    --exclude 'cloud/.terraform*' --exclude 'cloud/terraform.tfstate*' ./ "$SSH_USER@$MB:$REMOTE/"
echo ">>> building zrk (ref=$ZRK_REF)"; ZRK_REF=$ZRK_REF ./loadgen/zrk/build.sh
sshm "mkdir -p ~/zrk"; rsync -az --exclude src loadgen/zrk/ "$SSH_USER@$MB:zrk/"
sshm "cd $REMOTE/monitoring/targets/cloud && for pr in cadvisor:8081 node:9100 zrk:8090; do n=\${pr%%:*}; port=\${pr##*:}; printf -- '- targets: [\"$BIP:%s\"]\n  labels: { role: megabox }\n' \"\$port\" > \$n.yml; done"
sshm "cd $REMOTE && $PENV $COMPOSE --profile monitoring --profile backend up -d --wait" >/dev/null 2>&1
sshm "docker update --cpuset-cpus=$B_SET backend" >/dev/null 2>&1

record() { python3 -c "import json,sys; m=json.load(open('$META')); m['runs']['$1']={'start':'$2','end':'$3','max_rate':$MAX_RATE,'ramp_seconds':$RAMP_SECONDS,'start_rate':200,'loadgens':['lg1'],'proxy_cpuset':'$P_SET'}; json.dump(m,open('$META','w'),indent=2)"; }

for p in $PROXIES; do
    echo ">>> [$p] starting"
    target="http://$BIP:9000/1k"
    if [ "$p" != direct ]; then
        sshm "cd $REMOTE && $PENV $COMPOSE --profile $p up -d --build --force-recreate --wait $p" >/dev/null 2>&1 || true
        target="http://$BIP:8080/1k"
        ok=0
        for i in $(seq 1 30); do sshm "curl -sf -o /dev/null $target" 2>/dev/null && { ok=1; break; }; sleep 1; done
        if [ "$ok" != 1 ]; then
            echo "  [$p] PROBE FAILED — logs:"; sshm "docker logs $p 2>&1 | tail -3"
            sshm "cd $REMOTE && $COMPOSE --profile $p rm -sf $p" >/dev/null 2>&1   # ALWAYS clean up (else it blocks :8080 for the next)
            continue
        fi
        # verify the kernel cpuset cap — no proxy may use more than PROXY_CPUS cores
        cset=$(sshm "docker inspect -f '{{.HostConfig.CpusetCpus}}' $p" 2>/dev/null)
        if [ "$cset" = "$P_SET" ]; then echo "  [$p] cpuset=$cset ✓ capped"
        else echo "  [$p] !!! cpuset='$cset' EXPECTED '$P_SET' — NOT capped, results unfair"; fi
    fi
    start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo ">>> [$p] ramping ${RAMP_SECONDS}s to $MAX_RATE"
    sshm "docker run --rm --network host --cpuset-cpus=$V_SET --ulimit nofile=1048576 -v ~/zrk:/w -w /w \
        -e TARGET=$target -e MAX_RATE=$MAX_RATE -e RAMP_SECONDS=$RAMP_SECONDS -e START_RATE=200 \
        -e CONNECTIONS=$CONNECTIONS -e THREADS=$THREADS -e TIMEOUT_S=$TIMEOUT_S \
        -e OUT=/w/$p.lg1 -e NAME=$p -e RUNID=$RUNID -e METRICS_ADDR=:8090 \
        python:3-alpine python3 /w/run.py" 2>&1 | grep -E 'peak|knee'
    end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    for ext in ndjson json hgrm; do scp -q "$SSH_USER@$MB:zrk/$p.lg1.$ext" "$RESULTS/" 2>/dev/null || true; done
    record "$p" "$start" "$end"
    [ "$p" != direct ] && sshm "cd $REMOTE && $COMPOSE --profile $p rm -sf $p" >/dev/null 2>&1
    echo ">>> [$p] done"; sleep 5
done
echo ">>> render:  python3 report/report.py $RESULTS"

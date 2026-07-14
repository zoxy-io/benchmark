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
MAX_WORKERS=${MAX_WORKERS:-2000}
CONNECTIONS=${CONNECTIONS:-2000}
ZOXY_REF=${ZOXY_REF:-main}
RUNID=${RUNID:-megabox-$(date -u +%Y%m%d-%H%M%S)}

inv=$($TF -chdir=cloud output -json inventory)
MB=$(echo "$inv" | jq -r '.megabox.external_ip // empty')
BIP=$(echo "$inv" | jq -r '.megabox.internal_ip // empty')
[ -n "$MB" ] || { echo "no megabox in the fleet — run: make megabox-up"; exit 1; }
sshm() { ssh -o BatchMode=yes "$SSH_USER@$MB" "$@"; }

# --- cpuset layout: proxy | backend | vegeta | OS(reserve 2) -------------------
NC=$(sshm nproc)
P_SET="0-$((PROXY_CPUS - 1))"
B_SET="$PROXY_CPUS-$((PROXY_CPUS + BACKEND_CPUS - 1))"
V_START=$((PROXY_CPUS + BACKEND_CPUS)); V_END=$((NC - 3))   # leave last 2 cores for OS/softirq
[ "$V_START" -le "$V_END" ] || { echo "not enough cores ($NC) for PROXY_CPUS=$PROXY_CPUS + BACKEND_CPUS=$BACKEND_CPUS + loadgen"; exit 1; }
V_SET="$V_START-$V_END"
echo ">>> megabox=$MB ($NC cores)  proxy=$P_SET backend=$B_SET vegeta=$V_SET  ramp $MAX_RATE/${RAMP_SECONDS}s workers<=$MAX_WORKERS"

RESULTS="results/$RUNID"; mkdir -p "$RESULTS"; ln -sfn "$RUNID" results/latest
META="$RESULTS/meta.json"
echo "{\"prom\":\"http://$MB:9090\",\"runid\":\"$RUNID\",\"runs\":{}}" > "$META"
COMPOSE="docker compose -f compose.yaml -f compose.cloud.yaml"
PENV="ZOXY_REF=$ZOXY_REF PROXY_CPUS=$PROXY_CPUS PROXY_CPUSET=$P_SET BACKEND_IP=$BIP PROM_TARGETS=cloud PROM_URL=http://$BIP:9090"

# --- ship repo, build vegeta-ramp, monitoring targets -> the megabox, roles up -
rsync -az --delete --exclude .git --exclude results --exclude .env --exclude .env.cloud \
    --exclude 'cloud/.terraform*' --exclude 'cloud/terraform.tfstate*' ./ "$SSH_USER@$MB:$REMOTE/"
sshm "mkdir -p ~/vegeta-ramp"; rsync -az loadgen/vegeta-ramp/ "$SSH_USER@$MB:vegeta-ramp/"
sshm "test -x ~/vegeta-ramp/vegeta-ramp || (cd ~/vegeta-ramp && docker run --rm -v \"\$PWD\":/src -w /src golang:1.23 sh -c 'CGO_ENABLED=0 go build -o vegeta-ramp .')"
sshm "cd $REMOTE/monitoring/targets/cloud && for pr in cadvisor:8081 node:9100 vegeta:8090; do n=\${pr%%:*}; port=\${pr##*:}; printf -- '- targets: [\"$BIP:%s\"]\n  labels: { role: megabox }\n' \"\$port\" > \$n.yml; done"
sshm "cd $REMOTE && $PENV $COMPOSE --profile monitoring --profile backend up -d --wait" >/dev/null 2>&1
sshm "docker update --cpuset-cpus=$B_SET backend" >/dev/null 2>&1

record() { python3 -c "import json,sys; m=json.load(open('$META')); m['runs']['$1']={'start':'$2','end':'$3','max_rate':$MAX_RATE,'ramp_seconds':$RAMP_SECONDS,'start_rate':200,'loadgens':['lg1']}; json.dump(m,open('$META','w'),indent=2)"; }

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
    fi
    start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo ">>> [$p] ramping ${RAMP_SECONDS}s to $MAX_RATE"
    sshm "docker run --rm --network host --cpuset-cpus=$V_SET --ulimit nofile=1048576 -v ~/vegeta-ramp:/w -w /w \
        -e TARGET=$target -e MAX_RATE=$MAX_RATE -e RAMP_SECONDS=$RAMP_SECONDS -e START_RATE=200 \
        -e CONNECTIONS=$CONNECTIONS -e MAX_WORKERS=$MAX_WORKERS -e OUT=/w/$p.lg1.csv -e NAME=$p -e RUNID=$RUNID \
        alpine:3 /w/vegeta-ramp" 2>&1 | grep -E 'peak|knee'
    end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    scp -q "$SSH_USER@$MB":vegeta-ramp/$p.lg1.csv "$RESULTS/"
    record "$p" "$start" "$end"
    [ "$p" != direct ] && sshm "cd $REMOTE && $COMPOSE --profile $p rm -sf $p" >/dev/null 2>&1
    echo ">>> [$p] done"; sleep 5
done
echo ">>> render:  python3 report/report_vegeta.py $RESULTS"

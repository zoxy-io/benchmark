#!/usr/bin/env bash
# Snapshot the control node's Prometheus TSDB and pull it back, so a run's full
# metric history travels with its results/ dir and can be replayed offline.
#
#   snapshot.sh CONTROL_SSH DEST_DIR
#   e.g. snapshot.sh bench@51.2.3.4 results/2026-07-05T12-00-00
set -euo pipefail

CTRL=$1 DEST=$2   # CTRL = bench@<control_external_ip> (the sole public host)
mkdir -p "$DEST"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

name=$(ssh "${SSH_OPTS[@]}" "$CTRL" 'curl -sf -XPOST http://localhost:9090/api/v1/admin/tsdb/snapshot' \
       | jq -r '.data.name')
[ -n "$name" ] && [ "$name" != null ] || { echo "snapshot failed (is --web.enable-admin-api set?)" >&2; exit 1; }

ssh "${SSH_OPTS[@]}" "$CTRL" "sudo tar -C /var/lib/bench-prom/snapshots -czf /tmp/${name}.tgz '${name}'"
scp "${SSH_OPTS[@]}" "$CTRL:/tmp/${name}.tgz" "$DEST/prometheus-snapshot.tgz"
echo "snapshot -> $DEST/prometheus-snapshot.tgz"

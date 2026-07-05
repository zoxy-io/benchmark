#!/usr/bin/env bash
# Render a proxy config from its template with the real backend endpoints and
# thread count, ready to scp to the proxy host.
#
#   render-config.sh PROXY TLS_MODE NPROC OUT_DIR BACKEND[ BACKEND...]
#     PROXY     zoxy|haproxy|envoy|traefik|caddy
#     TLS_MODE  plain|tls   (only zoxy branches on this; it's single-listener)
#     NPROC     vCPU count on the proxy host (haproxy nbthread)
#     OUT_DIR   directory to write the rendered config(s) into
#     BACKEND   one or more "ip:9000"
#
# Prints the primary rendered file path(s), one per line.
set -euo pipefail

PROXY=$1 TLS_MODE=$2 NPROC=$3 OUT=$4
shift 4
BACKENDS=("$@")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T="$ROOT/proxies"
mkdir -p "$OUT"

# --- build the proxy-specific backend fragment ------------------------------
# Inline fragments (single line) for zoxy/caddy; a temp block file for the
# YAML/cfg proxies that need multiple indented lines.
inline=""
blk=$(mktemp)
case $PROXY in
  zoxy)
    parts=(); for b in "${BACKENDS[@]}"; do parts+=("\"$b\""); done
    inline=$(IFS=,; echo "${parts[*]}")
    ;;
  caddy)
    inline="${BACKENDS[*]}"          # space-separated ip:9000 ip:9000
    ;;
  haproxy)
    i=0; for b in "${BACKENDS[@]}"; do echo "    server b$i $b"; i=$((i+1)); done > "$blk"
    ;;
  traefik)
    for b in "${BACKENDS[@]}"; do echo "          - url: \"http://$b\""; done > "$blk"
    ;;
  envoy)
    for b in "${BACKENDS[@]}"; do
      ip=${b%:*}; port=${b##*:}
      printf '              - endpoint:\n                  address:\n                    socket_address: { address: %s, port_value: %s }\n' "$ip" "$port"
    done > "$blk"
    ;;
  *) echo "unknown proxy: $PROXY" >&2; exit 2 ;;
esac

# fill @@NPROC@@ (no-op where absent), then either inline @@BACKENDS@@ or splice
# the block file in place of the marker line.
fill() { # fill <template> <out>
  if [ -n "$inline" ]; then
    sed -e "s/@@NPROC@@/$NPROC/g" -e "s|@@BACKENDS@@|$inline|g" "$1" > "$2"
  else
    sed "s/@@NPROC@@/$NPROC/g" "$1" \
      | awk -v f="$blk" '/@@BACKENDS@@/{while((getline l<f)>0)print l;close(f);next}{print}' > "$2"
  fi
}

case $PROXY in
  zoxy)
    if [ "$TLS_MODE" = tls ]; then
      fill "$T/zoxy/config.tls.json.tmpl" "$OUT/config.json"
    else
      fill "$T/zoxy/config.plain.json.tmpl" "$OUT/config.json"
    fi
    echo "$OUT/config.json"
    ;;
  haproxy) fill "$T/haproxy/haproxy.cfg.tmpl" "$OUT/haproxy.cfg"; echo "$OUT/haproxy.cfg" ;;
  envoy)   fill "$T/envoy/envoy.yaml.tmpl"    "$OUT/envoy.yaml";  echo "$OUT/envoy.yaml" ;;
  caddy)   fill "$T/caddy/Caddyfile.tmpl"     "$OUT/Caddyfile";   echo "$OUT/Caddyfile" ;;
  traefik)
    cp "$T/traefik/traefik.yml" "$OUT/traefik.yml"
    fill "$T/traefik/dynamic.yml.tmpl" "$OUT/dynamic.yml"
    echo "$OUT/traefik.yml"; echo "$OUT/dynamic.yml"
    ;;
esac

rm -f "$blk"

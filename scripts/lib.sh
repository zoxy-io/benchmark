# Shared helpers: parse the terraform inventory and talk to hosts over SSH.
# Sourced by run.sh. Expects INVENTORY (default terraform/inventory.json) — the
# JSON from `tofu output -json`.

INVENTORY=${INVENTORY:-terraform/inventory.json}

_jqi() { jq -r "$1" "$INVENTORY"; }

hosts_of_role() { _jqi ".inventory.value.hosts | to_entries[] | select(.value.role==\"$1\") | .key"; }
int_ip()        { _jqi ".inventory.value.hosts[\"$1\"].internal_ip"; }
ext_ip()        { _jqi ".inventory.value.hosts[\"$1\"].external_ip"; }
role_int_ips()  { local h; for h in $(hosts_of_role "$1"); do int_ip "$h"; done; }
role_ext_ips()  { local h; for h in $(hosts_of_role "$1"); do ext_ip "$h"; done; }

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=10 -o LogLevel=ERROR)
sshx()  { local host=$1; shift; ssh "${SSH_OPTS[@]}" "bench@$host" "$@"; }
scpx()  { scp "${SSH_OPTS[@]}" "$@"; }
scprx() { scp -r "${SSH_OPTS[@]}" "$@"; }

log() { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# systemd unit name == proxy name (see nix/proxies.nix)
proxy_etc() {
  case $1 in
    zoxy) echo /etc/zoxy ;; haproxy) echo /etc/haproxy ;; envoy) echo /etc/envoy ;;
    traefik) echo /etc/traefik ;; caddy) echo /etc/caddy ;;
    *) echo "unknown proxy: $1" >&2; return 1 ;;
  esac
}

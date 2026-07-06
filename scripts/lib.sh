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

# Only `control` has a public IP; every other host is reached by its INTERNAL
# IP through control as a jump host. BASTION is set by run.sh to
# "bench@<control_external_ip>"; empty => everything is direct.
BASTION="${BASTION:-}"

# SSH identity. Set SSH_KEY to the private key that matches terraform's
# ssh_public_key; defaults to ~/.ssh/zoxy_bench (the README's keygen path). If
# neither is present, ssh falls back to your agent / default keys. The same key
# authorizes `bench` on every host (terraform injects it fleet-wide), so it
# works for both the control hop and the jumped-to internal hosts.
SSH_KEY="${SSH_KEY:-}"
if [ -z "$SSH_KEY" ] && [ -f "$HOME/.ssh/zoxy_bench" ]; then SSH_KEY="$HOME/.ssh/zoxy_bench"; fi
[ -n "$SSH_KEY" ] && SSH_KEY="${SSH_KEY/#\~/$HOME}"

# BatchMode=yes: never prompt. A missing/wrong key fails fast (clear error)
# instead of silently dropping to an interactive password prompt.
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=10 -o LogLevel=ERROR -o BatchMode=yes)
[ -n "$SSH_KEY" ] && SSH_OPTS+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)

# _jump <host> -> emits "-J <bastion>" (one token per line) unless <host> IS the
# bastion. The same key options apply to both hops via SSH_OPTS.
_jump() {
  [ -n "$BASTION" ] && [ "bench@$1" != "$BASTION" ] && printf -- '-J\n%s\n' "$BASTION"
}

sshx() { # sshx HOST CMD...
  local host=$1; shift
  local j; mapfile -t j < <(_jump "$host")
  ssh "${j[@]}" "${SSH_OPTS[@]}" "bench@$host" "$@"
}
scp_to() { # scp_to HOST DEST SRC...
  local host=$1 dest=$2; shift 2
  local j; mapfile -t j < <(_jump "$host")
  scp "${j[@]}" "${SSH_OPTS[@]}" "$@" "bench@$host:$dest"
}
scp_from() { # scp_from HOST REMOTE LOCAL
  local host=$1 remote=$2 dst=$3
  local j; mapfile -t j < <(_jump "$host")
  scp "${j[@]}" "${SSH_OPTS[@]}" "bench@$host:$remote" "$dst"
}
scp_dir_to() { # scp_dir_to HOST DEST SRCDIR
  local host=$1 dest=$2 src=$3
  local j; mapfile -t j < <(_jump "$host")
  scp -r "${j[@]}" "${SSH_OPTS[@]}" "$src" "bench@$host:$dest"
}

log() { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# systemd unit name == proxy name (see nix/proxies.nix)
proxy_etc() {
  case $1 in
    zoxy) echo /etc/zoxy ;; haproxy) echo /etc/haproxy ;; envoy) echo /etc/envoy ;;
    traefik) echo /etc/traefik ;; caddy) echo /etc/caddy ;;
    *) echo "unknown proxy: $1" >&2; return 1 ;;
  esac
}

#!/usr/bin/env bash
# =============================================================================
#  Open an interactive shell on any node.
#
#      ./scripts/ssh.sh victim
#      ./scripts/ssh.sh attacker-2
#      ./scripts/ssh.sh observer
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_jq
require_ssh

name="${1:-}"

usage() {
  cat >&2 <<'EOF'
usage: ssh.sh <victim|attacker-N|observer>

  victim       the vulnerable Apache node
  attacker-N   1-based attacker index (attacker-1, attacker-2, ...)
  observer     the Prometheus/Grafana node
EOF
}

resolve() {
  case "$1" in
    victim)
      victim_ip
      ;;
    observer)
      local ip; ip="$(observer_ip)"
      [ -n "$ip" ] || die "no observer deployed (deploy_observer = false)"
      printf '%s' "$ip"
      ;;
    attacker-*)
      local index="${1#attacker-}"
      [[ "$index" =~ ^[0-9]+$ ]] || die "attacker index must be a number, e.g. attacker-2"
      mapfile -t ips < <(attacker_ips)
      index=$((index - 1))
      [ "$index" -ge 0 ] && [ "$index" -lt "${#ips[@]}" ] || die "attacker-$((index + 1)) does not exist"
      printf '%s' "${ips[$index]}"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

[ -n "$name" ] || { usage; exit 1; }

ip="$(resolve "$name")"
[ -n "$ip" ] || die "could not resolve $name"

key="$(key_path)"
[ -f "$key" ] || die "private key not found at $key"

log "connecting to $name ($ip)"
exec ssh -i "$key" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$SSH_KNOWN_HOSTS" \
    -o LogLevel=ERROR \
    "ec2-user@$ip"

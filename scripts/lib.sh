#!/usr/bin/env bash
# =============================================================================
#  Shared helpers for the lab scripts. Source this, do not execute it.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$REPO_ROOT/infra"
SSH_KNOWN_HOSTS="${SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts_lab}"

if [ -t 2 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_DIM=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

log()  { printf '%s\n' "${C_BLUE}==>${C_RESET} $*" >&2; }
step() { printf '%s\n' "${C_DIM}    $*${C_RESET}" >&2; }
ok()   { printf '%s\n' "${C_GREEN} ok ${C_RESET} $*" >&2; }
warn() { printf '%s\n' "${C_YELLOW}warn${C_RESET} $*" >&2; }
die()  { printf '%s\n' "${C_RED}fail${C_RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
#  OpenTofu wrapper. Falls back to Terraform if someone has that instead.
# ---------------------------------------------------------------------------
TOFU_BIN=""
detect_tofu() {
  if [ -n "$TOFU_BIN" ]; then return 0; fi
  if command -v tofu >/dev/null 2>&1; then
    TOFU_BIN="tofu"
  elif command -v terraform >/dev/null 2>&1; then
    TOFU_BIN="terraform"
    warn "using terraform instead of tofu"
  else
    die "neither 'tofu' nor 'terraform' was found in PATH"
  fi
}

tf()     { detect_tofu; ( cd "$INFRA_DIR" && "$TOFU_BIN" "$@" ); }
tf_raw() { detect_tofu; ( cd "$INFRA_DIR" && "$TOFU_BIN" output -raw "$1" 2>/dev/null ); }
tf_json() { detect_tofu; ( cd "$INFRA_DIR" && "$TOFU_BIN" output -json ); }

require_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required but was not found in PATH"
}

require_ssh() {
  command -v ssh >/dev/null 2>&1 || die "ssh is required but was not found in PATH"
}

# ---------------------------------------------------------------------------
#  Inventory, read from the OpenTofu outputs
# ---------------------------------------------------------------------------
key_path() { tf_raw ssh_private_key_path; }

victim_ip() { tf_raw victim_public_ip; }

observer_ip() {
  local ip
  ip="$(tf_raw observer_public_ip || true)"
  [ -n "$ip" ] && [ "$ip" != "null" ] && printf '%s' "$ip"
}

attacker_ips() {
  require_jq
  tf_json | jq -r '.attacker_public_ips.value[]?'
}

all_node_ips() {
  victim_ip
  attacker_ips
  observer_ip
}

# ---------------------------------------------------------------------------
#  Remote execution
# ---------------------------------------------------------------------------
remote() {
  # remote <ip> <command...>
  local ip="$1"; shift
  local key; key="$(key_path)"
  [ -f "$key" ] || die "private key not found at $key -- run ./scripts/up.sh first"
  ssh -i "$key" \
      -o BatchMode=yes \
      -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="$SSH_KNOWN_HOSTS" \
      -o LogLevel=ERROR \
      "ec2-user@$ip" "$@"
}

wait_for_ssh() {
  local ip="$1" timeout="${2:-300}" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if remote "$ip" true >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

wait_for_cloud_init() {
  # cloud-init writes "bootstrap complete" as the final line of lab-init.log
  local ip="$1" timeout="${2:-600}" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if remote "$ip" "test -f /var/log/lab-init.log && grep -q 'bootstrap complete' /var/log/lab-init.log" >/dev/null 2>&1; then
      return 0
    fi
    sleep 10
    waited=$((waited + 10))
  done
  return 1
}

confirm() {
  local prompt="${1:-Continue?}"
  if [ "${LAB_ASSUME_YES:-0}" = "1" ]; then return 0; fi
  read -r -p "$prompt [y/N] " reply
  case "$reply" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

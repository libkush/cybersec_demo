#!/usr/bin/env bash
# =============================================================================
#  One-glance health check for every node in the lab.
#      ./scripts/status.sh
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_jq
require_ssh

VICTIM="$(victim_ip)"
OBSERVER="$(observer_ip)"
mapfile -t ATTACKERS < <(attacker_ips)

printf '\n%s\n' "${C_BOLD}Lab nodes${C_RESET}"
printf '%-14s %-16s %-6s %s\n' ROLE ADDRESS SSH DETAIL
printf '%-14s %-16s %-6s %s\n' ---- ------- --- ------

report_row() {
  local role="$1" ip="$2" detail
  if remote "$ip" true >/dev/null 2>&1; then
    detail="$3"
    printf '%-14s %-16s %-6s %s\n' "$role" "$ip" "${C_GREEN}ok${C_RESET}" "$detail"
  else
    printf '%-14s %-16s %-6s %s\n' "$role" "$ip" "${C_RED}no${C_RESET}" "unreachable"
  fi
}

# --- victim -----------------------------------------------------------------
# `systemctl is-active` prints the state AND exits non-zero when the unit is
# not active, so a bare `|| echo unknown` appends a second line. Capture the
# output and only fall back when it is empty.
victim_detail="$(
  remote "$VICTIM" "
    svc=\$(systemctl is-active httpd 2>/dev/null || true); [ -n \"\$svc\" ] || svc=unknown
    conns=\$(ss -Htn state established 'sport = :80' 2>/dev/null | wc -l)
    printf 'httpd=%s  established-80=%s' \"\$svc\" \"\$conns\"
  " 2>/dev/null || echo "httpd=?"
)"
report_row victim "$VICTIM" "$victim_detail"

# --- attackers --------------------------------------------------------------
index=0
for ip in "${ATTACKERS[@]}"; do
  index=$((index + 1))
  attacker_detail="$(
    remote "$ip" "
      attack=\$(systemctl is-active lab-slowloris 2>/dev/null || true); [ -n \"\$attack\" ] || attack=unknown
      conns=\$(ss -Htn state established 'dport = :80' 2>/dev/null | wc -l)
      printf 'slowloris=%s  established-80=%s' \"\$attack\" \"\$conns\"
    " 2>/dev/null || echo "slowloris=?"
  )"
  report_row "attacker-$index" "$ip" "$attacker_detail"
done

# --- observer ---------------------------------------------------------------
if [ -n "${OBSERVER:-}" ]; then
  # docker needs sudo here unless ec2-user is in the docker group.
  observer_detail="$(
    remote "$OBSERVER" "
      running=\$(sudo docker ps --format '{{.Names}}' 2>/dev/null | sort | tr '\n' ',' | sed 's/,\$//')
      printf 'containers=%s' \"\$running\"
    " 2>/dev/null || echo "docker=?"
  )"
  report_row observer "$OBSERVER" "$observer_detail"
fi

printf '\n'
if [ -n "${OBSERVER:-}" ]; then
  printf 'Grafana    : http://%s:3000/\n' "$OBSERVER"
  printf 'Prometheus : http://%s:9090/\n' "$OBSERVER"
else
  printf 'Observer   : not deployed (docker compose -f monitoring/docker-compose.yml up -d)\n'
fi
printf 'Victim site: http://%s/\n' "$VICTIM"
printf '\n'

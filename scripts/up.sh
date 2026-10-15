#!/usr/bin/env bash
# =============================================================================
#  Bring the lab up.
#
#      ./scripts/up.sh                 # interactive plan/apply
#      ./scripts/up.sh -auto-approve   # no prompts (good for a rehearsal)
#
#  After apply it waits for every node to finish cloud-init, which is when the
#  site, exporters and Grafana are actually usable.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_jq
require_ssh

detect_tofu

log "initialising $TOFU_BIN"
tf init -input=false

log "applying infrastructure"
tf apply "$@"

echo >&2

VICTIM="$(victim_ip)"
mapfile -t ATTACKERS < <(attacker_ips)
OBSERVER="$(observer_ip)"

NODES=("$VICTIM" "${ATTACKERS[@]}")
if [ -n "${OBSERVER:-}" ]; then
  NODES+=("$OBSERVER")
fi

log "waiting for SSH on ${#NODES[@]} node(s)"
for ip in "${NODES[@]}"; do
  if wait_for_ssh "$ip"; then
    ok "ssh   $ip"
  else
    warn "ssh   $ip  (timed out)"
  fi
done

log "waiting for cloud-init to finish (this can take a few minutes)"
for ip in "${NODES[@]}"; do
  if wait_for_cloud_init "$ip"; then
    ok "ready $ip"
  else
    warn "ready $ip  (still bootstrapping -- check /var/log/lab-init.log)"
  fi
done

log "smoke-testing the victim's website"
for attempt in $(seq 1 12); do
  if curl -fsS -m 5 -o /dev/null "http://$VICTIM/"; then
    ok "http://$VICTIM/ is serving"
    break
  fi
  sleep 5
  if [ "$attempt" -eq 12 ]; then
    warn "the victim site is not answering yet"
  fi
done

if [ -n "${OBSERVER:-}" ]; then
  log "smoke-testing Grafana"
  for attempt in $(seq 1 24); do
    if curl -fsS -m 5 -o /dev/null "http://$OBSERVER:3000/api/health"; then
      ok "http://$OBSERVER:3000/ is serving"
      break
    fi
    sleep 5
    if [ "$attempt" -eq 24 ]; then
      warn "Grafana is not answering yet -- give it another minute"
    fi
  done
fi

echo >&2
tf_raw summary >&2

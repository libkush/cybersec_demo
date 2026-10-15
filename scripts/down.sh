#!/usr/bin/env bash
# =============================================================================
#  Tear the entire lab down.
#
#      ./scripts/down.sh                # asks for confirmation
#      LAB_ASSUME_YES=1 ./scripts/down.sh   # no prompt
#
#  This destroys everything: the VPC, all EC2 instances, the security groups and
#  the S3 asset bucket (force_destroy is on, so its objects go too).
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

detect_tofu

log "about to destroy the following:"
step "the dedicated lab VPC and its subnet, IGW and route table"
step "the victim, every attacker, and the observer instance"
step "the S3 asset bucket and everything inside it"
step "the generated SSH key pair in AWS (the local .pem is left on disk)"
echo >&2

if ! confirm "Destroy the lab?"; then
  log "aborted -- nothing was destroyed"
  exit 0
fi

tf destroy "$@"

echo >&2
ok "lab destroyed"

if [ -n "${LAB_KEEP_KEY:-}" ]; then
  log "keeping the local private key at $(key_path 2>/dev/null || echo 'generated/')"
fi

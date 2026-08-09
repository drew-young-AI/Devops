#!/usr/bin/env bash
# Check whether a Vault KV v2 secret is overdue for rotation, based on the
# `rotated_at` custom_metadata field written by rotate_secret.sh (or set
# manually for secrets migrated but not yet rotated by this tooling).
#
# Rotation interval defaults to 90 days, matching
# platform/iac/variables.tf's secret_rotation_interval_days default -- this
# script and the IaC contract intentionally agree on the same number so
# "what does rotation policy actually require" has one source of truth,
# not two that can silently drift apart.
#
# Usage:
#   check_rotation_due.sh <path> [interval_days]
#
# Exit code: 0 if not due, 1 if due or overdue, 2 if no rotation record exists.

set -euo pipefail

SECRET_PATH="${1:?Usage: check_rotation_due.sh <path> [interval_days]}"
INTERVAL_DAYS="${2:-90}"
CONTAINER="vault-vault-1"

if [ -z "${VAULT_TOKEN:-}" ]; then
  echo "VAULT_TOKEN not set." >&2
  exit 1
fi

ROTATED_AT="$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$CONTAINER" \
  vault kv metadata get -format=json "secret/$SECRET_PATH" 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['custom_metadata'].get('rotated_at', ''))" 2>/dev/null || echo "")"

if [ -z "$ROTATED_AT" ]; then
  echo "secret/$SECRET_PATH: no rotation record (rotated_at custom_metadata not set)."
  echo "Either never rotated via rotate_secret.sh, or migrated directly without recording it."
  exit 2
fi

DAYS_SINCE="$(python3 -c "
import datetime
rotated = datetime.datetime.strptime('$ROTATED_AT', '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
now = datetime.datetime.now(datetime.timezone.utc)
print((now - rotated).days)
")"

echo "secret/$SECRET_PATH: last rotated $ROTATED_AT ($DAYS_SINCE days ago, policy: every $INTERVAL_DAYS days)"

if [ "$DAYS_SINCE" -ge "$INTERVAL_DAYS" ]; then
  echo "ROTATION DUE"
  exit 1
else
  echo "OK: $(( INTERVAL_DAYS - DAYS_SINCE )) days remaining"
  exit 0
fi

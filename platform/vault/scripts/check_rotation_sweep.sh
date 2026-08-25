#!/usr/bin/env bash
# Scheduled rotation check: sweep EVERY KV v2 secret, not one hardcoded path.
#
# Replaces the scheduler's use of check_rotation_due.sh, which takes a single
# <path> and was being invoked with none -- red since it was added, failing
# with a usage error, and a usage error that never once said "your secrets
# might be overdue". A rotation policy that only ever checked one path would
# also have been a rotation policy with a blind spot the size of the tree.
#
# WHY IT AUTHENTICATES WITH AN APPROLE AND NOT A ROOT TOKEN.
#
# launchd hands a process almost no environment, so VAULT_TOKEN is never set
# for a scheduled run. The tempting fix -- park a privileged token on disk --
# would put a secret-reading credential in a file so a REPORT can run. Instead
# this uses an AppRole bound to platform/vault/policies/rotation-check.hcl,
# which grants metadata only. See that file for what it can and cannot do.
#
# EXIT CODES, AND WHY 78 IS NOT 1.
#
#   0   every secret has a rotated_at, all within the interval
#   1   at least one secret is due/overdue, or has NO rotation record
#   78  not-configured: no AppRole credentials on disk (EX_CONFIG)
#
# 78 is the platform's existing convention for "this check is not running and
# is not pretending to" -- run_job.sh:180 maps it to `not-configured`, which
# the board shows yellow. It is deliberately NOT 0: a rotation check that
# cannot reach Vault has verified nothing, and green would say otherwise.
# It is deliberately NOT 1 either: nothing is overdue as far as anyone knows,
# and paging someone for an unconfigured check is how alerts get ignored.
#
# Usage:
#   check_rotation_sweep.sh [interval_days]     # default 90
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CONTAINER="vault-vault-1"
CREDS="$REPO_ROOT/platform/vault/.rotation-check-approle.json"
# Default matches platform/iac/variables.tf's secret_rotation_interval_days,
# the same single-source-of-truth argument check_rotation_due.sh makes.
INTERVAL_DAYS="${1:-90}"

echo "=== [rotation] sweep, interval ${INTERVAL_DAYS}d ==="

if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
  echo "  Vault container '$CONTAINER' is not running." >&2
  echo "  Start it: docker compose -f platform/vault/compose.yaml up -d" >&2
  exit 78
fi

if [ ! -f "$CREDS" ]; then
  echo "  not-configured: no rotation-check AppRole on disk."
  echo "  This check is NOT running and is not claiming otherwise."
  echo "  Enable it (one command, needs the root token already on this host):"
  echo "    platform/vault/scripts/setup_rotation_check.sh"
  exit 78
fi

ROLE_ID="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['role_id'])" "$CREDS" 2>/dev/null)"
SECRET_ID="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['secret_id'])" "$CREDS" 2>/dev/null)"
if [ -z "$ROLE_ID" ] || [ -z "$SECRET_ID" ]; then
  echo "  $CREDS exists but does not contain role_id/secret_id." >&2
  exit 78
fi

TOKEN="$(docker exec "$CONTAINER" vault write -field=token auth/approle/login \
           role_id="$ROLE_ID" secret_id="$SECRET_ID" </dev/null 2>/dev/null)"
if [ -z "$TOKEN" ]; then
  # A stored secret_id that Vault rejects is a REAL failure, not a missing
  # configuration: something revoked it, or Vault was rebuilt underneath it.
  # Reporting 78 here would turn a broken credential into a yellow "not set
  # up yet" and nobody would look.
  echo "  AppRole login FAILED with the stored credentials." >&2
  echo "  Re-issue them: platform/vault/scripts/setup_rotation_check.sh" >&2
  exit 1
fi

vt() { docker exec -e VAULT_TOKEN="$TOKEN" "$CONTAINER" vault "$@" </dev/null; }

# Walk the KV v2 tree. `vault kv list` is per-level: entries ending in `/` are
# folders, everything else is a secret. A single top-level list would miss
# every nested secret, which on this platform is most of them
# (secret/devops/ghcr, secret/dataops/..., and so on).
declare -a QUEUE=("")
declare -a SECRETS=()
while [ "${#QUEUE[@]}" -gt 0 ]; do
  prefix="${QUEUE[0]}"; QUEUE=("${QUEUE[@]:1}")
  listing="$(vt kv list -format=json "secret/$prefix" 2>/dev/null)" || continue
  [ -z "$listing" ] && continue
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    case "$entry" in
      */) QUEUE+=("$prefix$entry") ;;
      *)  SECRETS+=("$prefix$entry") ;;
    esac
  done < <(printf '%s' "$listing" | python3 -c "
import json,sys
try: print('\n'.join(json.load(sys.stdin)))
except Exception: pass
")
done

if [ "${#SECRETS[@]}" -eq 0 ]; then
  # An empty tree is not a pass. Either there really are no secrets (in which
  # case rotation policy is vacuous and should say so out loud), or the
  # listing grant is broken and this would otherwise report a cheerful green.
  echo "  No secrets found under secret/. Either the KV mount is empty, or the"
  echo "  rotation-check policy lost its list grant. Not reporting a pass on"
  echo "  an empty sweep." >&2
  exit 1
fi

NOW="$(date -u +%s)"
LIMIT=$(( INTERVAL_DAYS * 86400 ))
due=0; unrecorded=0; ok=0

for path in "${SECRETS[@]}"; do
  meta="$(vt kv metadata get -format=json "secret/$path" 2>/dev/null)"
  rotated="$(printf '%s' "$meta" | python3 -c "
import json,sys
try:
    cm = json.load(sys.stdin)['data'].get('custom_metadata') or {}
    print(cm.get('rotated_at',''))
except Exception:
    print('')
" 2>/dev/null)"
  if [ -z "$rotated" ]; then
    echo "  NO RECORD  secret/$path  (never rotated by this tooling)"
    unrecorded=$(( unrecorded + 1 ))
    continue
  fi
  then_ts="$(python3 -c "
import datetime,sys
s = sys.argv[1].replace('Z','+00:00')
try: print(int(datetime.datetime.fromisoformat(s).timestamp()))
except Exception: print('')
" "$rotated" 2>/dev/null)"
  if [ -z "$then_ts" ]; then
    echo "  UNPARSEABLE secret/$path  rotated_at='$rotated'"
    unrecorded=$(( unrecorded + 1 ))
    continue
  fi
  age_days=$(( (NOW - then_ts) / 86400 ))
  if [ "$(( NOW - then_ts ))" -ge "$LIMIT" ]; then
    echo "  DUE        secret/$path  ${age_days}d old (limit ${INTERVAL_DAYS}d)"
    due=$(( due + 1 ))
  else
    echo "  ok         secret/$path  ${age_days}d old"
    ok=$(( ok + 1 ))
  fi
done

echo ""
echo "  ${#SECRETS[@]} secret(s): $ok within interval, $due due, $unrecorded without a record"
if [ "$due" -gt 0 ] || [ "$unrecorded" -gt 0 ]; then
  echo "  Rotate with: platform/vault/scripts/rotate_secret.sh <path>" >&2
  exit 1
fi
echo "  ROTATION PASS -- every secret has a record and is within ${INTERVAL_DAYS}d"
exit 0

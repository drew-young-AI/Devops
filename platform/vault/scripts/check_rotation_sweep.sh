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
#   2   VACUOUS: every secret is exempt, so the sweep checked nothing
#   78  not-configured: no AppRole credentials on disk (EX_CONFIG)
#
# WHY 2 EXISTS (2026-09-01).
#
# This script already guarded one shape of emptiness -- zero secrets under
# secret/ -- with the comment "An empty tree is not a pass". Then the platform
# drifted into the OTHER shape and walked straight past the guard:
#
#   3 secret(s): 0 within interval, 0 due, 0 without a record, 3 exempt
#   ROTATION PASS -- every non-exempt secret has a record and is within its
#                    own interval
#
# Every one of the three was exempt, so "every non-exempt secret is within its
# interval" was quantifying over the empty set and is trivially true. The line
# read as a rotation policy being met. It was a rotation policy that had
# checked nothing, reported by a script whose author had already thought about
# vacuous passes and guarded the case that did not happen.
#
# That is worth stating plainly because it is the general lesson: a vacuity
# guard is written against the emptiness you imagined. The set can go empty
# some other way.
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
due=0; unrecorded=0; ok=0; exempt=0

for path in "${SECRETS[@]}"; do
  meta="$(vt kv metadata get -format=json "secret/$path" 2>/dev/null)"
  # Two fields, read in one pass: when it was last rotated, and what interval
  # THIS secret is held to. The interval is per-secret data (see
  # set_rotation_policy.sh for why one global number was wrong), so the
  # argument to this script is only the DEFAULT for secrets that have not
  # been given one.
  # The reason is read LAST and with `read -r a b rest`, so it keeps its own
  # spaces. The first version space-encoded it as underscores and decoded with
  # ${var//_/ }, which also ate the underscores that belonged to the text --
  # "rotation_drill.sh" came out as "rotation drill.sh". An encoding that is
  # not reversible is not an encoding.
  read -r rotated secret_interval exempt_reason <<<"$(printf '%s' "$meta" | python3 -c "
import json,sys
try:
    cm = json.load(sys.stdin)['data'].get('custom_metadata') or {}
except Exception:
    cm = {}
print(cm.get('rotated_at','-'),
      cm.get('rotation_interval_days','-'),
      (cm.get('rotation_exempt_reason','') or '').replace(chr(10), ' '))
" 2>/dev/null)"
  [ "$rotated" = "-" ] && rotated=""
  # An exempt secret is a DECISION that was recorded, so it is reported as its
  # own outcome rather than folded into the pass count -- "3 ok" must not mean
  # "2 rotated and 1 we agreed to stop checking".
  if [ "$secret_interval" = "0" ]; then
    echo "  EXEMPT     secret/$path  ($exempt_reason)"
    exempt=$(( exempt + 1 ))
    continue
  fi
  case "$secret_interval" in
    ''|*[!0-9]*) effective="$INTERVAL_DAYS"; source_note="default" ;;
    *)           effective="$secret_interval"; source_note="per-secret" ;;
  esac
  LIMIT=$(( effective * 86400 ))
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
    echo "  DUE        secret/$path  ${age_days}d old (limit ${effective}d, $source_note)"
    due=$(( due + 1 ))
  else
    echo "  ok         secret/$path  ${age_days}d old (limit ${effective}d, $source_note)"
    ok=$(( ok + 1 ))
  fi
done

echo ""
echo "  ${#SECRETS[@]} secret(s): $ok within interval, $due due, $unrecorded without a record, $exempt exempt"
if [ "$due" -gt 0 ] || [ "$unrecorded" -gt 0 ]; then
  echo "  Rotate:  platform/vault/scripts/rotate_secret.sh <path> <field>" >&2
  echo "  Or set this secret's own interval / record an exemption:" >&2
  echo "           platform/vault/scripts/set_rotation_policy.sh <path> <days> [reason]" >&2
  exit 1
fi
if [ "$exempt" -eq "${#SECRETS[@]}" ]; then
  # Not a pass, and deliberately not a failure either. Nothing is overdue --
  # there is simply no secret this sweep is holding to any interval, and that
  # is a state somebody chose and can un-choose. Paging for it would be wrong;
  # printing PASS would be a lie.
  echo "  ROTATION VACUOUS -- all ${#SECRETS[@]} secret(s) are exempt, so this sweep verified nothing." >&2
  echo "  'Every non-exempt secret is within its interval' is true over an empty set." >&2
  echo "  Give at least one secret a real interval to make this check mean something:" >&2
  echo "           platform/vault/scripts/set_rotation_policy.sh <path> <days>" >&2
  echo "  The mechanism itself is proven separately and is not what is missing here:" >&2
  echo "           platform/vault/scripts/rotation_drill.sh" >&2
  exit 2
fi
echo "  ROTATION PASS -- every non-exempt secret has a record and is within its own interval"
echo "  (checked $(( ${#SECRETS[@]} - exempt )) of ${#SECRETS[@]} secret(s); $exempt exempt)"
exit 0

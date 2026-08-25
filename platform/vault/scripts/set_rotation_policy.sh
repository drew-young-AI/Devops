#!/usr/bin/env bash
# Set ONE secret's rotation interval, or record that it is exempt.
#
# WHY THE INTERVAL IS DATA AND NOT A CONSTANT.
#
# It used to be 90, hardcoded in check_rotation_due.sh and again in
# platform/iac/main.tf, with a comment in the first calling the second its
# "single source of truth". That claim was already false when it was written:
# main.tf carries TWO different numbers (secret_rotation_interval_days = 90 and
# token_rotation_interval_days = 30), inside a null_resource with
# `lifecycle { ignore_changes = all }`. It enforces nothing and nothing reads
# it. Two numbers, neither of them wired to anything, described as one source
# of truth.
#
# One global number is also wrong on the merits. A classic PAT with
# write:packages is long-lived, broadly scoped and usable from anywhere; a
# Grafana admin password is read by one local setup script on the loopback.
# Holding both to 90 days means the number is either too slack for the first or
# pointless busywork for the second. So the interval lives WITH the secret, in
# custom_metadata, next to rotated_at.
#
# EXEMPTION IS A RECORDED DECISION, NOT A MISSING ROW.
#
# `<days> = 0` marks a secret exempt and REQUIRES a reason. The alternative --
# quietly dropping it from the sweep, or stamping a fake rotated_at to turn the
# board green -- writes down a claim nobody verified. An exemption with a reason
# is auditable; a green light with no rotation behind it is not.
#
# Usage:
#   set_rotation_policy.sh <path> <days>
#   set_rotation_policy.sh <path> 0 "<why it is exempt>"
#
# Example:
#   set_rotation_policy.sh devops/ghcr 30
#   set_rotation_policy.sh devops/grafana-admin 0 "local loopback only; \
#                                                  rotated by re-running setup"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONTAINER="vault-vault-1"
INIT_FILE="$REPO_ROOT/platform/vault/.init-output.json"

SECRET_PATH="${1:?Usage: set_rotation_policy.sh <path> <days> [reason-if-0]}"
DAYS="${2:?Usage: set_rotation_policy.sh <path> <days> [reason-if-0]}"
REASON="${3:-}"

case "$DAYS" in
  ''|*[!0-9]*) echo "days must be a non-negative integer, got '$DAYS'." >&2; exit 1 ;;
esac
if [ "$DAYS" = "0" ] && [ -z "$REASON" ]; then
  echo "Exempting a secret (days=0) requires a reason." >&2
  echo "  set_rotation_policy.sh $SECRET_PATH 0 \"why this is exempt\"" >&2
  exit 1
fi

[ -f "$INIT_FILE" ] || { echo "No $INIT_FILE." >&2; exit 1; }
docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true \
  || { echo "Vault container '$CONTAINER' is not running." >&2; exit 1; }

VAULT_TOKEN="$(python3 -c "import json;print(json.load(open('$INIT_FILE'))['root_token'])")"
v() { docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$CONTAINER" vault "$@" </dev/null; }

v kv metadata get "secret/$SECRET_PATH" >/dev/null 2>&1 \
  || { echo "secret/$SECRET_PATH does not exist." >&2; exit 1; }

# Merge, never replace -- same reason as rotate_secret.sh: -custom-metadata
# rewrites the whole map, so a partial write silently drops rotated_at.
EXISTING="$(v kv metadata get -format=json "secret/$SECRET_PATH" 2>/dev/null || echo '{}')"
# bash 3.2 (what macOS ships, and what `#!/usr/bin/env bash` resolves to here)
# has no `mapfile`. The first version used it and the whole script exited 127 --
# caught by the self-test, not by reading it.
META_ARGS=()
while IFS= read -r _arg; do
  [ -n "$_arg" ] && META_ARGS+=("$_arg")
done < <(printf '%s' "$EXISTING" | python3 -c "
import json, sys
try:
    cm = json.load(sys.stdin)['data'].get('custom_metadata') or {}
except Exception:
    cm = {}
days, reason = sys.argv[1], sys.argv[2]
cm['rotation_interval_days'] = days
if days == '0':
    cm['rotation_exempt_reason'] = reason
else:
    cm.pop('rotation_exempt_reason', None)
for k, val in cm.items():
    print(f'-custom-metadata={k}={val}')
" "$DAYS" "$REASON")

v kv metadata put "${META_ARGS[@]}" "secret/$SECRET_PATH" >/dev/null

# Read back and assert, rather than trusting that the write took. Vault will
# accept a metadata put that drops keys, and this script's whole purpose is to
# not drop keys.
READ_BACK="$(v kv metadata get -format=json "secret/$SECRET_PATH" 2>/dev/null | python3 -c "
import json,sys
cm = json.load(sys.stdin)['data'].get('custom_metadata') or {}
print(json.dumps(cm, sort_keys=True))
")"
echo "  secret/$SECRET_PATH custom_metadata now: $READ_BACK"
printf '%s' "$READ_BACK" | grep -q "\"rotation_interval_days\": \"$DAYS\"" \
  || { echo "FAIL: the interval did not persist." >&2; exit 1; }
if [ "$DAYS" = "0" ]; then
  echo "  EXEMPT, reason recorded. The sweep will report it as exempt, not due."
else
  echo "  interval set to ${DAYS}d. The sweep judges this secret against that,"
  echo "  not against the global default."
fi

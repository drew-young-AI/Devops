#!/usr/bin/env bash
# Rotation drill: prove a credential can actually be replaced, end to end.
#
# The same argument restore_drill.sh makes about backups. A rotation policy
# that has never rotated anything is a policy, not a capability -- and the
# moment you need it (a leak) is the worst possible time to discover the
# mechanism does not work.
#
# WHAT MAKES THIS A PROOF RATHER THAN A CEREMONY.
#
# Three assertions, and the third is the one that matters:
#
#   1. the OLD credential works before the rotation   (there was something to
#                                                      rotate; a drill against
#                                                      an already-broken
#                                                      credential proves nothing)
#   2. the NEW credential works after it              (the service actually took it)
#   3. the OLD credential is REFUSED after it         (it really was replaced)
#
# Without 3 this "passes" when the write silently did nothing -- which is the
# exact shape of the GRANT-is-a-snapshot and placeholder-collision bugs this
# platform has already been bitten by twice.
#
# TARGET: grafana-admin, deliberately.
#
# It is the only credential here whose consumer is entirely local, whose
# rotation is scriptable end to end, and whose failure locks nobody out of
# anything external. The GitHub credentials cannot be drilled this way: minting
# a replacement needs github.com, and revoking the old one breaks `git push`
# from the macOS keychain, which Vault does not control. See docs/Backlog.md 11.
#
# ROLLBACK: on any failure the previous KV version is restored and the live
# password reset from it, then the drill exits non-zero. KV v2 keeps versions;
# this script never destroys one.
#
# Usage:
#   platform/vault/scripts/rotation_drill.sh            # rotate and verify
#   platform/vault/scripts/rotation_drill.sh --check    # verify current only
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VAULT_CONTAINER="vault-vault-1"
GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:13000}"
SECRET_PATH="secret/devops/grafana-admin"
INIT_FILE="$REPO_ROOT/platform/vault/.init-output.json"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && echo "       $2"; }

[ -f "$INIT_FILE" ] || { echo "No $INIT_FILE." >&2; exit 1; }
docker inspect -f '{{.State.Running}}' "$VAULT_CONTAINER" 2>/dev/null | grep -q true \
  || { echo "Vault is not running." >&2; exit 1; }

VAULT_TOKEN="$(python3 -c "import json;print(json.load(open('$INIT_FILE'))['root_token'])")"
export VAULT_TOKEN
v() { docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT_CONTAINER" vault "$@" </dev/null; }

# Credentials are held in shell variables and never printed, never passed as a
# command-line argument (which would put them in `ps`), and never written to a
# file by this script. Same discipline as rotate_secret.sh.
# Three outcomes, not two, and the third is why this drill nearly reported a
# false PASS.
#
# Grafana blocks a user after several consecutive failed logins. Assertion 3
# below DELIBERATELY submits a wrong password, so the drill trips that lock on
# itself -- and a locked account also answers 401. Reading only the status code,
# "the old credential is refused" would have passed because the account was
# blocked, not because the password had changed. That is the assertion the whole
# drill exists for, passing for the wrong reason.
#
# Observed, not theorised: repeated runs produced
#   "too many consecutive incorrect login attempts for user - login for user
#    temporarily blocked"
# while the correct password also returned 401.
#
# Echoes: works | rejected | blocked | error:<code>
grafana_login() {
  local user="$1" pass="$2" body code
  body="$(curl -s -w '\n%{http_code}' --max-time 10 \
          -u "$user:$pass" "$GRAFANA_URL/api/user" 2>/dev/null)"
  code="${body##*$'\n'}"
  case "$code" in
    200) echo works ;;
    401) case "$body" in
           *"temporarily blocked"*) echo blocked ;;
           *)                       echo rejected ;;
         esac ;;
    *)   echo "error:$code" ;;
  esac
}

# Grafana's lockout is time-based. Waiting it out is the only honest way to get
# a verdict: forcing the account unlocked would be testing a system that is not
# the one running.
wait_for_unblock() {
  local user="$1" pass="$2" waited=0
  while [ "$(grafana_login "$user" "$pass")" = "blocked" ] && [ "$waited" -lt 360 ]; do
    [ "$waited" -eq 0 ] && echo "  (account is rate-limited; waiting for the lock to lapse)"
    sleep 20; waited=$((waited + 20))
  done
}

echo "=== [rotation drill] $SECRET_PATH ==="

USER_NAME="$(v kv get -field=username "$SECRET_PATH" 2>/dev/null)"
OLD_PASS="$(v kv get -field=password "$SECRET_PATH" 2>/dev/null)"
OLD_VERSION="$(v kv metadata get -format=json "$SECRET_PATH" 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['current_version'])" 2>/dev/null)"
[ -n "$USER_NAME" ] && [ -n "$OLD_PASS" ] || { echo "Could not read $SECRET_PATH." >&2; exit 1; }

echo ""
echo "--- 1. is there a working credential to rotate? ---"
wait_for_unblock "$USER_NAME" "$OLD_PASS"
if [ "$(grafana_login "$USER_NAME" "$OLD_PASS")" = "works" ]; then
  ok "current credential authenticates to Grafana (v$OLD_VERSION)"
else
  bad "current credential does NOT authenticate" \
      "Vault and Grafana are already out of sync. Fix that before drilling: \
platform/observability/scripts/setup_grafana_identity.sh"
  echo ""; echo "  $PASS passed, $FAIL failed"; exit 1
fi

if [ "${1:-}" = "--check" ]; then
  echo ""; echo "  $PASS passed, $FAIL failed  (--check: nothing was rotated)"
  exit 0
fi

restore() {
  echo ""
  echo "--- rollback ---"
  # `kv rollback` writes the old value as a NEW version rather than deleting
  # the bad one. The history stays intact, which is the whole reason KV v2
  # versioning is being relied on here instead of a backup file.
  v kv rollback -version="$OLD_VERSION" "$SECRET_PATH" >/dev/null 2>&1 \
    && echo "  Vault rolled back to v$OLD_VERSION" \
    || echo "  ROLLBACK FAILED -- $SECRET_PATH may be inconsistent" >&2
  bash "$REPO_ROOT/platform/observability/scripts/setup_grafana_identity.sh" >/dev/null 2>&1 \
    && echo "  live Grafana password reset from Vault" \
    || echo "  could not reset the live Grafana password" >&2
}

echo ""
echo "--- 2. rotate ---"
NEW_PASS="$(python3 -c "import secrets; print(secrets.token_urlsafe(24))")"
if printf '%s' "$NEW_PASS" | bash "$SCRIPT_DIR/rotate_secret.sh" \
     "devops/grafana-admin" "password" >/dev/null 2>&1; then
  ok "new version written to Vault"
else
  bad "rotate_secret.sh failed"; restore
  echo ""; echo "  $PASS passed, $FAIL failed"; exit 1
fi

# Vault is the source of truth; Grafana has to be told. This is the step that
# makes rotation real rather than bookkeeping -- writing a new value into Vault
# while the service keeps accepting the old one is not a rotation.
# Output captured rather than discarded: the first version sent it to
# /dev/null and the drill reported "setup_grafana_identity.sh failed" with no
# way to see why. A drill that cannot tell you what broke is a drill you will
# stop running.
DELIVERY_LOG="$(mktemp)"
trap 'rm -f "$DELIVERY_LOG"' EXIT
if bash "$REPO_ROOT/platform/observability/scripts/setup_grafana_identity.sh" \
     >"$DELIVERY_LOG" 2>&1; then
  ok "credential delivered to Grafana"
else
  bad "setup_grafana_identity.sh failed" "$(tail -4 "$DELIVERY_LOG" | tr '\n' ' ')"; restore
  echo ""; echo "  $PASS passed, $FAIL failed"; exit 1
fi

echo ""
echo "--- 3. did it actually take? ---"
wait_for_unblock "$USER_NAME" "$NEW_PASS"
if [ "$(grafana_login "$USER_NAME" "$NEW_PASS")" = "works" ]; then
  ok "NEW credential authenticates"
else
  bad "new credential does NOT authenticate" "the rotation did not reach Grafana"
  restore; echo ""; echo "  $PASS passed, $FAIL failed"; exit 1
fi

# The assertion the whole drill exists for. Everything above passes just as
# happily when the write silently did nothing.
case "$(grafana_login "$USER_NAME" "$OLD_PASS")" in
  works)
    bad "OLD credential STILL authenticates" \
        "the old password was never replaced -- this is not a rotation"
    restore; echo ""; echo "  $PASS passed, $FAIL failed"; exit 1 ;;
  rejected)
    ok "OLD credential is refused (it really was replaced)" ;;
  blocked)
    # NOT a pass. A blocked account refuses every password, including the one
    # that would have proved the rotation did nothing.
    bad "cannot verify: Grafana rate-limited the account" \
        "the old credential was refused for the WRONG reason. Re-run in a few \
minutes; the new credential is already in place and working." ;;
  *)
    bad "cannot verify: unexpected response from Grafana" ;;
esac

NEW_VERSION="$(v kv metadata get -format=json "$SECRET_PATH" 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['current_version'])" 2>/dev/null)"
ROTATED_AT="$(v kv metadata get -format=json "$SECRET_PATH" 2>/dev/null \
  | python3 -c "import json,sys; print((json.load(sys.stdin)['data'].get('custom_metadata') or {}).get('rotated_at',''))" 2>/dev/null)"
echo ""
echo "  v$OLD_VERSION -> v$NEW_VERSION, rotated_at=$ROTATED_AT (values never printed)"
echo "  v$OLD_VERSION is NOT destroyed: vault kv get -version=$OLD_VERSION $SECRET_PATH"
echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

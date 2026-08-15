#!/usr/bin/env bash
# Boundary verification for the identity mechanism.
#
# A policy file is a claim. This script is the evidence. Every case below
# issues a REAL request with a REAL token minted through the REAL auth
# method, and asserts allowed/denied -- because the failure mode of an
# access-control policy is not an error, it is a silent success by the wrong
# subject.
#
# Deliberately a script, not a one-off manual session: an access model that
# was verified once, by hand, months ago, is an access model nobody can
# prove anything about today. Re-run this after any change to
# platform/vault/policies/*.hcl.
#
# Usage:
#   platform/vault/scripts/verify_identity.sh
#
# Exit 0 if every boundary behaves as specified. Creates and destroys its
# own throwaway secrets; touches no real credential. Prints no secret value.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTAINER="${VAULT_CONTAINER:-vault-vault-1}"

PASSED=0
FAILED=0

if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(python3 -c "
import json
print(json.load(open('$VAULT_DIR/.init-output.json'))['root_token'])
")"
fi

v() {
  # </dev/null is load-bearing. `docker exec -i` attaches the caller's
  # stdin, so any vault subcommand that reads stdin (`policy write -`,
  # `kv put field=-`) blocks forever, and any call inside a `while read`
  # loop silently eats the loop's input instead. Both have already
  # happened in this repo -- see platform/tests/test_static.sh, which
  # now fails the build if a `docker exec -i` appears unguarded.
  docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" -e VAULT_ADDR=http://127.0.0.1:8200 \
    "$CONTAINER" vault "$@" </dev/null
}

# Runs a vault command AS the given token, never as admin.
as() {
  local token="$1"; shift
  # `policy write evil -` in the checks below reads stdin by design; without
  # this redirect the whole suite hung for seven minutes on that one line,
  # with no output and no timeout. Empty stdin is exactly right here: the
  # request still goes out and still gets its 403.
  docker exec -i -e VAULT_TOKEN="$token" -e VAULT_ADDR=http://127.0.0.1:8200 \
    "$CONTAINER" vault "$@" 2>&1 </dev/null
}

check() {
  local expect="$1" desc="$2"; shift 2
  local out rc
  out="$("$@")"
  rc=$?
  local denied=0
  if [ $rc -ne 0 ] && echo "$out" | grep -qiE "permission denied|403"; then
    denied=1
  fi
  if { [ "$expect" = "allow" ] && [ $rc -eq 0 ]; } || { [ "$expect" = "deny" ] && [ $denied -eq 1 ]; }; then
    PASSED=$((PASSED + 1))
    printf '  \033[32mPASS\033[0m [%s] %s\n' "$expect" "$desc"
  else
    FAILED=$((FAILED + 1))
    printf '  \033[31mFAIL\033[0m [%s] %s\n' "$expect" "$desc"
    printf '       rc=%s out=%s\n' "$rc" "$(echo "$out" | head -1)"
  fi
}

echo "=== seeding throwaway secrets ==="
v kv put secret/pilots/station1-hello/test-placeholder value=throwaway >/dev/null
v kv put secret/pilots/other-pilot/test-placeholder value=throwaway >/dev/null
echo "  seeded (deleted at the end of this script)"

# --- workload identity: AppRole login actually works -------------------

echo ""
echo "=== workload identity (approle) ==="

approle_token() {
  local role="$1"
  local role_id secret_id
  role_id="$(v read -field=role_id "auth/approle/role/$role/role-id")"
  secret_id="$(v write -f -field=secret_id "auth/approle/role/$role/secret-id")"
  v write -field=token auth/approle/login role_id="$role_id" secret_id="$secret_id"
}

S1_TOKEN="$(approle_token workload-station1-hello)"
if [ -n "$S1_TOKEN" ]; then
  PASSED=$((PASSED + 1)); printf '  \033[32mPASS\033[0m [allow] workload-station1-hello can log in via approle\n'
else
  FAILED=$((FAILED + 1)); printf '  \033[31mFAIL\033[0m [allow] workload-station1-hello approle login\n'
fi

check allow "station1 workload reads its own secret" \
  as "$S1_TOKEN" kv get secret/pilots/station1-hello/test-placeholder
check deny "station1 workload CANNOT read another pilot's secret" \
  as "$S1_TOKEN" kv get secret/pilots/other-pilot/test-placeholder
check deny "station1 workload CANNOT read devops secrets" \
  as "$S1_TOKEN" kv get secret/devops/github
check deny "station1 workload CANNOT write policies" \
  as "$S1_TOKEN" policy list

# A workload token must be short-lived even while the credential it reads is
# static. This is the half of "short-lived" that is available today, without
# waiting for dynamic secrets.
TTL="$(as "$S1_TOKEN" token lookup -format=json | python3 -c "
import json,sys
try: print(json.load(sys.stdin)['data']['ttl'])
except Exception: print(-1)
")"
if [ "$TTL" -gt 0 ] && [ "$TTL" -le 1200 ]; then
  PASSED=$((PASSED + 1)); printf '  \033[32mPASS\033[0m [allow] workload token TTL is short (%ss <= 1200s)\n' "$TTL"
else
  FAILED=$((FAILED + 1)); printf '  \033[31mFAIL\033[0m workload token TTL unexpected: %s\n' "$TTL"
fi

# --- credential separation is enforced, not just conventional ----------

echo ""
echo "=== ci-pipeline: narrowest possible workload ==="
CI_TOKEN="$(approle_token ci-pipeline)"
check allow "CI reads the GHCR push credential" \
  as "$CI_TOKEN" kv get secret/devops/ghcr
# This is why the two GitHub credentials live at separate paths: separate
# paths are what make separate grants possible.
check deny "CI CANNOT read the git PAT it has no business holding" \
  as "$CI_TOKEN" kv get secret/devops/github

# --- human RBAC ---------------------------------------------------------

echo ""
echo "=== human RBAC (userpass) ==="

userpass_token() {
  local user="$1" password="$2"
  v write -field=token "auth/userpass/login/$user" password="$password"
}

OPERATOR_PW="$(python3 -c "
import json
print(json.load(open('$VAULT_DIR/.identity-output.json'))['humans']['platform-operator'])
")"
VIEWER_PW="$(python3 -c "
import json
print(json.load(open('$VAULT_DIR/.identity-output.json'))['humans']['platform-viewer'])
")"

OP_TOKEN="$(userpass_token platform-operator "$OPERATOR_PW")"
check allow "operator reads a devops secret value" \
  as "$OP_TOKEN" kv get secret/devops/github
check deny "operator CANNOT create a policy (that would make them an admin)" \
  as "$OP_TOKEN" policy write evil -
check deny "operator CANNOT enable a new auth method" \
  as "$OP_TOKEN" auth enable github

VIEW_TOKEN="$(userpass_token platform-viewer "$VIEWER_PW")"
# The distinction this whole role exists to prove: KV v2 splits metadata and
# value into different API paths, so "can see it exists and when it was
# rotated" is genuinely separable from "can read it".
check allow "viewer reads secret METADATA (exists, versions, rotation dates)" \
  as "$VIEW_TOKEN" kv metadata get secret/devops/github
check deny "viewer CANNOT read the secret VALUE" \
  as "$VIEW_TOKEN" kv get secret/devops/github
check deny "viewer CANNOT read a pilot secret value either" \
  as "$VIEW_TOKEN" kv get secret/pilots/station1-hello/test-placeholder

# --- cleanup ------------------------------------------------------------

echo ""
echo "=== cleanup ==="
v kv metadata delete secret/pilots/station1-hello/test-placeholder >/dev/null 2>&1
v kv metadata delete secret/pilots/other-pilot/test-placeholder >/dev/null 2>&1
for t in "$S1_TOKEN" "$CI_TOKEN" "$OP_TOKEN" "$VIEW_TOKEN"; do
  [ -n "$t" ] && v token revoke "$t" >/dev/null 2>&1
done
echo "  throwaway secrets deleted, test tokens revoked"

echo ""
echo "  $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]

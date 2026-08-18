#!/usr/bin/env bash
# Prove the dynamic credentials are actually dynamic.
#
# The claim "credentials are short-lived and revocable" is worth nothing
# asserted. A credential that keeps working after revocation is a static
# credential with extra steps, and nothing in the configuration would say so:
# `vault read database/creds/...` returns a username and password either way.
#
# So this checks, in both directions:
#
#   issued        the credential Vault just minted can actually connect
#   distinct      two reads produce two DIFFERENT users, not one shared one
#   least-priv    it can read and insert, and CANNOT drop a table
#   revoked       after revocation the SAME credential is refused by postgres
#
# The last one is the whole point. Everything before it can pass on a system
# where "dynamic" is decorative.
#
# Usage: verify_database_secrets.sh <pilot> [db-host-port]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PILOT="${1:-station2-twin}"
DB_PORT="${2:-15432}"
DB_NAME="${DB_NAME:-twin}"
DB_CONTAINER="${DB_CONTAINER:-${PILOT}-db-1}"
VAULT_CONTAINER="${VAULT_CONTAINER:-vault-vault-1}"
INIT_FILE="$REPO_ROOT/platform/vault/.init-output.json"

ROOT_TOKEN="$(python3 -c "import json;print(json.load(open('$INIT_FILE'))['root_token'])" 2>/dev/null)"
[ -n "$ROOT_TOKEN" ] || { echo "No Vault root token." >&2; exit 1; }

v() { docker exec -e VAULT_TOKEN="$ROOT_TOKEN" "$VAULT_CONTAINER" vault "$@" </dev/null; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf "  \033[32mPASS\033[0m %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf "  \033[31mFAIL\033[0m %s\n       %s\n" "$1" "${2:-}"; }

# Connect AS the generated user, from inside the db container so the check
# does not depend on a client being installed on the host.
as_user() {
  local user="$1" pass="$2" sql="$3"
  docker exec -e PGPASSWORD="$pass" "$DB_CONTAINER" \
    psql -h 127.0.0.1 -U "$user" -d "$DB_NAME" -qtAX -v ON_ERROR_STOP=1 -c "$sql" </dev/null 2>&1
}

echo ""
CRED1="$(v read -format=json database/creds/"$PILOT" 2>/dev/null)"
if [ -z "$CRED1" ]; then
  echo "Could not read database/creds/$PILOT" >&2; exit 1
fi
U1="$(printf '%s' "$CRED1" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['username'])")"
P1="$(printf '%s' "$CRED1" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['password'])")"
L1="$(printf '%s' "$CRED1" | python3 -c "import json,sys;print(json.load(sys.stdin)['lease_id'])")"
TTL1="$(printf '%s' "$CRED1" | python3 -c "import json,sys;print(json.load(sys.stdin)['lease_duration'])")"

echo "  issued user: $U1   ttl: ${TTL1}s"
echo ""

# 1. It works.
OUT="$(as_user "$U1" "$P1" "SELECT COUNT(*) FROM surveillance_observations")"
if [ "$(echo "$OUT" | tr -d ' \n')" -gt 0 ] 2>/dev/null; then
  ok "issued credential connects and reads ($(echo "$OUT" | tr -d ' \n') rows)"
else
  bad "issued credential connects and reads" "$OUT"
fi

# 2. Per-workload, not shared. Two reads must not return the same user.
CRED2="$(v read -format=json database/creds/"$PILOT" 2>/dev/null)"
U2="$(printf '%s' "$CRED2" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['username'])")"
L2="$(printf '%s' "$CRED2" | python3 -c "import json,sys;print(json.load(sys.stdin)['lease_id'])")"
if [ -n "$U2" ] && [ "$U1" != "$U2" ]; then
  ok "each read mints a DISTINCT user ($U2)"
else
  bad "each read mints a distinct user" "both reads returned $U1"
fi

# 3. Least privilege. It must be able to insert, and must NOT be able to
#    drop. A credential that can drop the table it reads is not scoped.
INS="$(as_user "$U1" "$P1" "INSERT INTO observations (asset_id, metric, value) VALUES ('vault-probe','probe',1) RETURNING id")"
if [ -n "$INS" ] && ! echo "$INS" | grep -qi "denied\|error"; then
  ok "can INSERT (the privilege the application needs)"
else
  bad "can INSERT" "$INS"
fi

DROP="$(as_user "$U1" "$P1" "DROP TABLE surveillance_observations")"
if echo "$DROP" | grep -qi "must be owner\|denied\|permission"; then
  ok "CANNOT DROP TABLE -- least privilege holds"
else
  bad "CANNOT DROP TABLE" "drop was not refused: $DROP"
fi

DEL="$(as_user "$U1" "$P1" "DELETE FROM observations WHERE asset_id='vault-probe'")"
if echo "$DEL" | grep -qi "denied\|permission"; then
  ok "CANNOT DELETE -- not granted, so not available"
else
  # Not fatal, but it must be visible: the role was written without DELETE,
  # so this succeeding means the grant is wider than intended.
  bad "CANNOT DELETE" "delete was permitted; the grant is wider than the role definition"
fi

# 4. THE ONE THAT MATTERS. Revoke, then try the same credential again.
echo ""
echo "  revoking lease ${L1:0:40}..."
v lease revoke "$L1" >/dev/null 2>&1
sleep 3

AFTER="$(as_user "$U1" "$P1" "SELECT 1")"
if echo "$AFTER" | grep -qi "authentication failed\|does not exist\|role .* does not exist"; then
  ok "REVOKED credential is refused by postgres"
else
  bad "REVOKED credential is refused by postgres" \
      "it still works -- 'dynamic' would be decorative: $AFTER"
fi

# Clean up the second lease so the drill leaves nothing behind.
v lease revoke "$L2" >/dev/null 2>&1
docker exec -e PGPASSWORD="${PGPASSWORD:-twin-bootstrap}" "$DB_CONTAINER" \
  psql -U twin -d "$DB_NAME" -qtAX -c \
  "DELETE FROM observations WHERE asset_id='vault-probe'" </dev/null >/dev/null 2>&1

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

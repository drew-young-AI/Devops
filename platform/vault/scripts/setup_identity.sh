#!/usr/bin/env bash
# Identity mechanism: who can prove they are whom, and what that identity
# may do. Human RBAC and workload identity are ONE mechanism with two kinds
# of subject -- they share the same policies, the same audit surface and the
# same administration, and splitting them into two systems is how the two
# drift apart.
#
#   Subject      How it proves identity      Vault auth method
#   ---------    -------------------------   -----------------
#   human        username + password         userpass
#   workload     role_id + secret_id         approle
#
# Both then get a token whose capabilities come from the SAME policy files
# in platform/vault/policies/. One policy language, one place to audit.
#
# Idempotent: safe to re-run. Re-running re-applies every policy file, which
# is what makes platform/vault/policies/*.hcl the source of truth rather
# than whatever happens to be live in Vault.
#
# Usage:
#   platform/vault/scripts/setup_identity.sh
#
# Requires VAULT_TOKEN with admin rights, or falls back to the root token in
# .init-output.json. Secret values are NEVER printed: generated credentials
# are written to platform/vault/.identity-output.json (chmod 600,
# gitignored), same handling as .init-output.json -- move to a password
# manager and delete the file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTAINER="${VAULT_CONTAINER:-vault-vault-1}"
POLICY_DIR="$VAULT_DIR/policies"
OUTPUT_FILE="$VAULT_DIR/.identity-output.json"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Vault container '$CONTAINER' is not running." >&2
  echo "Start it: cd platform/vault && docker compose up -d" >&2
  exit 1
fi

if [ -z "${VAULT_TOKEN:-}" ]; then
  if [ ! -f "$VAULT_DIR/.init-output.json" ]; then
    echo "No VAULT_TOKEN set and no .init-output.json to fall back to." >&2
    exit 1
  fi
  VAULT_TOKEN="$(python3 -c "
import json
print(json.load(open('$VAULT_DIR/.init-output.json'))['root_token'])
")"
fi

# All vault calls go through here so the token is passed via the environment
# of a single exec and never appears in a command line (visible in `ps`).
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

# Separate function for the one case that genuinely pipes data in, so the
# guarded default above cannot be quietly weakened to accommodate it.
v_stdin() {
  # stdin: intentional -- callers pipe a policy file in.
  docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" -e VAULT_ADDR=http://127.0.0.1:8200 \
    "$CONTAINER" vault "$@"
}

echo "=== [identity] enabling auth methods ==="
# `vault auth enable` errors if already enabled; that is the idempotent case,
# not a failure.
if ! v auth list -format=json | grep -q '"approle/"'; then
  v auth enable approle
  echo "  approle: enabled"
else
  echo "  approle: already enabled"
fi
if ! v auth list -format=json | grep -q '"userpass/"'; then
  v auth enable userpass
  echo "  userpass: enabled"
else
  echo "  userpass: already enabled"
fi

echo ""
echo "=== [identity] applying policies from $POLICY_DIR ==="
# Piped via stdin, not `docker cp`: this container's rootfs is read-only by
# design (see platform/vault/README.md).
for policy_file in "$POLICY_DIR"/*.hcl; do
  name="$(basename "$policy_file" .hcl)"
  v_stdin policy write "$name" - < "$policy_file"
  echo "  applied: $name"
done

echo ""
echo "=== [identity] workload identities (approle) ==="
# token_ttl / token_max_ttl are the point: a workload token is short-lived
# even while the underlying credential it reads is still static. Identity
# lifetime and credential lifetime are separate dials, and this one can be
# turned down today without waiting for dynamic secrets.
create_approle() {
  local role="$1" policy="$2"
  v write "auth/approle/role/$role" \
    token_policies="$policy" \
    token_ttl=20m \
    token_max_ttl=1h \
    secret_id_ttl=60m \
    secret_id_num_uses=0 >/dev/null
  local role_id
  role_id="$(v read -field=role_id "auth/approle/role/$role/role-id")"
  # Progress goes to stderr: stdout is the function's return channel, and
  # mixing the two made `$(create_approle ...)` swallow every progress line
  # (the caller only ever saw an empty section).
  echo "  $role -> policy=$policy role_id=$role_id" >&2
  echo "$role_id"
}

# role_id is an identifier, not a credential -- it is safe to log and to
# bake into config. The secret_id is the credential, and is minted on demand
# (see README "Minting a workload credential"), never stored here.
# A fixture, not a service -- see policies/workload-pilot-fixture.hcl.
# station2-twin's real workload identity is created by
# setup_database_secrets.sh, which owns it because it binds the dynamic
# database role. Two scripts creating the same AppRole would race.
FIXTURE_ROLE_ID="$(create_approle workload-pilot-fixture workload-pilot-fixture | tail -1)"
DATAOPS_ROLE_ID="$(create_approle workload-dataops dataops-readonly | tail -1)"
CI_ROLE_ID="$(create_approle ci-pipeline ci-pipeline | tail -1)"

echo ""
echo "=== [identity] human roles (userpass) ==="
# Passwords are generated here, written only to the gitignored output file,
# and never echoed. Creating a human account is otherwise the same
# mechanism as creating a workload account -- same policies, same audit.
gen_password() {
  python3 -c "import secrets; print(secrets.token_urlsafe(24))"
}

ADMIN_PW="$(gen_password)"
OPERATOR_PW="$(gen_password)"
VIEWER_PW="$(gen_password)"

v write auth/userpass/users/platform-admin \
  password="$ADMIN_PW" token_policies="default" token_ttl=1h >/dev/null
echo "  platform-admin   -> policy=default (see note below)"
v write auth/userpass/users/platform-operator \
  password="$OPERATOR_PW" token_policies="platform-operator" token_ttl=1h >/dev/null
echo "  platform-operator -> policy=platform-operator"
v write auth/userpass/users/platform-viewer \
  password="$VIEWER_PW" token_policies="platform-viewer" token_ttl=1h >/dev/null
echo "  platform-viewer   -> policy=platform-viewer (metadata only, no secret values)"

python3 - "$OUTPUT_FILE" "$ADMIN_PW" "$OPERATOR_PW" "$VIEWER_PW" \
  "$FIXTURE_ROLE_ID" "$DATAOPS_ROLE_ID" "$CI_ROLE_ID" <<'PY'
import json, os, pathlib, sys
path, admin, operator, viewer, fixture, dataops, ci = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
    "_warning": "Move these to a password manager and delete this file.",
    "humans": {
        "platform-admin": admin,
        "platform-operator": operator,
        "platform-viewer": viewer,
    },
    "workload_role_ids": {
        "workload-pilot-fixture": fixture,
        "workload-dataops": dataops,
        "ci-pipeline": ci,
    },
    "note": "role_id is an identifier, not a credential. secret_id is the "
            "credential and is minted on demand, never stored here.",
}, indent=2) + "\n")
os.chmod(path, 0o600)
PY

echo ""
echo "=== [identity] done ==="
echo "Credentials written to $OUTPUT_FILE (chmod 600, gitignored)."
echo "No secret value was printed by this script."
echo ""
echo "NOTE on platform-admin: it is deliberately created with the 'default'"
echo "policy, NOT root. Granting a standing root-equivalent human account is"
echo "the thing this mechanism exists to avoid. Elevating it is a decision"
echo "that belongs with the break-glass / audit design, which is still open"
echo "(it depends on the auditing body, per the user's own scoping)."

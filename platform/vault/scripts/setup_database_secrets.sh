#!/usr/bin/env bash
# Enable Vault's database secrets engine and issue short-lived credentials.
#
# This closes the last unfulfilled mechanism in the Vault work. The seam was
# reserved months ago in workload-station1-hello.hcl; everything until now has
# used a long-lived static password, deliberately, because there was no
# database to issue against. station2-twin changed that.
#
# WHAT ACTUALLY CHANGES, AND WHAT DOES NOT.
#
# The identity model does not change at all: the same AppRole, the same
# authentication, the same administration. Only the PATH the workload reads
# changes -- static `secret/data/...` becomes dynamic `database/creds/...`.
# That was the whole argument for building identity first and credentials
# second, and it is worth checking that the argument held. It did.
#
# THREE PROPERTIES THAT MAKE THIS MORE THAN A PASSWORD GENERATOR.
#
#   PER-WORKLOAD    Every consumer gets its OWN database user. A leaked
#                   credential names its holder, and revoking it affects
#                   nobody else. With one shared password, "rotate it"
#                   means "restart everything at once".
#
#   LEAST PRIVILEGE The generated role gets SELECT/INSERT/UPDATE and nothing
#                   else -- no DDL, no DELETE, no ownership. The application
#                   never needed them; the static bootstrap user had them
#                   because it was also the schema owner.
#
#   REVOCABLE       Credentials expire, and can be revoked immediately. This
#                   is the property that has to be OBSERVED rather than
#                   assumed: a "dynamic" credential that keeps working after
#                   revocation is a static credential with extra steps.
#
# WHY host.docker.internal AND NOT A SHARED DOCKER NETWORK.
#
# Vault runs in the platform's compose project, the database in the pilot's.
# Attaching Vault to the pilot's network would make a platform component
# depend on a specific pilot, which the boundary rule in README.md forbids
# and which does not survive a second pilot. Reaching the published port
# through the host keeps the dependency pointing the right way.
#
# Usage:
#   setup_database_secrets.sh <pilot> [db-host-port]
#
# Exit 0 configured and verified, 1 failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PILOT="${1:-station2-twin}"
DB_PORT="${2:-15432}"
DB_NAME="${DB_NAME:-twin}"
DB_ADMIN_USER="${DB_ADMIN_USER:-twin}"
DB_ADMIN_PASS="${PGPASSWORD:-twin-bootstrap}"
DB_CONTAINER="${DB_CONTAINER:-${PILOT}-db-1}"

VAULT_CONTAINER="${VAULT_CONTAINER:-vault-vault-1}"
INIT_FILE="$REPO_ROOT/platform/vault/.init-output.json"
ROLE="$PILOT"
# Vault's own database login. Deliberately NOT the application user and NOT a
# superuser: it needs CREATEROLE to mint users, and nothing more.
VAULT_DB_USER="vault_admin"
VAULT_DB_PASS="${VAULT_DB_PASS:-$(openssl rand -base64 24 | tr -d '/+=' | head -c 28)}"

die() { echo "$@" >&2; exit 1; }

[ -f "$INIT_FILE" ] || die "Missing $INIT_FILE -- Vault has not been initialised."
ROOT_TOKEN="$(python3 -c "import json;print(json.load(open('$INIT_FILE'))['root_token'])")"

# stdin: redirected on every exec. `docker exec -i` attaches the caller's
# stdin, and inside any read loop that silently consumes the caller's input.
# This platform has been bitten by it three times.
v() { docker exec -e VAULT_TOKEN="$ROOT_TOKEN" "$VAULT_CONTAINER" vault "$@" </dev/null; }

# `vault policy write <name> -` reads the policy body from stdin, so it is the
# one command that MUST NOT get </dev/null. Kept as a separate function rather
# than dropping the redirect from v(): the redirect is what stops `docker exec
# -i` from eating the caller's stdin inside a read loop, which has broken this
# platform three times. Two functions, each obviously correct, beats one
# function that is conditionally safe.
v_stdin() { docker exec -i -e VAULT_TOKEN="$ROOT_TOKEN" "$VAULT_CONTAINER" vault "$@"; }  # stdin: intentional
psql_admin() {
  docker exec -e PGPASSWORD="$DB_ADMIN_PASS" "$DB_CONTAINER" \
    psql -U "$DB_ADMIN_USER" -d "$DB_NAME" -qtAX -v ON_ERROR_STOP=1 "$@" </dev/null
}

docker inspect "$DB_CONTAINER" >/dev/null 2>&1 || die "Database container $DB_CONTAINER is not running."
v status >/dev/null 2>&1 || die "Vault is not reachable or is sealed."

echo "=== [1/5] Vault's own database role ==="

# Idempotent: the password is reset every run, which is correct -- this
# script is also the recovery path when the role exists but its password is
# unknown (the generated one is never written to disk).
psql_admin -c "
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$VAULT_DB_USER') THEN
    CREATE ROLE $VAULT_DB_USER WITH LOGIN CREATEROLE PASSWORD '$VAULT_DB_PASS';
  ELSE
    ALTER ROLE $VAULT_DB_USER WITH LOGIN CREATEROLE PASSWORD '$VAULT_DB_PASS';
  END IF;
END
\$\$;" >/dev/null || die "Could not create the $VAULT_DB_USER role."

# It must be able to hand out privileges on objects it does not own. Granting
# the owner role to it (NOINHERIT keeps it from silently acting as the owner)
# is how PostgreSQL expresses that.
psql_admin -c "GRANT $DB_ADMIN_USER TO $VAULT_DB_USER;" >/dev/null 2>&1 || true
psql_admin -c "ALTER ROLE $VAULT_DB_USER NOINHERIT;" >/dev/null 2>&1 || true
# The group role from migration 010 -- Vault's creation_statement GRANTs it to
# every dynamic user, and postgres requires ADMIN OPTION to do that. Done here
# as well as in migration 011 because the two run in either order: a fresh
# database is migrated before Vault is configured, an existing one the other way
# round. NOT silenced with `|| true` like the lines above: if this fails, every
# credential Vault issues from now on fails too, and that must be loud.
if ! psql_admin -c "GRANT station2_app TO $VAULT_DB_USER WITH ADMIN OPTION;" >/dev/null 2>&1; then
  echo "  NOTE: station2_app does not exist yet -- apply migration 010 and 011," >&2
  echo "        then re-run this script, or credentials will fail to issue." >&2
fi
echo "  $VAULT_DB_USER created (LOGIN CREATEROLE NOINHERIT, not superuser)"

echo ""
echo "=== [2/5] database secrets engine ==="
if v secrets list -format=json 2>/dev/null | grep -q '"database/"'; then
  echo "  already enabled"
else
  v secrets enable database >/dev/null 2>&1 || die "Could not enable the database engine."
  echo "  enabled"
fi

v write database/config/"$PILOT" \
  plugin_name=postgresql-database-plugin \
  allowed_roles="$ROLE" \
  connection_url="postgresql://{{username}}:{{password}}@host.docker.internal:${DB_PORT}/${DB_NAME}?sslmode=disable" \
  username="$VAULT_DB_USER" \
  password="$VAULT_DB_PASS" \
  password_authentication=scram-sha-256 >/dev/null 2>&1 \
  || die "Could not configure the database connection."
echo "  connection configured -> host.docker.internal:${DB_PORT}/${DB_NAME}"

# Vault should not keep the password we just handed it in its own config in a
# readable form; rotate-root makes Vault choose a new one that nobody, not
# even this script, ever knows.
if v write -f database/rotate-root/"$PILOT" >/dev/null 2>&1; then
  echo "  root credential rotated -- the password in this script is now dead"
else
  echo "  WARNING: could not rotate the root credential" >&2
fi

echo ""
echo "=== [3/5] role: least privilege, short lease ==="
# No DDL. No DELETE. No ownership. The application inserts observations and
# reads them back; the static bootstrap user had far more than that purely
# because it also happened to own the schema.
#
# REVOCATION USES EXPLICIT REVOKEs, NOT `DROP OWNED BY`.
#
# The obvious revocation set -- REASSIGN OWNED then DROP OWNED then DROP ROLE
# -- fails here, and the failure is silent in the worst way: Vault reports
# "All revocation operations queued successfully", returns HTTP 202, and then
# retries in the background forever while the credential keeps working. Only
# the server log says why:
#
#   permission denied to reassign objects (SQLSTATE 42501)
#   Only roles with privileges of role "v-..." may drop objects owned by it
#
# PostgreSQL 16 requires INHERITed membership for "privileges of role", and
# vault_admin is deliberately NOINHERIT so that being a member of the schema
# owner does not silently make it the schema owner. Loosening that to make
# DROP OWNED work would trade a real privilege boundary for a convenience.
#
# So: revoke exactly what was granted. vault_admin was the grantor, so it can
# revoke without inheriting anything, and the generated role owns nothing to
# begin with -- it has no DDL privileges, so `DROP OWNED BY` was never doing
# anything except failing.
# The ON ALL TABLES lines below are a SNAPSHOT, not a rule: postgres expands
# them once, against the tables that exist at role-creation time. On 2026-08-19
# migration 008 added a table and every already-issued credential went to
# `InsufficientPrivilege` -- reported by readiness as `db_unreachable`, so it
# read as a database outage against a perfectly healthy database, for up to the
# full 3600s TTL. The GRANT station2_app line is the actual fix (migration 010
# gives that group ALTER DEFAULT PRIVILEGES, so future tables are covered
# automatically). The snapshot grants are kept only so a credential still works
# if 010 has not been applied yet.
v write database/roles/"$ROLE" \
  db_name="$PILOT" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
    GRANT CONNECT ON DATABASE ${DB_NAME} TO \"{{name}}\";
    GRANT USAGE ON SCHEMA public TO \"{{name}}\";
    GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO \"{{name}}\";
    GRANT station2_app TO \"{{name}}\";" \
  revocation_statements="REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM \"{{name}}\";
    REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM \"{{name}}\";
    REVOKE USAGE ON SCHEMA public FROM \"{{name}}\";
    REVOKE CONNECT ON DATABASE ${DB_NAME} FROM \"{{name}}\";
    DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl="1h" max_ttl="24h" >/dev/null 2>&1 \
  || die "Could not create the database role."
echo "  role '$ROLE' created (default_ttl 1h, max_ttl 24h)"

echo ""
echo "=== [4/5] policy and workload identity ==="
v_stdin policy write "workload-${PILOT}" - >/dev/null 2>&1 <<POLICY || die "Could not write the policy."
# Workload role: ${PILOT}.
#
# Reading this path makes Vault mint a brand-new database user with a TTL,
# valid only for this workload and revoked automatically on expiry. Note what
# is NOT here: no access to secret/, no ability to read any other workload's
# credentials, and no way to change its own role definition.
path "database/creds/${ROLE}" {
  capabilities = ["read"]
}

# Renewing its own lease is how a long-running process keeps a credential
# alive without escalating. Revocation is deliberately included: a workload
# that knows it is shutting down should be able to hand the credential back
# rather than leave it valid until expiry.
path "sys/leases/renew" {
  capabilities = ["update"]
}
path "sys/leases/revoke" {
  capabilities = ["update"]
}
POLICY
echo "  policy workload-${PILOT} written"

v auth list -format=json 2>/dev/null | grep -q '"approle/"' || v auth enable approle >/dev/null 2>&1
v write auth/approle/role/"$PILOT" \
  token_policies="workload-${PILOT}" \
  token_ttl=20m token_max_ttl=1h secret_id_ttl=0 >/dev/null 2>&1 \
  || die "Could not create the AppRole."

ROLE_ID="$(v read -field=role_id auth/approle/role/"$PILOT"/role-id 2>/dev/null)"
SECRET_ID="$(v write -f -field=secret_id auth/approle/role/"$PILOT"/secret-id 2>/dev/null)"
[ -n "$ROLE_ID" ] && [ -n "$SECRET_ID" ] || die "Could not obtain AppRole credentials."
echo "  approle '$PILOT' created (role_id ${ROLE_ID:0:8}...)"

OUT="$REPO_ROOT/platform/vault/.${PILOT}-approle.json"
python3 - "$OUT" "$ROLE_ID" "$SECRET_ID" <<'PY'
import json, os, pathlib, sys
out, role_id, secret_id = sys.argv[1:]
p = pathlib.Path(out)
p.write_text(json.dumps({"role_id": role_id, "secret_id": secret_id}, indent=2) + "\n")
os.chmod(p, 0o600)
PY
echo "  approle credentials -> $(basename "$OUT") (chmod 600, gitignored)"

echo ""
echo "=== [5/5] proving it works, and proving revocation works ==="
"$SCRIPT_DIR/verify_database_secrets.sh" "$PILOT" "$DB_PORT"

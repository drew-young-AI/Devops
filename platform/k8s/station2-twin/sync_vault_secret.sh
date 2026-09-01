#!/usr/bin/env bash
# Put the pilot's Vault AppRole into the cluster, so the K8s copy stops
# carrying a database password.
#
# WHY THIS EXISTS (2026-09-01).
#
# The pilot has two copies. The Compose copy has held dynamic Vault credentials
# since 2026-08-19 -- `/health/ready` reports `mode: vault`, username
# `v-approle-station2-...`, a lease that expires. The Kubernetes copy, the one
# intended to become production, was still running with this in its Deployment:
#
#     - { name: PGPASSWORD, value: "twin-bootstrap" }
#
# A password in plain text, in a manifest, shared by every replica, with no
# expiry and no revocation path. The copy with the WEAKER credential model was
# the one being promoted toward production.
#
# That divergence is exactly what the `environment` label separation was added
# to make visible (see platform/observability/README.md): two copies are only
# worth labelling apart if someone actually looks at where they differ.
# Observing it and not closing it is the same failure one step later.
#
# WHAT THIS DOES NOT SOLVE: SECRET ZERO.
#
# The AppRole `secret_id` now lives in a Kubernetes Secret, which is
# base64-encoded, not encrypted, and readable by anyone with `get secrets` in
# this namespace. That is a real limitation and is stated here rather than
# glossed: this replaces a SHARED, NEVER-EXPIRING DATABASE PASSWORD with a
# SCOPED, REVOCABLE, ROTATABLE BOOTSTRAP CREDENTIAL that grants nothing except
# the ability to request short-lived database credentials. That is a smaller
# blast radius, not zero blast radius.
#
# The end state is Vault's `kubernetes` auth method, where the pod's
# ServiceAccount token IS the identity and no secret is distributed at all.
# That needs a change to the pilot app (a second login path beside AppRole) and
# a token-reviewer binding in the cluster, so it is recorded as the next step
# rather than half-done here. See docs/Backlog.md §1.
#
# Usage:
#   sync_vault_secret.sh [--context CTX] [--namespace NS]
#
# Exit codes:
#   0  Secret created or updated, and verified present
#   1  the AppRole file is missing -- run platform/vault/scripts/setup_database_secrets.sh
#   2  the cluster is unreachable, or the Secret did not land
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

CTX="k3d-devops-lab"
NS="station2"
while [ $# -gt 0 ]; do
  case "$1" in
    --context) CTX="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    *) echo "Usage: $0 [--context CTX] [--namespace NS]" >&2; exit 2 ;;
  esac
done

APPROLE="$REPO_ROOT/platform/vault/.station2-twin-approle.json"
SECRET_NAME="station2-twin-vault"

if [ ! -f "$APPROLE" ]; then
  echo "FATAL: $APPROLE not found." >&2
  echo "  The AppRole is created by:" >&2
  echo "    platform/vault/scripts/setup_database_secrets.sh station2-twin 15432" >&2
  exit 1
fi

if ! kubectl --context "$CTX" --request-timeout=8s get ns "$NS" >/dev/null 2>&1; then
  echo "FATAL: cannot reach namespace '$NS' on context '$CTX'." >&2
  exit 2
fi

# Read the two fields into variables. They are never passed as argv -- `ps` is
# world-readable on this machine, so a `kubectl create secret --from-literal`
# would expose the secret_id to every local process for the duration of the
# call. The manifest goes in on stdin instead.
ROLE_ID="$(python3 -c "
import json,sys
print(json.load(open(sys.argv[1]))['role_id'])" "$APPROLE")"
SECRET_ID="$(python3 -c "
import json,sys
print(json.load(open(sys.argv[1]))['secret_id'])" "$APPROLE")"

if [ -z "$ROLE_ID" ] || [ -z "$SECRET_ID" ]; then
  echo "FATAL: $APPROLE is missing role_id or secret_id." >&2
  exit 1
fi

# `kubectl apply` rather than `create`: this must be idempotent. It is called by
# deploy.sh on every deployment, and a second run failing with AlreadyExists
# would make a routine deploy look like a broken one.
MANIFEST="$(python3 - "$ROLE_ID" "$SECRET_ID" "$SECRET_NAME" "$NS" <<'PY'
import base64, sys
role_id, secret_id, name, ns = sys.argv[1:5]
b = lambda s: base64.b64encode(s.encode()).decode()
print("""apiVersion: v1
kind: Secret
metadata:
  name: %s
  namespace: %s
  labels:
    app: station2-twin
  annotations:
    # Not a database password. This is a Vault AppRole bootstrap credential:
    # it grants only the right to REQUEST short-lived database credentials,
    # and revoking it in Vault takes effect without touching the database.
    devops.platform/kind: vault-approle
    devops.platform/upgrade-path: "vault kubernetes auth -- removes this Secret entirely"
type: Opaque
data:
  role_id: %s
  secret_id: %s""" % (name, ns, b(role_id), b(secret_id)))
PY
)"

printf '%s\n' "$MANIFEST" | kubectl --context "$CTX" apply -f - >/dev/null || {
  echo "FATAL: kubectl apply failed for Secret/$SECRET_NAME" >&2
  exit 2
}

# Read it back. `kubectl apply` reporting success is not the same as the Secret
# holding what was intended -- this repository has been bitten by exactly that
# gap often enough to stop trusting the write's own report (ADR-0007).
GOT_ROLE="$(kubectl --context "$CTX" -n "$NS" get secret "$SECRET_NAME" \
  -o jsonpath='{.data.role_id}' 2>/dev/null | base64 -d 2>/dev/null)"
if [ "$GOT_ROLE" != "$ROLE_ID" ]; then
  echo "FATAL: Secret/$SECRET_NAME does not hold the expected role_id after apply." >&2
  exit 2
fi

echo "  Secret/$SECRET_NAME synced to $CTX/$NS (role_id ${ROLE_ID:0:8}..., secret_id masked)"

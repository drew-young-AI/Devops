#!/usr/bin/env bash
# Audit trail: answers "who read which secret, when, and did it succeed".
#
# Until this existed, the platform could enforce access control but could not
# EVIDENCE it. Every policy boundary verified by verify_identity.sh proves
# what is *possible*; only an audit log records what actually *happened*.
# For an auditing body those are different questions, and the second one is
# the one they ask.
#
# ---------------------------------------------------------------------
# READ THIS BEFORE ENABLING: Vault audit devices are FAIL-CLOSED.
#
# If every enabled audit device fails to write, Vault stops serving requests
# entirely -- it will not perform an operation it cannot record. That is the
# correct security posture and it is also an availability hazard: a full
# disk on the audit volume becomes a total Vault outage, which in this
# platform means deploys stop too.
#
# Two mitigations, both deliberate:
#   1. TWO devices are enabled, not one. Vault proceeds if AT LEAST ONE
#      device accepts the record, so a single failing sink degrades instead
#      of halting.
#   2. The file device writes to a named volume (vault-logs), not the 4MB
#      tmpfs that used to be mounted there. See compose.yaml.
#
# Disk usage still needs watching. audit_query.sh reports the log size and
# warns past a threshold.
# ---------------------------------------------------------------------
#
# Sensitive values are HMAC-SHA256'd by Vault before being written, so the
# audit log records THAT a secret was read without recording the secret.
# `log_raw=true` disables that protection and must never be set here --
# it would turn the audit trail into the largest plaintext secret store in
# the platform.
#
# Usage:
#   platform/vault/scripts/setup_audit.sh
#
# Idempotent: re-running reports already-enabled devices instead of failing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTAINER="${VAULT_CONTAINER:-vault-vault-1}"
AUDIT_PATH="/vault/logs/audit.log"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Vault container '$CONTAINER' is not running." >&2
  exit 1
fi

if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(python3 -c "
import json
print(json.load(open('$VAULT_DIR/.init-output.json'))['root_token'])
")"
fi

v() {
  docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" -e VAULT_ADDR=http://127.0.0.1:8200 \
    "$CONTAINER" vault "$@" </dev/null
}

echo "=== [audit] enabling audit devices ==="

# Device 1: durable file on the vault-logs volume. This is the record of
# truth -- it survives restarts and is included in platform/backup/.
if v audit list -format=json 2>/dev/null | grep -q '"file/"'; then
  echo "  file/    already enabled"
else
  v audit enable file file_path="$AUDIT_PATH"
  echo "  file/    enabled -> $AUDIT_PATH"
fi

# Device 2: stdout, captured by Docker and shipped to Loki by Alloy. Exists
# for two reasons: it makes the audit trail queryable alongside every other
# platform log, and -- more importantly -- it is the second sink that keeps
# a single failing device from halting Vault entirely.
if v audit list -format=json 2>/dev/null | grep -q '"stdout/"'; then
  echo "  stdout/  already enabled"
else
  v audit enable -path=stdout file file_path=stdout
  echo "  stdout/  enabled (-> Docker logs -> Alloy -> Loki, restricted tenant)"
fi

echo ""
echo "=== [audit] verifying the device actually records ==="

# Enabling a device and having it write are different claims. A read is
# performed here specifically so there is a known event to look for.
PROBE_PATH="secret/devops/github"
v kv get -field=token "$PROBE_PATH" >/dev/null 2>&1 || true

sleep 1
if docker exec "$CONTAINER" sh -c "test -s $AUDIT_PATH"; then
  LINES="$(docker exec "$CONTAINER" sh -c "wc -l < $AUDIT_PATH" | tr -d ' ')"
  echo "  file device is writing ($LINES records)"
else
  echo "  ERROR: $AUDIT_PATH is empty or missing after a known request." >&2
  exit 1
fi

# The HMAC guarantee, checked rather than trusted: the literal path appears
# (so the record is useful), the secret value does not (so the log is safe).
if docker exec "$CONTAINER" sh -c "grep -q 'secret/devops/github' $AUDIT_PATH"; then
  echo "  request paths are recorded in readable form"
else
  echo "  WARNING: expected path not found in audit log" >&2
fi

SECRET_VALUE="$(v kv get -field=token "$PROBE_PATH" 2>/dev/null || true)"
if [ -n "$SECRET_VALUE" ]; then
  if docker exec "$CONTAINER" sh -c "grep -qF -- '$SECRET_VALUE' $AUDIT_PATH" 2>/dev/null; then
    echo "  CRITICAL: the plaintext secret VALUE appears in the audit log." >&2
    echo "  Check that log_raw is not enabled. Do not ship this." >&2
    exit 1
  fi
  echo "  secret values are HMAC'd, not stored in plaintext (verified)"
fi

echo ""
echo "=== [audit] done ==="
v audit list
echo ""
echo "Query it:  platform/vault/scripts/audit_query.sh --help"
echo "Reminder:  audit devices are fail-closed. If ALL of them cannot write,"
echo "           Vault stops serving requests. Watch the log size."

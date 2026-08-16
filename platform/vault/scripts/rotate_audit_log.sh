#!/usr/bin/env bash
# Rotate Vault's file audit log.
#
# This is not housekeeping. Vault audit devices are FAIL-CLOSED: if every
# device cannot write, Vault refuses ALL requests -- which on this platform
# means secrets, identity and deploys all stop. An audit log that grows
# without bound is therefore a scheduled outage, and rotation is the control
# that prevents it.
#
# Vault's file device performs no rotation of its own. The documented
# mechanism is: move the file aside, then SIGHUP the process, which closes
# and reopens the path. Verified here before being trusted -- Vault stayed
# unsealed, kept serving requests, and created a fresh audit.log.
#
# ARCHIVES ARE NEVER DELETED. How long audit records must be kept is an
# auditing-body decision that has not been made (see platform/vault/README.md
# "Audit Trail"), and deleting on a guess is the one irreversible mistake
# available here. Old archives are compressed, never pruned, and total size
# is reported so the decision surfaces before the disk does.
#
# Usage:
#   rotate_audit_log.sh [--force] [--threshold-mb N]
#
# Exit 0 whether or not rotation was needed; non-zero only on real failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTAINER="${VAULT_CONTAINER:-vault-vault-1}"
AUDIT_PATH="/vault/logs/audit.log"
LOG_DIR="/vault/logs"

FORCE=0
THRESHOLD_MB="${AUDIT_ROTATE_THRESHOLD_MB:-50}"

while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --threshold-mb) THRESHOLD_MB="${2:?}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Vault container '$CONTAINER' is not running." >&2
  exit 1
fi

dexec() { docker exec -i "$CONTAINER" sh -c "$1" </dev/null; }

if ! dexec "test -f $AUDIT_PATH"; then
  echo "No audit log at $AUDIT_PATH -- nothing to rotate."
  exit 0
fi

SIZE_BYTES="$(dexec "wc -c < $AUDIT_PATH" | tr -d ' ')"
THRESHOLD_BYTES=$((THRESHOLD_MB * 1024 * 1024))

echo "=== [audit-rotate] current: $((SIZE_BYTES / 1024)) KB, threshold: ${THRESHOLD_MB} MB ==="

if [ "$FORCE" -eq 0 ] && [ "$SIZE_BYTES" -lt "$THRESHOLD_BYTES" ]; then
  echo "Below threshold -- no rotation needed."
  ARCHIVE_TOTAL="$(dexec "du -sk $LOG_DIR 2>/dev/null | cut -f1" | tr -d ' ')"
  echo "  audit dir total: $((ARCHIVE_TOTAL / 1024)) MB"
  exit 0
fi

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
ARCHIVE="$LOG_DIR/audit-${STAMP}.log"

echo "Rotating -> $(basename "$ARCHIVE")"
dexec "mv $AUDIT_PATH $ARCHIVE"

# SIGHUP makes Vault close and reopen the audit path. It does NOT restart or
# seal Vault -- verified by observing Sealed=false and a successful secret
# read immediately afterwards.
docker kill -s HUP "$CONTAINER" >/dev/null
sleep 3

# The dangerous outcome is not "rotation failed" but "rotation appeared to
# work and Vault is no longer recording". Both are checked, because a silent
# audit gap is exactly the thing this whole mechanism exists to prevent.
if ! dexec "test -f $AUDIT_PATH"; then
  echo "ROTATION FAILED: Vault did not recreate $AUDIT_PATH after SIGHUP." >&2
  echo "The previous log is preserved at $ARCHIVE." >&2
  echo "Vault may now be unable to write audit records -- it is FAIL-CLOSED," >&2
  echo "so check immediately: docker exec $CONTAINER vault status" >&2
  exit 1
fi

SEALED="$(docker exec -i -e VAULT_ADDR=http://127.0.0.1:8200 "$CONTAINER" \
  vault status -format=json </dev/null 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['sealed'])" 2>/dev/null || echo unknown)"
if [ "$SEALED" != "False" ]; then
  echo "ROTATION FAILED: Vault reports sealed=$SEALED after SIGHUP." >&2
  exit 1
fi

# A recreated file proves the path exists; it does not prove Vault is
# recording into it. An empty log right after rotation is normal (no
# requests yet), so emptiness is not the signal -- a deliberate probe is.
# Getting this wrong would leave a silent audit gap looking like success.
if [ -f "$VAULT_DIR/.init-output.json" ]; then
  PROBE_TOKEN="$(python3 -c "
import json
print(json.load(open('$VAULT_DIR/.init-output.json'))['root_token'])
")"
  # Reading a path that does not exist is still an audited request, so this
  # probes the audit path without touching a real secret.
  docker exec -i -e VAULT_TOKEN="$PROBE_TOKEN" -e VAULT_ADDR=http://127.0.0.1:8200 \
    "$CONTAINER" vault kv metadata get secret/_rotation_probe </dev/null >/dev/null 2>&1 || true
  sleep 1
  PROBE_SIZE="$(dexec "wc -c < $AUDIT_PATH" | tr -d ' ')"
  if [ "$PROBE_SIZE" -gt 0 ]; then
    echo "  verified: new log is receiving records (probe request recorded)"
  else
    echo "ROTATION FAILED: new audit log stayed empty after a known request." >&2
    echo "Vault is FAIL-CLOSED on audit writes -- investigate immediately." >&2
    exit 1
  fi
else
  echo "  NOTE: no root token available, could not probe-verify recording." >&2
fi

NEW_SIZE="$(dexec "wc -c < $AUDIT_PATH" | tr -d ' ')"

# Compress, never delete. gzip on JSON-lines audit data typically reaches
# 10-20x, which buys far more headroom than any retention policy anyone has
# actually asked for.
dexec "gzip -f $ARCHIVE" || echo "WARNING: could not compress $ARCHIVE" >&2

ARCHIVE_COUNT="$(dexec "ls -1 $LOG_DIR/audit-*.log.gz 2>/dev/null | wc -l" | tr -d ' ')"
ARCHIVE_TOTAL="$(dexec "du -sk $LOG_DIR 2>/dev/null | cut -f1" | tr -d ' ')"

echo "ROTATE PASS"
echo "  archived:   $(basename "$ARCHIVE").gz"
echo "  new log:    $((NEW_SIZE)) bytes, Vault unsealed and serving"
echo "  archives:   $ARCHIVE_COUNT file(s), audit dir total $((ARCHIVE_TOTAL / 1024)) MB"
echo ""
echo "Archives are never deleted here -- retention is an auditing-body"
echo "decision that has not been made. They are in the vault-logs volume and"
echo "are included in platform/backup/."

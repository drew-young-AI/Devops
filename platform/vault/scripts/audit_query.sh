#!/usr/bin/env bash
# Auditor-facing view of the Vault audit trail.
#
# The raw log is one JSON object per request, ~2KB each, with every value of
# interest HMAC'd. Handing an auditor `tail audit.log` is not an audit
# capability -- it is a pile of bytes that happens to contain the answer.
# This turns it into the three questions actually asked:
#
#   who touched this secret, when, and were they allowed?
#
# Usage:
#   audit_query.sh                          last 20 secret operations
#   audit_query.sh --path secret/devops     only that path prefix
#   audit_query.sh --actor platform-viewer  only that identity
#   audit_query.sh --denied                 only refused requests
#   audit_query.sh --all                    include sys/ and auth/ traffic
#   audit_query.sh --limit 100
#   audit_query.sh --json                   machine-readable
#
# Reading the audit log requires access to the Vault container, which is
# deliberately narrower than the platform-viewer Vault role: seeing WHO read
# WHAT is a higher privilege than seeing that a secret exists.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="${VAULT_CONTAINER:-vault-vault-1}"
AUDIT_PATH="/vault/logs/audit.log"

FILTER_PATH=""
FILTER_ACTOR=""
DENIED_ONLY=0
INCLUDE_ALL=0
LIMIT=20
AS_JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --path)   FILTER_PATH="${2:?--path needs a value}"; shift 2 ;;
    --actor)  FILTER_ACTOR="${2:?--actor needs a value}"; shift 2 ;;
    --denied) DENIED_ONLY=1; shift ;;
    --all)    INCLUDE_ALL=1; shift ;;
    --limit)  LIMIT="${2:?--limit needs a value}"; shift 2 ;;
    --json)   AS_JSON=1; shift ;;
    --help|-h) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
  esac
done

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Vault container '$CONTAINER' is not running." >&2
  exit 1
fi

if ! docker exec "$CONTAINER" sh -c "test -s $AUDIT_PATH" 2>/dev/null; then
  echo "No audit log at $AUDIT_PATH." >&2
  echo "Enable it: platform/vault/scripts/setup_audit.sh" >&2
  exit 1
fi

SIZE_BYTES="$(docker exec "$CONTAINER" sh -c "wc -c < $AUDIT_PATH" | tr -d ' ')"

# The log is copied to a temp file and passed BY PATH rather than piped in.
# `docker exec cat ... | python3 - <<'PY'` looks correct and silently reads
# nothing: the heredoc IS python's stdin, so it consumes the script and the
# pipe is discarded. Every query returned zero records with no error.
LOG_COPY="$(mktemp)"
trap 'rm -f "$LOG_COPY"' EXIT
docker exec "$CONTAINER" cat "$AUDIT_PATH" > "$LOG_COPY"

python3 - \
  "$LOG_COPY" "$FILTER_PATH" "$FILTER_ACTOR" "$DENIED_ONLY" "$INCLUDE_ALL" "$LIMIT" "$AS_JSON" "$SIZE_BYTES" <<'PY'
import json, sys

log_path, filter_path, filter_actor, denied_only, include_all, limit, as_json, size_bytes = sys.argv[1:]
denied_only, include_all, limit = int(denied_only), int(include_all), int(limit)
as_json, size_bytes = int(as_json), int(size_bytes)

records = []
malformed = 0
for line in open(log_path, encoding='utf-8'):
    line = line.strip()
    if not line:
        continue
    try:
        entry = json.loads(line)
    except json.JSONDecodeError:
        malformed += 1
        continue
    # Vault writes a "request" record and a "response" record per operation.
    # Only response records carry the allow/deny outcome, so those are the
    # ones worth showing -- request-only records would double every row and
    # report nothing about whether it succeeded.
    if entry.get("type") != "response":
        continue

    req = entry.get("request", {})
    auth = entry.get("auth", {})
    path = req.get("path", "")

    if not include_all and not path.startswith("secret/"):
        continue
    if filter_path and not path.startswith(filter_path):
        continue

    actor = auth.get("display_name") or "-"
    policies = auth.get("token_policies") or auth.get("policies") or []
    if filter_actor and filter_actor not in actor and filter_actor not in policies:
        continue

    error = entry.get("error") or ""
    allowed = (auth.get("policy_results") or {}).get("allowed")
    # A permission error and an explicitly-not-allowed policy result are the
    # same event to an auditor, and Vault reports them in different fields.
    denied = bool(error) or allowed is False
    if denied_only and not denied:
        continue

    records.append({
        "time": entry.get("time", "")[:19].replace("T", " "),
        "actor": actor,
        "policies": ",".join(policies) or "-",
        "operation": req.get("operation", "-"),
        "path": path,
        "outcome": "DENIED" if denied else "allowed",
        "error": error[:80],
        "remote_address": req.get("remote_address", "-"),
    })

records = records[-limit:]

if as_json:
    print(json.dumps({
        "records": records,
        "audit_log_size_bytes": size_bytes,
        "malformed_lines": malformed,
    }, indent=2, ensure_ascii=False))
    sys.exit(0)

if not records:
    print("No matching audit records.")
else:
    # Width from the data, not a guess: userpass display names run to 26+
    # chars and a fixed :<20 silently broke every column to its right.
    aw = max(len("ACTOR"), max(len(r["actor"]) for r in records))
    print(f"{'TIME':<20} {'ACTOR':<{aw}} {'OP':<7} {'OUTCOME':<8} PATH")
    print("-" * (20 + aw + 7 + 8 + 34))
    for r in records:
        print(f"{r['time']:<20} {r['actor']:<{aw}} {r['operation']:<7} "
              f"{r['outcome']:<8} {r['path']}")
        if r["error"]:
            first = r["error"].replace(chr(10), " ").strip()
            print(f"{'':<20} {'':<{aw}} {'':<7} {'':<8} -> {first[:70]}")

print()
print(f"{len(records)} record(s) shown.  audit log: {size_bytes/1024:.1f} KB")
if malformed:
    print(f"WARNING: {malformed} unparseable line(s) -- possible truncation.")

# Audit devices are fail-closed: if every device cannot write, Vault stops
# serving requests entirely. Disk pressure on this volume is therefore a
# Vault outage, not a logging inconvenience -- which is why size is surfaced
# on every query rather than hidden behind a separate check nobody runs.
if size_bytes > 100 * 1024 * 1024:
    print("WARNING: audit log over 100MB. Vault is FAIL-CLOSED on audit "
          "writes -- if this volume fills, Vault stops serving requests. "
          "Rotate or archive it.")
PY

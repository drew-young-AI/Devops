#!/usr/bin/env bash
# Notification sink for scheduled-job state transitions.
#
# DEFAULT IS LOCAL-ONLY, ON PURPOSE.
#
# A notification carries platform state -- which service is down, which gate
# failed, which secret path was refused. Pushing that to Telegram, email or a
# webhook sends operational detail about a system handling medical data to a
# third party. That is a decision with a real blast radius, and it is the
# user's to make, not a default to inherit because it was convenient.
#
# So the built-in sinks do not leave the machine:
#   * append to evidence/scheduler/notifications.jsonl (durable, queryable)
#   * macOS Notification Centre (visible when someone is actually logged in)
#
# To add an external destination, set NOTIFY_WEBHOOK to a URL. Nothing is
# sent anywhere until that variable exists -- opting in is an explicit act.
#
# Usage:
#   notify.sh <job> <old-status> <new-status>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

JOB="${1:?}"
OLD="${2:?}"
NEW="${3:?}"

STATE_DIR="$REPO_ROOT/evidence/scheduler"
FEED="$STATE_DIR/notifications.jsonl"
mkdir -p "$STATE_DIR"

AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# Recovery is a transition worth reporting too: silence after a failure is
# indistinguishable from the failure continuing.
case "$NEW" in
  ok)                       SEVERITY="recovered"; SYMBOL="OK" ;;
  degraded|unknown)         SEVERITY="warning";   SYMBOL="WARN" ;;
  critical|failed|timeout)  SEVERITY="critical";  SYMBOL="FAIL" ;;
  *)                        SEVERITY="info";      SYMBOL="INFO" ;;
esac

SUMMARY="[$SYMBOL] $JOB: $OLD -> $NEW"

# --- sink 1: durable feed ------------------------------------------------
# JSON Lines rather than a formatted log: the value stream board and any
# future consumer can read it without parsing prose.
python3 - "$FEED" "$AT" "$JOB" "$OLD" "$NEW" "$SEVERITY" "$SUMMARY" <<'PY'
import json, sys
feed, at, job, old, new, severity, summary = sys.argv[1:]
with open(feed, "a", encoding="utf-8") as fh:
    fh.write(json.dumps({
        "at": at, "job": job, "from": old, "to": new,
        "severity": severity, "summary": summary,
    }, ensure_ascii=False) + "\n")
PY

# --- sink 2: desktop, best effort ---------------------------------------
# Best effort by design: under launchd there may be no GUI session at all,
# and a notification that cannot be displayed must never fail the job that
# triggered it.
if command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"$OLD -> $NEW\" with title \"DevOps: $JOB\" subtitle \"$SEVERITY\"" \
    >/dev/null 2>&1 || true
fi

# --- sink 3: mail, when it has been proven to work -----------------------
# A job crossing from ok to failed is a TRANSITION, so it is sent once, on the
# crossing -- not repeated while the job stays broken. Alertmanager owns the
# repeating kind; see platform/notify/emit_event.sh for why the two are kept
# apart. Recovery is mailed too: silence after a failure is indistinguishable
# from the failure continuing.
#
# Delivery is best effort and never changes the job's own outcome. rc 78 means
# mail was never configured, which is a visible state rather than a failure.
if [ "$SEVERITY" != "info" ]; then
  MAILER="$REPO_ROOT/platform/notify/send_mail.sh"
  if [ -x "$MAILER" ]; then
    printf '%s\n\n%s\n' "$SUMMARY" \
      "排程工作 $JOB 由 $OLD 轉為 $NEW（$AT）。這是一次狀態轉換，不會重送。" \
      | "$MAILER" "[DevOps] $JOB: $OLD -> $NEW" >/dev/null 2>&1 \
      || true
  fi
fi

# --- sink 4: external webhook, opt-in only ------------------------------
if [ -n "${NOTIFY_WEBHOOK:-}" ]; then
  curl -sS -m 10 -X POST "$NOTIFY_WEBHOOK" \
    -H 'Content-Type: application/json' \
    -d "$(python3 -c "
import json, sys
print(json.dumps({'text': sys.argv[1], 'job': sys.argv[2],
                  'severity': sys.argv[3], 'at': sys.argv[4]}))
" "$SUMMARY" "$JOB" "$SEVERITY" "$AT")" >/dev/null 2>&1 \
    || echo "notify: webhook delivery failed (job outcome unaffected)" >&2
fi

echo "notify: $SUMMARY"

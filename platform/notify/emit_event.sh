#!/usr/bin/env bash
# One-shot platform EVENTS. Deliberately not Alertmanager.
#
# THE DISTINCTION THIS SCRIPT EXISTS TO ENFORCE.
#
#   STATE  a condition that is true and stays true -- a service is down, a
#          schema version is unknown. Alertmanager owns these. It groups them,
#          it REPEATS them every 4h while they hold, it silences them on
#          request, and it sends a resolved notice when they stop.
#
#   EVENT  something that happened once and is already over -- a promote
#          succeeded, a restore drill failed, the model gate refused a release.
#          It has no duration, so there is nothing to repeat and nothing to
#          resolve.
#
# Putting an event through Alertmanager gives one of two broken outcomes: it
# never resolves, so it re-sends every four hours forever about something that
# finished; or it resolves immediately, so one thing that happened arrives as
# two emails saying opposite things. Neither is a delivery problem -- both are
# the wrong tool. Hence a separate, deliberately dumber path: send once, record
# once, never repeat.
#
# NOTIFICATION FAILURE MUST NOT FAIL THE CALLER.
# Always exits 0. A backup that worked must not be recorded as broken because
# the mail about it bounced; the delivery outcome is recorded in the feed
# instead, where it can be seen without changing the caller's own result.
#
# Usage:
#   emit_event.sh <event-id> <ok|failed|blocked> [detail...]

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FEED="$REPO_ROOT/evidence/notify/events.jsonl"

EVENT="${1:?usage: emit_event.sh <event-id> <ok|failed|blocked> [detail]}"
OUTCOME="${2:?usage: emit_event.sh <event-id> <ok|failed|blocked> [detail]}"
shift 2 || true
DETAIL="${*:-}"

# The events that are worth a person's attention, and what each one means.
# A registry rather than free-form strings: an event id that nobody declared is
# almost always a typo, and a typo here means a notification that silently never
# had a subject line anybody recognises.
case "$EVENT" in
  promote)        TITLE="換版" ;;
  backup)         TITLE="備份" ;;
  restore-drill)  TITLE="還原演練" ;;
  model-gate)     TITLE="模型上線閘門" ;;
  rotation)       TITLE="憑證輪替" ;;
  *) echo "emit_event: unknown event id '$EVENT' -- add it to the registry" >&2; exit 0 ;;
esac

case "$OUTCOME" in
  ok)      MARK="成功"; NOTIFY=1 ;;
  failed)  MARK="失敗"; NOTIFY=1 ;;
  # `blocked` is a gate doing its job. It is reported because a release that
  # silently did not happen is indistinguishable from one nobody attempted.
  blocked) MARK="被擋下"; NOTIFY=1 ;;
  *) echo "emit_event: outcome must be ok|failed|blocked, got '$OUTCOME'" >&2; exit 0 ;;
esac

AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
LAN="${PLATFORM_LAN_HOST:-$(scutil --get LocalHostName 2>/dev/null).local}"
SUBJECT="[DevOps] ${TITLE}${MARK}"

BODY="$(cat <<EOF
${TITLE}${MARK}

事件   ${EVENT}
結果   ${OUTCOME}
時間   ${AT}
${DETAIL:+說明   ${DETAIL}}

這是一次性事件，不會重送。持續中的異常走告警管道（Alertmanager），會每 4 小時重送直到解除。

階段燈號  http://${LAN}:18085/Stage-Report.html
Grafana   http://${LAN}:13000/
EOF
)"

DELIVERY="skipped"
if [ "$NOTIFY" = "1" ]; then
  if printf '%s\n' "$BODY" | "$SCRIPT_DIR/send_mail.sh" "$SUBJECT" 2>/dev/null; then
    DELIVERY="sent"
  else
    case $? in
      78) DELIVERY="not-configured" ;;
      *)  DELIVERY="failed" ;;
    esac
  fi
fi

mkdir -p "$(dirname "$FEED")"
python3 - "$FEED" "$AT" "$EVENT" "$OUTCOME" "$DETAIL" "$DELIVERY" "$SUBJECT" <<'PY'
import json, sys
feed, at, event, outcome, detail, delivery, subject = sys.argv[1:8]
with open(feed, "a", encoding="utf-8") as fh:
    fh.write(json.dumps({"at": at, "kind": "event", "event": event,
                         "outcome": outcome, "detail": detail,
                         "delivery": delivery, "subject": subject},
                        ensure_ascii=False) + "\n")
PY

echo "event ${EVENT}=${OUTCOME} recorded (mail: ${DELIVERY})"
exit 0

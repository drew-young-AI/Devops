#!/usr/bin/env bash
# The mail transport. One place, so there is one thing to fix when it breaks.
#
# Reads the body from stdin. Never takes the password as an argument -- it is
# read from the chmod 600 file setup_mail.sh wrote, which is the same file
# Alertmanager reads, so both channels fail together rather than one of them
# quietly working with a stale credential.
#
# EXIT 78 (not-configured) WHEN MAIL IS NOT SET UP.
#
# Not 0, and not 1. Zero would let a caller report success for a message that
# went nowhere; one would make an unconfigured platform look broken. 78 is the
# same not-configured signal the offsite backup uses, so `not configured` stays
# one visible state across the platform rather than three different silences.
#
# Usage:
#   echo "body" | send_mail.sh "subject"
#   send_mail.sh "subject" < file

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CONF="$SCRIPT_DIR/mail.conf"
PW_FILE="$REPO_ROOT/platform/observability/alertmanager/smtp-password"

SUBJECT="${1:?usage: send_mail.sh <subject> [< body]}"

[ -f "$CONF" ]    || { echo "send_mail: not configured (no mail.conf)" >&2; exit 78; }
[ -f "$PW_FILE" ] || { echo "send_mail: not configured (no smtp-password)" >&2; exit 78; }
# shellcheck source=/dev/null
. "$CONF"

SMTP_PASSWORD="$(cat "$PW_FILE")" python3 - "$HOST" "$FROM" "$TO" "$SUBJECT" <<'PY'
import os, smtplib, ssl, sys
from email.message import EmailMessage

host, sender, rcpt, subject = sys.argv[1:5]
msg = EmailMessage()
msg["From"], msg["To"], msg["Subject"] = sender, rcpt, subject
msg.set_content(sys.stdin.read())
try:
    s = smtplib.SMTP(host, 587, timeout=25)
    s.ehlo(); s.starttls(context=ssl.create_default_context()); s.ehlo()
    s.login(sender, os.environ["SMTP_PASSWORD"])
    s.send_message(msg); s.quit()
except Exception as e:
    # The error goes to stderr and the exit code is non-zero, but the CALLER
    # decides what that means. A backup that succeeded must not be recorded as
    # failed because the notification about it could not be delivered.
    sys.stderr.write("send_mail: %s: %s\n" % (type(e).__name__, e))
    sys.exit(1)
PY

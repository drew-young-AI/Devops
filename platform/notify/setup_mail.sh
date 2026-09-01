#!/usr/bin/env bash
# Configure outbound mail, and PROVE it works before claiming it does.
#
# WHY THIS IS A SETUP SCRIPT AND NOT A CONFIG FILE.
#
# The platform already learned this lesson once, expensively. On 2026-08-19 an
# alert fired correctly and kept firing for 3h55m into a receiver called
# `local-null`. Every layer worked; the last hop reached nobody. An alert that
# fires into a dead channel is indistinguishable from an alert that never fired.
#
# So this script does not "configure mail". It configures mail and then SENDS A
# REAL MESSAGE, and fails if the send is refused. A mail path that has never
# delivered is not a mail path.
#
# THE SPECIFIC UNCERTAINTY THIS RESOLVES.
#
# smtp-mail.outlook.com advertises `AUTH LOGIN XOAUTH2` (measured 2026-08-26),
# so basic auth is on the menu at the SERVER. Whether Microsoft still permits it
# for a given personal account is a per-account policy that no amount of reading
# can settle -- Alertmanager's email_configs cannot do OAuth2, so if basic auth
# is refused for this account, this whole route is dead and we need to know that
# now rather than during an incident.
#
# THE PASSWORD NEVER APPEARS IN A COMMAND LINE.
#
# Read from the terminal with `read -s`, or from stdin when piped. Never an
# argument: arguments are visible in `ps` to every process on the machine, and
# an app password for a mailbox is a credential like any other. It is written to
# Vault as the source of truth, and dropped to a chmod 600 file only because
# Alertmanager reads credentials from files, not from Vault.
#
# Usage:
#   setup_mail.sh <from-address> [recipient]     # prompts for the password
#   printf '%s' "$PW" | setup_mail.sh <from> --stdin
#   setup_mail.sh --test                          # re-send using stored config

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

VAULT_CONTAINER="${VAULT_CONTAINER:-vault-vault-1}"
VAULT_PATH="secret/devops/smtp"
AM_DIR="$REPO_ROOT/platform/observability/alertmanager"
PW_FILE="$AM_DIR/smtp-password"
CONF="$REPO_ROOT/platform/notify/mail.conf"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "  $*"; }

# ---------------------------------------------------------------------------
# Host inference. Kept to the providers actually in play rather than a general
# lookup: guessing an SMTP host from a domain is exactly the kind of "force a
# mapping" this platform refuses to do elsewhere.
# ---------------------------------------------------------------------------
smtp_host_for() {
  case "${1##*@}" in
    hotmail.com|hotmail.com.tw|outlook.com|live.com|msn.com) echo "smtp-mail.outlook.com" ;;
    gmail.com|g.ntu.edu.tw)                                  echo "smtp.gmail.com" ;;
    *) echo "" ;;
  esac
}

ACTION=configure
[ "${1:-}" = "--test" ] && ACTION=test

if [ "$ACTION" = "configure" ]; then
  FROM="${1:-}"; [ -n "$FROM" ] || die "usage: setup_mail.sh <from-address> [recipient]"
  case "$FROM" in *@*.*) ;; *) die "'$FROM' does not look like an address" ;; esac
  TO="${2:-$FROM}"
  [ "$TO" = "--stdin" ] && TO="$FROM"

  HOST="$(smtp_host_for "$FROM")"
  [ -n "$HOST" ] || die "no known SMTP host for ${FROM##*@}. Add it to smtp_host_for() rather than guessing."

  if [ -t 0 ]; then
    printf '  SMTP password (app password) for %s: ' "$FROM" >&2
    IFS= read -rs PASSWORD; echo >&2
  else
    IFS= read -r PASSWORD
  fi
  [ -n "${PASSWORD:-}" ] || die "empty password"
  say "password received (${#PASSWORD} chars -- the value is never printed or logged)"
else
  [ -f "$CONF" ] || die "no stored config; run setup_mail.sh <from-address> first"
  # shellcheck source=/dev/null
  . "$CONF"
  [ -f "$PW_FILE" ] || die "no stored password at $PW_FILE"
  PASSWORD="$(cat "$PW_FILE")"
fi

echo "== mail setup =="
say "from      $FROM"
say "to        $TO"
say "smtp      $HOST:587 (STARTTLS)"

# ---------------------------------------------------------------------------
# THE ONLY ASSERTION THAT MATTERS: send one.
# ---------------------------------------------------------------------------
say "sending a test message ..."
RESULT="$(SMTP_PASSWORD="$PASSWORD" python3 - "$HOST" "$FROM" "$TO" <<'PY'
import os, smtplib, ssl, sys
from email.message import EmailMessage

host, sender, rcpt = sys.argv[1:4]
msg = EmailMessage()
msg["From"] = sender
msg["To"] = rcpt
msg["Subject"] = "[DevOps] mail path verified"
msg.set_content(
    "This message exists to prove the platform can actually deliver mail.\n\n"
    "It was sent by platform/notify/setup_mail.sh. If you are reading it, the\n"
    "last hop works -- which is the one hop that a config file cannot prove.\n")

try:
    s = smtplib.SMTP(host, 587, timeout=25)
    s.ehlo(); s.starttls(context=ssl.create_default_context()); s.ehlo()
    s.login(sender, os.environ["SMTP_PASSWORD"])
    s.send_message(msg)
    s.quit()
    print("OK")
except smtplib.SMTPAuthenticationError as e:
    print("AUTH_REFUSED %s" % (e.smtp_error.decode("utf-8", "replace")[:400]
                               if isinstance(e.smtp_error, bytes) else e.smtp_error))
except Exception as e:
    print("FAILED %s: %s" % (type(e).__name__, e))
PY
)"

case "$RESULT" in
  OK) say "delivered." ;;
  AUTH_REFUSED*)
    echo >&2
    echo "AUTHENTICATION REFUSED by $HOST." >&2
    echo "  ${RESULT#AUTH_REFUSED }" >&2
    echo >&2
    echo "This is the outcome that decides the route. Alertmanager's email_configs" >&2
    echo "speaks basic auth only -- it cannot do OAuth2 -- so if this mailbox does" >&2
    echo "not accept an app password, mail via Alertmanager is not available for it." >&2
    echo "Common causes: app passwords disabled for the account; the password given" >&2
    echo "is the sign-in password rather than an app password; the tenant has SMTP" >&2
    echo "AUTH switched off." >&2
    exit 2 ;;
  *) die "send failed -- ${RESULT}" ;;
esac

[ "$ACTION" = "test" ] && exit 0

# ---------------------------------------------------------------------------
# Only now is it worth storing. Storing first would leave a credential on disk
# for a path that was never shown to work.
# ---------------------------------------------------------------------------
VAULT_TOKEN="${VAULT_TOKEN:-$(python3 -c "
import json,sys
try: print(json.load(open('$REPO_ROOT/platform/vault/.init-output.json'))['root_token'])
except Exception: print('')
")}"
if [ -n "$VAULT_TOKEN" ] && /usr/local/bin/docker exec "$VAULT_CONTAINER" true 2>/dev/null; then
  if printf '%s' "$PASSWORD" | /usr/local/bin/docker exec -i \
       -e VAULT_TOKEN="$VAULT_TOKEN" "$VAULT_CONTAINER" \
       vault kv put "$VAULT_PATH" username="$FROM" password=- >/dev/null 2>&1; then
    say "stored in Vault at $VAULT_PATH (source of truth)"
  else
    say "WARNING: could not write to Vault -- the file below is the only copy"
  fi
else
  say "WARNING: Vault unreachable -- the file below is the only copy"
fi

umask 077
mkdir -p "$AM_DIR"
printf '%s' "$PASSWORD" > "$PW_FILE"
chmod 600 "$PW_FILE"
say "wrote $PW_FILE (chmod 600, gitignored -- Alertmanager reads credentials from files)"

cat > "$CONF" <<EOF
# Generated by platform/notify/setup_mail.sh. No secret here: the password lives
# in Vault, and in the chmod 600 file Alertmanager reads.
HOST=$HOST
FROM=$FROM
TO=$TO
EOF
say "wrote $CONF"

echo
echo "Verified end to end. Check $TO -- the message is already sent."

#!/usr/bin/env bash
# Generate Alertmanager's live config from the template, with the Telegram
# credentials injected from outside the repository.
#
# WHY GENERATED RATHER THAN COMMITTED.
#
# Alertmanager does not expand environment variables in its config, so the chat
# id has to be a literal in the file. This repository is PUBLIC. A private
# channel id in a public repo is not a catastrophe, but it is an identifier that
# did not need publishing, and "it is not very secret" is exactly the reasoning
# that puts real secrets in git eventually. So: template committed, config
# generated, both the config and the token file gitignored.
#
# The token never enters either file. Alertmanager supports bot_token_file, so
# the token lives in a chmod 600 file that only the container reads.
#
# VERIFY, DO NOT ASSUME. This script ends by sending one real test message and
# failing if Telegram does not accept it. A notification path that has never
# delivered anything is the same class of artefact as the null receiver it
# replaces -- it reads as coverage and proves nothing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AM_DIR="$(cd "$HERE/../alertmanager" && pwd)"
TEMPLATE="$AM_DIR/config.template.yml"
CONFIG="$AM_DIR/config.yml"
TOKEN_FILE="$AM_DIR/telegram-token"
ENV_FILE="${NOTIFY_ENV_FILE:-$HOME/.env}"
SEND_TEST="${SEND_TEST:-1}"

[ -f "$TEMPLATE" ] || { echo "missing template: $TEMPLATE" >&2; exit 1; }
[ -f "$ENV_FILE" ] || { echo "missing env file: $ENV_FILE" >&2; exit 1; }

read_env() {
  python3 - "$ENV_FILE" "$1" <<'PY'
import re, sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text()
m = re.search(rf'^{re.escape(sys.argv[2])}\s*=\s*["\']?([^"\'\n]+)', text, re.M)
print(m.group(1).strip() if m else "")
PY
}

TOKEN="$(read_env TELEGRAM_BOT_TOKEN)"
# The channel variable is TELEGRAM_HOME_CHANNEL in this environment, not the
# TELEGRAM_CHAT_ID the Alertmanager docs use. Both are accepted rather than
# assuming one: guessing the variable name is how this silently writes an empty
# chat_id and delivers to nobody.
CHAT="$(read_env TELEGRAM_HOME_CHANNEL)"
[ -n "$CHAT" ] || CHAT="$(read_env TELEGRAM_CHAT_ID)"

if [ -z "$TOKEN" ] || [ -z "$CHAT" ]; then
  echo "FAILED: need TELEGRAM_BOT_TOKEN and TELEGRAM_HOME_CHANNEL (or" >&2
  echo "TELEGRAM_CHAT_ID) in $ENV_FILE." >&2
  echo "  token: $([ -n "$TOKEN" ] && echo present || echo MISSING)" >&2
  echo "  chat:  $([ -n "$CHAT" ] && echo present || echo MISSING)" >&2
  exit 1
fi

umask 077
printf '%s' "$TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

# Mail is OPTIONAL and its config is written by platform/notify/setup_mail.sh,
# which refuses to write it until it has actually delivered a message. If that
# file is absent, the email_configs block is REMOVED rather than left holding
# placeholders -- a receiver addressed to the literal string __MAIL_TO__ is the
# `local-null` failure wearing a different name.
MAIL_CONF="$HERE/../../notify/mail.conf"
MAIL_HOST=""; MAIL_FROM=""; MAIL_TO=""
if [ -f "$MAIL_CONF" ]; then
  # shellcheck source=/dev/null
  . "$MAIL_CONF"
  MAIL_HOST="$HOST"; MAIL_FROM="$FROM"; MAIL_TO="$TO"
fi
LAN_HOST="${PLATFORM_LAN_HOST:-$(scutil --get LocalHostName 2>/dev/null).local}"

python3 - "$TEMPLATE" "$CONFIG" "$CHAT" "$MAIL_HOST" "$MAIL_FROM" "$MAIL_TO" "$LAN_HOST" <<'PY'
import pathlib, re, sys
tpl, out, chat, mhost, mfrom, mto, lanhost = sys.argv[1:8]
text = pathlib.Path(tpl).read_text()
if "__TELEGRAM_CHAT_ID__" not in text:
    sys.exit("template has no __TELEGRAM_CHAT_ID__ placeholder -- refusing to "
             "write a config that would silently keep an old value")
text = text.replace("__TELEGRAM_CHAT_ID__", chat)

if mhost and mfrom and mto:
    text = (text.replace("__MAIL_SMARTHOST__", mhost)
                .replace("__MAIL_FROM__", mfrom)
                .replace("__MAIL_TO__", mto)
                .replace("__LAN_HOST__", lanhost))
else:
    # Drop the whole email_configs block, from its key to the next key at the
    # same indent. Leaving it in with placeholders would either refuse to parse
    # or, worse, parse fine and mail into nowhere.
    text = re.sub(r"\n    email_configs:\n(?:(?:      |\n).*\n)*", "\n", text)

leftovers = [m for m in re.findall(r"__[A-Z_]+__", text)]
if leftovers:
    sys.exit("unsubstituted placeholders remain: %s" % ", ".join(sorted(set(leftovers))))
pathlib.Path(out).write_text(text)
print("  mail receiver: %s" % ("to " + mto if mto else "not configured (telegram only)"))
PY
chmod 600 "$CONFIG"

# Validate with Alertmanager's OWN parser before claiming success.
#
# Not paranoia -- this caught a real defect the day it was added. An
# email_configs block was inserted one indent level inside telegram_configs,
# which is valid YAML and complete nonsense to Alertmanager: the telegram
# entry's api_url, parse_mode and message ended up as email fields. Nothing
# earlier in this script could have noticed, because every check up to here is
# about text substitution. The failure would have surfaced as Alertmanager
# refusing to start AFTER someone configured mail -- that is, at the exact
# moment they were expecting notifications to start working.
if command -v docker >/dev/null 2>&1; then
  AM_CHECK="$(docker run --rm -v "$AM_DIR:/cfg:ro" \
      --entrypoint amtool prom/alertmanager:v0.28.1 \
      check-config /cfg/config.yml 2>&1)" || {
    echo "REFUSING: Alertmanager rejects the generated config." >&2
    echo "$AM_CHECK" | sed 's/^/    /' >&2
    exit 1
  }
  echo "  amtool: config accepted ($(echo "$AM_CHECK" | grep -c receiver) receiver line(s))"
else
  echo "  amtool: SKIPPED (no docker) -- the generated config is UNVERIFIED" >&2
fi

echo "  wrote $(basename "$CONFIG") and $(basename "$TOKEN_FILE") (chmod 600, gitignored)"

# Both must be gitignored. Checked, not trusted: a .gitignore pattern that
# depends on directory depth has already broken once on this platform.
for f in "$CONFIG" "$TOKEN_FILE"; do
  if ! git -C "$HERE/../../.." check-ignore -q "$f" 2>/dev/null; then
    echo "REFUSING TO CONTINUE: $f is NOT gitignored." >&2
    rm -f "$TOKEN_FILE"
    exit 1
  fi
done
echo "  both confirmed gitignored"

if [ "$SEND_TEST" = "1" ]; then
  echo "  sending one test message to the channel..."
  resp="$(curl -s --max-time 20 -X POST \
    "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    -d "chat_id=${CHAT}" \
    -d "parse_mode=HTML" \
    --data-urlencode "text=<b>✅ Devops alert delivery wired</b>
Alertmanager will now send here. This is the test message from setup_notifications.sh.
If you are reading this, the chain that was silent for 3h55m on 2026-08-19 is closed." \
    2>&1)"
  if ! printf '%s' "$resp" | grep -q '"ok":true'; then
    echo "FAILED: Telegram rejected the test message." >&2
    echo "$resp" | head -c 400 >&2; echo >&2
    exit 1
  fi
  echo "  test message accepted by Telegram"
fi

echo ""
echo "Next: restart Alertmanager so it loads the generated config"
echo "  docker compose -f platform/observability/compose.yaml up -d alertmanager"

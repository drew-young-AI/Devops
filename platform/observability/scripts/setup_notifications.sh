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

python3 - "$TEMPLATE" "$CONFIG" "$CHAT" <<'PY'
import pathlib, sys
tpl, out, chat = sys.argv[1:]
text = pathlib.Path(tpl).read_text()
if "__TELEGRAM_CHAT_ID__" not in text:
    sys.exit("template has no __TELEGRAM_CHAT_ID__ placeholder -- refusing to "
             "write a config that would silently keep an old value")
pathlib.Path(out).write_text(text.replace("__TELEGRAM_CHAT_ID__", chat))
PY
chmod 600 "$CONFIG"

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

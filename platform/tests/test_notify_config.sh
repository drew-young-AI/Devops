#!/usr/bin/env bash
# The branch that only runs the day somebody finally configures mail.
#
# WHY THIS SUITE EXISTS (2026-09-11).
#
# `setup_notifications.sh` had no test. Its mail branch has never executed on
# this machine, because the SMTP credential has never existed -- and its own
# comments say what that costs:
#
#   "An email_configs block was inserted one indent level inside
#    telegram_configs, which is valid YAML and complete nonsense to
#    Alertmanager ... The failure would have surfaced as Alertmanager refusing
#    to start AFTER someone configured mail -- that is, at the exact moment
#    they were expecting notifications to start working."
#
# That defect was found by hand. Nothing stops the next one. The whole point of
# a second channel is that it works on the day the first one is down, so
# discovering it is broken while wiring it up is the worst possible timing --
# and it is the ONLY timing this code path has ever been exercised at.
#
# NO CREDENTIAL IS NEEDED to pin this down. `mail.conf` holds a host, a from
# and a to; none of them is a secret, and the password lives in a separate
# file this script never reads. So the transition -- unconfigured to
# configured -- is fully testable with fabricated values, against
# Alertmanager's OWN parser rather than a YAML library that would accept the
# nonsense above.
#
# SEND_TEST=0 throughout: a suite must never deliver a real Telegram message.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="notify-config"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

SB="$(mktemp -d)"
on_exit 'rm -rf "$SB"'

mkdir -p "$SB/platform/observability/scripts" \
         "$SB/platform/observability/alertmanager" \
         "$SB/platform/notify"
cp "$REPO_ROOT/platform/observability/scripts/setup_notifications.sh" \
   "$SB/platform/observability/scripts/"
cp "$REPO_ROOT/platform/observability/alertmanager/config.template.yml" \
   "$SB/platform/observability/alertmanager/"
cp "$REPO_ROOT/.gitignore" "$SB/.gitignore" 2>/dev/null || true

# The script refuses to finish unless the generated files are gitignored, and
# it checks that with git itself rather than trusting a pattern. So the sandbox
# has to be a real repository.
git -C "$SB" init -q 2>/dev/null
git -C "$SB" add -A >/dev/null 2>&1
git -C "$SB" -c user.email=t@t -c user.name=t commit -qm fixture >/dev/null 2>&1

ENVF="$SB/fake.env"
printf 'TELEGRAM_BOT_TOKEN="000000:FAKE-TOKEN-FOR-TESTS"\nTELEGRAM_HOME_CHANNEL="-1000000000000"\n' > "$ENVF"

SETUP="$SB/platform/observability/scripts/setup_notifications.sh"
OUT="$SB/platform/observability/alertmanager/config.yml"
MAILCONF="$SB/platform/notify/mail.conf"

run_setup() {
  rm -f "$OUT"
  run_cmd env SEND_TEST=0 NOTIFY_ENV_FILE="$ENVF" PLATFORM_LAN_HOST="fixture.local" \
    bash "$SETUP"
}

echo "== unconfigured: the email block is removed, not left holding placeholders =="
rm -f "$MAILCONF"
run_setup
assert_rc 0 "generates a config with no mail.conf present"
assert_file_exists "$OUT" "config.yml is written"
assert_output_contains "not configured (telegram only)" "and says the mail receiver is absent"
run_cmd grep -c '__' "$OUT"
assert_output_contains "0" "no placeholder survives into the generated config"
run_cmd grep -c 'email_configs' "$OUT"
assert_output_contains "0" "the email_configs block is gone entirely, not emptied"

echo "== configured: the branch that has never run on this machine =="
# Not secrets: a host, a from and a to. The password lives in a separate file
# this script never reads.
printf 'HOST=smtp.gmail.com\nFROM=fixture@example.invalid\nTO=ops@example.invalid\n' > "$MAILCONF"
run_setup
assert_rc 0 "generates a config with mail.conf present"
assert_output_contains "to ops@example.invalid" "and names the recipient it wired"

run_cmd grep -c '__' "$OUT"
assert_output_contains "0" "still no placeholder survives once mail is configured"
run_cmd grep -c 'email_configs' "$OUT"
assert_output_contains "1" "exactly one email_configs block, not zero and not two"
run_cmd grep -c 'smtp.gmail.com' "$OUT"
assert_output_contains "1" "the smarthost from mail.conf reached the config"

# THE CONTROL THAT MATTERS. Valid YAML is not the bar: the defect this script
# already survived was an email_configs block nested inside telegram_configs,
# which parses fine and means nothing. Only Alertmanager's own parser knows.
run_cmd grep -n 'email_configs' "$OUT"
assert_output_contains "    email_configs" "the block sits at receiver level, not nested inside telegram_configs"

echo "== a half-filled mail.conf must not produce a half-filled receiver =="
printf 'HOST=smtp.gmail.com\nFROM=\nTO=\n' > "$MAILCONF"
run_setup
assert_rc 0 "a partial mail.conf still generates a config"
run_cmd grep -c 'email_configs' "$OUT"
assert_output_contains "0" "a partially configured channel is dropped, never half-substituted"
run_cmd grep -c '__' "$OUT"
assert_output_contains "0" "and leaves no placeholder behind either"

echo "== Alertmanager's own parser accepts both shapes =="
if command -v docker >/dev/null 2>&1; then
  for shape in unconfigured configured; do
    if [ "$shape" = "configured" ]; then
      printf 'HOST=smtp.gmail.com\nFROM=fixture@example.invalid\nTO=ops@example.invalid\n' > "$MAILCONF"
    else
      rm -f "$MAILCONF"
    fi
    run_setup
    assert_rc 0 "$shape: the script itself accepted the result"
    assert_output_contains "amtool: config accepted" \
      "$shape: Alertmanager's own parser accepted it, not just a YAML library"
  done
else
  _pass "SKIP: no docker, so amtool could not be asked"
fi

suite_summary

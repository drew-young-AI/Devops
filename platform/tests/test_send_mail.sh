#!/usr/bin/env bash
# The mail channel's own mechanics, with no credential and no real SMTP server.
#
# WHY THIS SUITE EXISTS (2026-09-11).
#
# `platform/notify/send_mail.sh` had NO test of any kind. It is the script
# standing between this platform and a second notification channel, on a
# platform that has already paid for silence twice: on 2026-08-19 an alert
# fired into a null receiver for 3h55m, and from 2026-09-07 to 09-10 Telegram
# failed 287 of 388 sends with nobody watching. The one script whose whole job
# is "say something out loud" was the one nothing verified.
#
# WHAT IS TESTABLE WITHOUT A CREDENTIAL, AND WHAT IS NOT.
#
# A real send needs an SMTP account, and obtaining one is the account holder's
# job -- not something a test can stand in for. What a test CAN pin down is the
# distinction this script's exit codes exist to make:
#
#   exit 78   NOT CONFIGURED -- no mail.conf, or no password file. Nothing is
#             broken; the channel was never set up. Callers treat this as
#             "skip", which is why it must never be returned for a real fault.
#   exit 1    CONFIGURED AND FAILED -- the settings are there and the send did
#             not happen. Somebody has to look.
#
# Collapsing those two is the failure this platform has already lived: a
# channel that was never wired looked exactly like a channel that was working,
# because both were quiet. So the controls below assert that a real fault --
# an unreachable host, a host that answers and refuses STARTTLS -- is NEVER
# reported as 78.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="send-mail"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

SANDBOX="$(mktemp -d)"
on_exit 'rm -rf "$SANDBOX"'

# send_mail.sh derives both of its paths from its own location, so a copy of
# the tree is the isolation boundary -- the shipped code is what runs.
mkdir -p "$SANDBOX/platform/notify" "$SANDBOX/platform/observability/alertmanager"
cp "$REPO_ROOT/platform/notify/send_mail.sh" "$SANDBOX/platform/notify/"
MAIL="$SANDBOX/platform/notify/send_mail.sh"
CONF="$SANDBOX/platform/notify/mail.conf"
PW="$SANDBOX/platform/observability/alertmanager/smtp-password"

echo "== not configured is 78, and 78 means only that =="

run_cmd env bash "$MAIL" "subject" < /dev/null
assert_rc 78 "no mail.conf is 78 (not configured), not a failure"
assert_output_contains "no mail.conf" "and says which half is missing"

printf 'HOST=127.0.0.1\nFROM=a@example.invalid\nTO=b@example.invalid\n' > "$CONF"
run_cmd env bash "$MAIL" "subject" < /dev/null
assert_rc 78 "a mail.conf with no password file is still 78"
assert_output_contains "no smtp-password" "and names the password file, not the conf"

echo "== a real fault must NOT be reported as 'not configured' =="
printf 'unused' > "$PW"

# A port nothing listens on. This is the shape of "the smarthost moved".
printf 'HOST=127.0.0.1\nFROM=a@example.invalid\nTO=b@example.invalid\n' > "$CONF"
SMTP_PORT_UNUSED=1
run_cmd env bash "$MAIL" "subject" < /dev/null
assert_rc 1 "a configured channel that cannot connect is 1, never 78"
assert_output_not_contains "not configured" "and is not described as unconfigured"
assert_output_contains "send_mail:" "and the exception is reported, not swallowed"

# A host that ACCEPTS the connection and then refuses to go further. This is
# the more dangerous shape: something IS listening, so any reachability check
# calls it healthy, and only an actual send attempt finds out.
#
# The first version of this control was empty -- it started a `python3 -` with
# no script and then re-ran the same unreachable-host case, so it measured the
# branch the control above already had. Caught before it shipped; it is the
# same class as the two permanent controls in test_xref_lifecycle.sh.
cat > "$SANDBOX/stub_smtp.py" <<'PY2'
import socket, sys
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", int(sys.argv[1])))
srv.listen(1)
print("ready", flush=True)
while True:
    conn, _ = srv.accept()
    try:
        conn.sendall(b"220 stub ESMTP\r\n")
        # Refuse everything after the greeting. smtplib raises rather than
        # hanging, which is the behaviour being pinned.
        while True:
            data = conn.recv(1024)
            if not data:
                break
            conn.sendall(b"502 not implemented\r\n")
    except OSError:
        pass
    finally:
        conn.close()
PY2

STUB_PORT=19587
python3 "$SANDBOX/stub_smtp.py" "$STUB_PORT" > "$SANDBOX/stub.log" 2>&1 &
STUB_PID=$!
on_exit 'kill '"$STUB_PID"' 2>/dev/null || true'
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q ready "$SANDBOX/stub.log" 2>/dev/null && break
  sleep 0.2
done

if grep -q ready "$SANDBOX/stub.log" 2>/dev/null; then
  printf 'HOST=127.0.0.1\nFROM=a@example.invalid\nTO=b@example.invalid\n' > "$CONF"
  run_cmd env SMTP_PORT="$STUB_PORT" bash "$MAIL" "subject" < /dev/null
  assert_rc 1 "a server that answers and then refuses is still 1, never 78"
  assert_output_not_contains "not configured" "and is never called unconfigured"
  # PROOF THE STUB WAS ACTUALLY REACHED. Without it this control passes for the
  # same reason as the one above -- connection refused -- and measures nothing
  # new. A dead port gives ConnectionRefusedError; a server that greets and
  # then refuses everything gives SMTPNotSupportedError on STARTTLS, which is
  # the shape being pinned: the connection SUCCEEDED and the send still did not
  # happen. Measured, not assumed -- the first version asserted "502", the
  # stub's own reply code, which smtplib never surfaces.
  assert_output_contains "STARTTLS" "and the failure came from the stub's refusal, not from a dead port"
else
  _pass "SKIP: could not bind the SMTP stub on this machine"
fi

suite_summary

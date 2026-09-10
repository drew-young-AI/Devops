#!/usr/bin/env bash
# The offline runbook must name things that exist, and nothing that needs a network.
#
# WHY THIS SUITE EXISTS (2026-09-09).
#
# docs/Runbook.md is written for the worst case: no agent, no internet, one
# person and this machine. That audience cannot check anything. If the runbook
# names a script that was renamed, the reader has no way to find out what it
# became -- they are stuck at the exact moment they have least help.
#
# This repository already knows what happens to hand-written operational prose:
# doc_freshness.py's second layer exists because two hand-maintained status
# pages went stale, and one of them told a manager the opposite of the truth.
# A runbook cannot be generated -- judgement is the whole content -- so the
# next best thing is that every FACT in it is checked: every command exists and
# is executable, every port it tells you to open is really published, and it
# contains no link that needs a network to follow.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="runbook"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

RUNBOOK="$REPO_ROOT/docs/Runbook.md"

echo "== the offline runbook names only things that exist =="

assert_file_exists "$RUNBOOK" "docs/Runbook.md exists"

# ---- every command it names is a real executable ---------------------------
#
# Pulled from anywhere in the file, because a reader does not care whether a
# path appeared in a fenced block or in a table.
MISSING=""
COUNT=0
for cmd in $(grep -oE '(platform|pilots)/[A-Za-z0-9_./-]+\.(sh|py)' "$RUNBOOK" \
             | sort -u); do
  COUNT=$((COUNT + 1))
  if [ ! -f "$REPO_ROOT/$cmd" ]; then
    MISSING="$MISSING $cmd(absent)"
  elif [ ! -x "$REPO_ROOT/$cmd" ]; then
    # A runbook that says "run this" about a file the reader cannot run is a
    # dead end with no error message.
    MISSING="$MISSING $cmd(not-executable)"
  fi
done
MISSING="$(printf '%s' "$MISSING" | sed 's/^ *//')"
assert_equals "" "$MISSING" "every script the runbook tells you to run exists and is executable"

# THE DENOMINATOR IS ASSERTED. A runbook that lost its command blocks would
# pass the loop above with zero iterations, which is the empty-scan shape this
# repository has now hit five times.
if [ "$COUNT" -ge 8 ]; then
  assert_equals "yes" "yes" "it names $COUNT runnable scripts, not zero"
else
  assert_equals "at least 8 scripts" "$COUNT scripts" \
    "a runbook naming almost nothing is refused, not reported clean"
fi

# ---- every other path it names exists too ----------------------------------
MISSING_PATH=""
for p in $(grep -oE '(docs|evidence)/[A-Za-z0-9_./-]+' "$RUNBOOK" | sed 's/[.,;)]*$//' \
           | sort -u); do
  case "$p" in */) continue ;; *[*?]*) continue ;; esac
  git -C "$REPO_ROOT" check-ignore -q "$p" 2>/dev/null && continue
  [ -e "$REPO_ROOT/$p" ] || MISSING_PATH="$MISSING_PATH $p"
done
MISSING_PATH="$(printf '%s' "$MISSING_PATH" | sed 's/^ *//')"
assert_equals "" "$MISSING_PATH" "every document the runbook points at still exists"

# ---- it must be usable with no network -------------------------------------
#
# The whole premise is "no internet". A runbook that says "see the wiki" fails
# its own audience. Localhost and the LAN hostname are not external.
EXTERNAL="$(grep -oE 'https?://[A-Za-z0-9._-]+' "$RUNBOOK" \
            | grep -vE '://(localhost|127\.0\.0\.1|mac\.local|ubu\.local)' \
            | sort -u | tr '\n' ' ' | sed 's/ *$//')"
assert_equals "" "$EXTERNAL" "the runbook has no link that needs a network to follow"

# ---- the ports it tells you to open are really published -------------------
#
# A port number in a runbook is a promise. These are read from the compose
# files rather than from a running Docker, so the check works on a machine
# where the platform is DOWN -- which is exactly when the runbook is read.
PORT_MISS=""
# CONTAINER-INTERNAL ADDRESSES ARE NOT A PROMISE ABOUT THE HOST.
#
# `VAULT_ADDR=http://127.0.0.1:8200` inside a `docker exec` is the address as
# seen from INSIDE the Vault container; 8200 is deliberately not published to
# the host. The first version of this rule flagged it as an unpublished port,
# which was the guard being right about the wrong line: the rule exists for
# ports the reader is told to OPEN, not for addresses passed to a process that
# is already inside the network namespace.
for port in $(grep -vE 'docker exec|VAULT_ADDR' "$RUNBOOK" \
              | grep -oE 'mac\.local:[0-9]+|127\.0\.0\.1:[0-9]+' \
              | grep -oE '[0-9]+$' | sort -u); do
  # The compose files write ports as "127.0.0.1:${HOST_PORT:-18090}:8080", so
  # the number is looked for inside the ports mapping rather than anchored to a
  # colon -- the first version of this check required `:18090:` and reported a
  # correctly published port as missing.
  grep -rqE "(^|[:{-])${port}[}:]" \
    "$REPO_ROOT/platform/observability/compose.yaml" \
    "$REPO_ROOT/platform/nginx/compose.yaml" \
    "$REPO_ROOT/pilots/station2-twin/compose.yaml" 2>/dev/null \
    || PORT_MISS="$PORT_MISS $port"
done
PORT_MISS="$(printf '%s' "$PORT_MISS" | sed 's/^ *//')"
assert_equals "" "$PORT_MISS" "every port the runbook sends you to is published by a compose file"

# ---- the four commands that matter are actually the four -------------------
#
# Not style policing. If `recover.sh` stops being the way to start the
# platform, this runbook becomes wrong in its first section, which is the one
# section someone reads under pressure.
run_cmd cat "$RUNBOOK"
assert_output_contains "platform/recover.sh" "the start path is named"
assert_output_contains "check_health.sh" "the deterministic verdict is named"
assert_output_contains "init_and_unseal.sh" "the post-reboot unseal is named"
assert_output_contains "監控自己壞了" \
  "and rc 3 is explained as MONITORING ITSELF IS BROKEN, not as a third kind of bad"
assert_output_contains "stage_report.py" \
  "completion is something you GENERATE, not a percentage typed into a document"

# ---- the control: the checks can go red ------------------------------------
#
# Without this the suite would pass on a runbook that had been emptied.
FIX="$(mktemp -t runbook_ctl.XXXXXX)"
cleanup() { rm -f "$FIX"; }
on_exit cleanup
printf 'run platform/does_not_exist.sh and see https://wiki.example.com/page\n' > "$FIX"
BAD_CMD="$(grep -oE '(platform|pilots)/[A-Za-z0-9_./-]+\.(sh|py)' "$FIX" | sort -u)"
BAD_EXT="$(grep -oE 'https?://[A-Za-z0-9._-]+' "$FIX" \
           | grep -vE '://(localhost|127\.0\.0\.1|mac\.local|ubu\.local)')"
[ -f "$REPO_ROOT/$BAD_CMD" ] \
  && _fail "the fixture names a missing script" "it exists" \
  || _pass "catches: a runbook naming a script that does not exist"
[ -n "$BAD_EXT" ] \
  && _pass "catches: a runbook link that needs a network" \
  || _fail "catches: a runbook link that needs a network" "found none"


# ---- every Vault path the runbook names must really be in Vault ------------
#
# WHY THIS IS THE ASSERTION THAT MATTERS IN THIS SUITE.
#
# A credential table is only worth having if following it WORKS. A row naming a
# Vault path that does not exist sends the reader to `No value found`, which is
# indistinguishable from "I typed it wrong" -- and they have no way to tell,
# because the table is the authority they were sent to.
#
# This is not hypothetical. `platform/notify/setup_mail.sh` reads
# `secret/devops/smtp`, and that secret has never existed. The board says
# "email declared but not connected"; the CAUSE was one missing row in Vault,
# and nothing in the repository connected those two facts until this check.
#
# Skipped, not failed, when Vault is down or sealed: the runbook is read most
# often when things are broken, and a suite that cannot run then is no use.
VAULT_INIT="$REPO_ROOT/platform/vault/.init-output.json"
if [ -f "$VAULT_INIT" ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^vault-vault-1$'; then
  VT="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['root_token'])" "$VAULT_INIT" 2>/dev/null)"
  MISSING_SECRET=""
  CHECKED=0
  for path in $(grep -oE 'secret/[a-z]+/[a-z0-9-]+' "$RUNBOOK" | sort -u); do
    # A path the runbook itself DECLARES missing is exempt, and the declaration
    # has to be in the document -- not in this test. `secret/devops/smtp` is
    # read by platform/notify/setup_mail.sh and has never existed; the runbook
    # says so, in the section that explains why the board reports email as
    # declared-but-not-connected. An exemption a reader can see is a note; an
    # exemption only the test knows about is a hole.
    if grep -q "$path" "$RUNBOOK" \
       && grep -A2 -B2 "$path" "$RUNBOOK" | grep -q '沒有這一筆\|不存在'; then
      continue
    fi
    CHECKED=$((CHECKED + 1))
    docker exec -e VAULT_TOKEN="$VT" -e VAULT_ADDR=http://127.0.0.1:8200 \
      vault-vault-1 vault kv get "$path" >/dev/null 2>&1 \
      || MISSING_SECRET="$MISSING_SECRET $path"
  done
  MISSING_SECRET="$(printf '%s' "$MISSING_SECRET" | sed 's/^ *//')"
  assert_equals "" "$MISSING_SECRET" \
    "every Vault path the credential table names really holds a secret ($CHECKED checked)"
  # The denominator again: a table that lost its Vault rows would pass a loop
  # that ran zero times.
  if [ "$CHECKED" -ge 3 ]; then
    assert_equals "yes" "yes" "the credential table names $CHECKED Vault paths, not zero"
  else
    assert_equals "at least 3 vault paths" "$CHECKED" \
      "a credential table naming almost no secrets is refused, not reported clean"
  fi
else
  echo "  SKIP  Vault is down or uninitialised -- the credential table is UNVERIFIED"
fi

# ---- the retrieval chain must actually be in the document ------------------
#
# The failure this replaces: the old section named the file holding the root
# token and stopped there. A reader following it hits `permission denied` with
# no next step. Naming a credential is not the same as making it reachable.
run_cmd cat "$RUNBOOK"
assert_output_contains "VAULT_ADDR" \
  "the runbook says how to address Vault, not just where the token file is"
assert_output_contains "vault kv get" \
  "and shows the command that actually reads a secret out"
assert_output_contains "gitignored" \
  "and says which credential files do NOT travel with a fresh clone"

# ---- one question, one file ------------------------------------------------
#
# The thing a first-time reader (or a weaker agent) actually gets stuck on is
# not a command, it is "where do I look this up". The map is asserted rather
# than trusted because a pointer that rots sends them somewhere that does not
# exist at the moment they have least context.
assert_output_contains "docs/Backlog.md" "the register of what is not done is named"
assert_output_contains "docs/decisions/index.md" "and the decision record index"
assert_output_contains "Session-Handover.md" "and the agent entry point"
assert_output_contains "ssh drew@ubu.local" \
  "the production node is reached by hostname; its IP has drifted three times"

suite_summary

#!/usr/bin/env bash
# The write-time redaction must actually redact, must not redact everything,
# and must not drift between the two log streams.
#
# WHY THIS SUITE EXISTS (2026-09-01).
#
# `docs/Backlog.md` §6 calls the current Alloy redaction "緩解措施，不是保證"
# -- a mitigation, not a guarantee -- and makes completing it a hard
# prerequisite before any real CYCH data enters this platform.
#
# Designing v2 needs a schema that does not exist yet, and guessing at it would
# be exactly the "force a data mapping without evidence" this platform forbids.
# What CAN be settled today, deterministically and with synthetic data only, is
# the question underneath: HOW MUCH DOES v1 ACTUALLY COVER?
#
# Until now, nothing asserted that it covers anything. `platform/observability/
# README.md` records "Verified end-to-end, by generating real PII" -- one
# manual check, once, in August. That is the same shape this repo already
# criticised in its own CI ("previously only verified manually, once, ad hoc"),
# and it means a regex could be broken today with nothing to say so.
#
# THE DRIFT GUARD IS THE POINT OF THIS FILE.
#
# config.alloy declares the same three rules TWICE -- once in
# `redact_internal`, once in `redact_restricted`. Two copies of a rule set is
# how they diverge, and the copy that would silently keep leaking is
# `restricted`: the MORE sensitive stream. This platform was bitten by exactly
# that shape earlier the same day, when the Kubernetes copy of the pilot turned
# out to hold the weaker credential model of the two while nothing compared
# them.
#
# ENGINE CAVEAT, STATED RATHER THAN GLOSSED.
#
# Alloy evaluates these with Go's RE2; this suite evaluates them with Python's
# `re`. The two agree on the subset used here (character classes, \b, {n,},
# alternation), so a match result is meaningful -- but it is not the production
# engine, and the check below for RE2-incompatible constructs exists because
# that is the one way the two could disagree catastrophically: a lookahead
# compiles in Python and is REJECTED by RE2, which would leave Alloy running
# with the stage silently absent.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="redaction"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== write-time redaction: does it redact, only what it should, in both streams? =="

CONFIG="$REPO_ROOT/platform/observability/alloy/config.alloy"
HELPER="$REPO_ROOT/platform/security/redaction_check.py"

assert_file_exists "$CONFIG" "alloy config is where the rules live"
assert_file_exists "$HELPER" "redaction_check.py exists"

SANDBOX="$(mktemp -d)"

run_cmd python3 "$HELPER" --config "$CONFIG" --json --out "$SANDBOX/red.json"
assert_rc 0 "reads the redaction rules out of the alloy config"

field() {  # <key>
  python3 -c "
import json,sys
print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$SANDBOX/red.json" "$1" 2>/dev/null || echo ERR
}

# --- the rules were actually found ------------------------------------------
#
# A parser that stops matching would otherwise report "0 rules, 0 drift, all
# clean" -- the vacuous pass this repo keeps finding in its own gates.
assert_equals "3" "$(field rules_per_block)" "finds all three declared rules"
assert_equals "2" "$(field blocks)" "finds both redaction blocks (internal and restricted)"

# --- drift between the two streams ------------------------------------------
assert_equals "True" "$(field blocks_identical)" \
  "both streams carry the SAME rules -- the restricted stream is not the weaker copy"

# --- RE2 compatibility ------------------------------------------------------
#
# Not theoretical. A lookahead or backreference compiles fine in Python, is
# rejected by RE2, and Alloy would then run without that stage -- redaction
# silently absent while the config still reads as if it were there.
assert_equals "0" "$(field re2_incompatible)" \
  "no rule uses a construct RE2 rejects (lookaround / backreference)"

# --- positive controls: each declared class must actually be caught ----------
#
# Synthetic values only. Every identifier below is invented for this test.
POS_FAIL="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(','.join(c['name'] for c in d['covered'] if not c['redacted']))" "$SANDBOX/red.json" 2>/dev/null || echo ERR)"
assert_equals "" "$POS_FAIL" "every class v1 claims to cover is redacted in synthetic input"

# --- negative control: benign text must survive untouched -------------------
#
# A redactor that redacts everything passes every positive control and destroys
# the logs. This is the assertion that stops "redact more" from ever being a
# safe default.
NEG_FAIL="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(','.join(c['name'] for c in d['benign'] if c['redacted']))" "$SANDBOX/red.json" 2>/dev/null || echo ERR)"
assert_equals "" "$NEG_FAIL" "does not cry wolf: ordinary log lines pass through unchanged"

# --- the honest number: what v1 does NOT cover ------------------------------
#
# Reported, not asserted against a threshold. Coverage is allowed to be partial
# -- the config says so in its own comment. What is NOT allowed is for the
# uncovered set to be unnamed, because "mitigation, not guarantee" in a comment
# is not something anyone can act on, and a list of named classes is.
UNCOVERED="$(field uncovered_count)"
TOTAL="$(field classes_total)"
if [ "$UNCOVERED" -ge 1 ] 2>/dev/null; then
  _pass "names what v1 does not cover ($UNCOVERED of $TOTAL classes), instead of leaving it to a comment"
else
  _fail "names what v1 does not cover" \
        "expected at least one uncovered class; got '$UNCOVERED' -- either v2 shipped without updating this suite, or the class list stopped being evaluated"
fi

echo ""
python3 "$HELPER" --config "$CONFIG" --out "$SANDBOX/red2.json" | sed 's/^/  /'
rm -rf "$SANDBOX"

suite_summary

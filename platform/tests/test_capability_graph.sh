#!/usr/bin/env bash
# Every capability must be findable by someone who starts at README.md.
#
# WHY THIS SUITE EXISTS (2026-09-02), AND WHY IT IS NOT test_doc_graph.sh AGAIN.
#
# test_doc_graph.sh asks whether every DOCUMENT is reachable. This asks whether
# every CAPABILITY is. They come apart, and the gap is where duplicate work
# gets built: a script that runs, is called by other scripts, and appears in no
# document anybody can reach. Nothing breaks, so nothing complains -- and the
# next person cannot find it, so they write a second one.
#
# First run found 9 of 89 in that state. Four of them were things a HUMAN is
# supposed to run: the rotation drill, the one-time rotation-check AppRole
# setup, the per-secret rotation policy setter, and the Alertmanager
# notification setup. Every one was referenced by other code, which is exactly
# the point: BEING CALLED IS NOT BEING DISCOVERABLE.
#
# INTERNAL exists because not every file is an entry point -- check_health.py
# is the engine behind check_health.sh and documenting it separately would be
# noise. The control below is the one that matters: an INTERNAL entry pointing
# at a front door that is ITSELF undocumented must fail, or INTERNAL becomes a
# place to hide things.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="capability-graph"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== every capability must be findable from the index, not just callable =="

CAP="$REPO_ROOT/platform/docs/capability_graph.py"
assert_file_exists "$CAP" "capability_graph.py exists"

run_cmd python3 "$CAP" --check
assert_rc 0 "every capability is described, or is internal to one that is"
assert_output_not_contains "ORPHAN CAPABILITIES" "no orphan capability in the repository"

REPORT="$(mktemp)"
python3 "$CAP" --json > "$REPORT" 2>/dev/null
COUNT="$(python3 -c "
import json,sys
print(json.load(open(sys.argv[1]))['capabilities'])" "$REPORT" 2>/dev/null || echo 0)"
if [ "$COUNT" -ge 60 ] 2>/dev/null; then
  _pass "the enumeration sees the whole platform ($COUNT capabilities)"
else
  _fail "the enumeration sees the whole platform" "only $COUNT found -- enumeration has broken"
fi
rm -f "$REPORT"

# --- the generated catalogue -------------------------------------------------
#
# The agent-facing view is DERIVED from the README tables, never hand-written.
# A hand-maintained capability list is a second index, and two indexes are a
# divergence problem: nobody updates both, so one starts lying while reading
# exactly like the one that does not.
CATALOG="$(mktemp -d)/capabilities.json"
CAPABILITY_CATALOG_OUT="$CATALOG" run_cmd python3 "$CAP" --catalog
assert_rc 0 "the catalogue generates"
assert_file_exists "$CATALOG" "the catalogue is written where asked"
BAD="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
caps=d['capabilities']
missing=[c['path'] for c in caps
         if c.get('described') and not (c.get('when') and c.get('what') and c.get('guarantee'))]
print(len(missing))" "$CATALOG" 2>/dev/null || echo ERR)"
assert_equals "0" "$BAD" "every described capability carries when / what / guarantee"
UNDESC="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for c in d['capabilities'] if not c.get('described')))" "$CATALOG" 2>/dev/null || echo ERR)"
INTERNAL_N="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for c in d['capabilities'] if c.get('internal_to')))" "$CATALOG" 2>/dev/null || echo ERR)"
assert_equals "$INTERNAL_N" "$UNDESC" \
  "the only entries without a description are the ones declared internal"
rm -rf "$(dirname "$CATALOG")"

# --- a sandbox: the controls never touch the real tree ----------------------
SANDBOX="$(mktemp -d)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT
mkdir -p "$SANDBOX/platform/docs" "$SANDBOX/platform/thing" "$SANDBOX/platform/tests"
cp "$CAP" "$SANDBOX/platform/docs/capability_graph.py"
git -C "$REPO_ROOT" init -q "$SANDBOX" 2>/dev/null
cat > "$SANDBOX/README.md" <<'EOF'
# sandbox
[the thing](platform/thing/README.md)
EOF
cat > "$SANDBOX/platform/thing/README.md" <<'EOF'
# thing

Rows, not prose: the rule under test is that a capability must be the SUBJECT
of a table row carrying at least three filled cells. The checker's own sandbox
copy is listed too, so it is not reported as a stray orphan and does not make
every control below fail for a reason unrelated to the control.

| 能力 | 何時 | 做什麼 | 保證 |
|---|---|---|---|
| platform/thing/front_door.sh | on demand | does the thing | it is the front door |
| platform/docs/capability_graph.py | ci | checks capabilities | the sandbox copy is described so it is not a stray orphan |
EOF
printf '#!/bin/sh\necho front\n' > "$SANDBOX/platform/thing/front_door.sh"
printf '#!/bin/sh\necho hidden\n' > "$SANDBOX/platform/thing/hidden.sh"
printf '#!/bin/sh\necho helper\n' > "$SANDBOX/platform/thing/helper.sh"
printf 'suites=(test_a.sh)\n' > "$SANDBOX/platform/tests/run_all.sh"
printf '#!/bin/sh\ntrue\n' > "$SANDBOX/platform/tests/test_a.sh"
git -C "$SANDBOX" add -A >/dev/null 2>&1

export CAPABILITY_GRAPH_ROOT="$SANDBOX"
export CAPABILITY_GRAPH_MIN=1

# --- control: an undescribed capability must be caught ----------------------
CAPABILITY_GRAPH_INTERNAL='{}' run_cmd python3 "$CAP" --check
assert_rc 1 "catches: a capability no reachable document names"
assert_output_contains "hidden.sh" "names the orphan capability"
assert_output_contains "Being called by another script is not discoverability" \
  "says why callable is not the same as findable"

# --- control: declaring it internal to a DOCUMENTED entry point passes ------
CAPABILITY_GRAPH_INTERNAL='{"platform/thing/hidden.sh":"platform/thing/front_door.sh","platform/thing/helper.sh":"platform/thing/front_door.sh"}' \
  run_cmd python3 "$CAP" --check
assert_rc 0 "accepts: an internal piece attached to a documented entry point"

# --- control: INTERNAL pointing at an UNDOCUMENTED entry must fail ----------
#
# The half that gives INTERNAL its teeth. Without it, anything could be hidden
# by pointing it at anything else.
CAPABILITY_GRAPH_INTERNAL='{"platform/thing/hidden.sh":"platform/thing/helper.sh","platform/thing/helper.sh":"platform/thing/hidden.sh"}' \
  run_cmd python3 "$CAP" --check
assert_rc 1 "catches: an internal piece whose named entry point is itself undocumented"
assert_output_contains "ENTRY POINT IS ALSO UNDOCUMENTED" "says which half of the declaration failed"

# --- control: a stale INTERNAL entry must be caught -------------------------
CAPABILITY_GRAPH_INTERNAL='{"platform/thing/hidden.sh":"platform/thing/front_door.sh","platform/thing/helper.sh":"platform/thing/front_door.sh","platform/thing/gone.sh":"platform/thing/front_door.sh"}' \
  run_cmd python3 "$CAP" --check
assert_rc 1 "catches: an internal declaration for a file that no longer exists"
assert_output_contains "gone.sh" "names the stale declaration"

# --- control: an unregistered test suite must be caught ---------------------
#
# A test suite nobody runs is the same defect wearing different clothes: it
# exists, it passes when invoked by hand, and it guards nothing.
printf '#!/bin/sh\ntrue\n' > "$SANDBOX/platform/tests/test_unregistered.sh"
git -C "$SANDBOX" add -A >/dev/null 2>&1
CAPABILITY_GRAPH_INTERNAL='{"platform/thing/hidden.sh":"platform/thing/front_door.sh","platform/thing/helper.sh":"platform/thing/front_door.sh"}' \
  run_cmd python3 "$CAP" --check
assert_rc 1 "catches: a test suite that run_all.sh does not run"
assert_output_contains "test_unregistered.sh" "names the unregistered suite"
git -C "$SANDBOX" rm -q --cached "platform/tests/test_unregistered.sh" >/dev/null 2>&1
rm -f "$SANDBOX/platform/tests/test_unregistered.sh"

# --- control: a bare basename shared by two capabilities is not enough ------
#
# There are four run.sh and two deploy.sh in the real repository. A document
# saying "run.sh" describes at most one of them, so accepting the bare basename
# would mark all four as covered -- a pass that reads exactly like a real one.
# The rule is the SHORTEST UNAMBIGUOUS suffix, so `mlops/run.sh` counts (it is
# how a person naturally writes it) and bare `run.sh` does not.
mkdir -p "$SANDBOX/platform/alpha" "$SANDBOX/platform/beta"
printf '#!/bin/sh
' > "$SANDBOX/platform/alpha/run.sh"
printf '#!/bin/sh
' > "$SANDBOX/platform/beta/run.sh"
cat > "$SANDBOX/platform/thing/README.md" <<'EOF'
# thing

| 能力 | 何時 | 做什麼 | 保證 |
|---|---|---|---|
| platform/thing/front_door.sh | on demand | does the thing | it is the front door |
| platform/docs/capability_graph.py | ci | checks capabilities | the sandbox copy is described so it is not a stray orphan |
| run.sh | on demand | ambiguous on purpose | two capabilities share this basename |
EOF
git -C "$SANDBOX" add -A >/dev/null 2>&1
CAPABILITY_GRAPH_INTERNAL='{"platform/thing/hidden.sh":"platform/thing/front_door.sh","platform/thing/helper.sh":"platform/thing/front_door.sh"}'   run_cmd python3 "$CAP" --check
assert_rc 1 "catches: a bare basename that two capabilities share describes neither"
assert_output_contains "alpha/run.sh" "names the first of the ambiguous pair"
assert_output_contains "beta/run.sh" "names the second, rather than silently covering both"

# --- control: the unambiguous suffix IS accepted ----------------------------
cat > "$SANDBOX/platform/thing/README.md" <<'EOF'
# thing

| 能力 | 何時 | 做什麼 | 保證 |
|---|---|---|---|
| platform/thing/front_door.sh | on demand | does the thing | it is the front door |
| platform/docs/capability_graph.py | ci | checks capabilities | the sandbox copy is described so it is not a stray orphan |
| alpha/run.sh | nightly | loads | named by its shortest unambiguous suffix |
| beta/run.sh | nightly | scores | named the same way |
EOF
git -C "$SANDBOX" add -A >/dev/null 2>&1
CAPABILITY_GRAPH_INTERNAL='{"platform/thing/hidden.sh":"platform/thing/front_door.sh","platform/thing/helper.sh":"platform/thing/front_door.sh"}'   run_cmd python3 "$CAP" --check
assert_rc 0 "accepts: the shortest unambiguous suffix, written the way a person would"

# --- control: the capability must be the row's SUBJECT, not a citation ------
#
# Without this, the generated decision index qualified as a description: its
# `rerun:` column names scripts, so loki_coverage.py was "described" by a row
# whose three columns were an ADR's title, status and date. The check passed
# and the generated catalogue published that as the capability's purpose --
# worse than failing, because it looked like an answer.
cat > "$SANDBOX/platform/thing/README.md" <<'EOF'
# thing

| 能力 | 何時 | 做什麼 | 保證 |
|---|---|---|---|
| platform/thing/front_door.sh | on demand | does the thing | it is the front door |
| platform/docs/capability_graph.py | ci | checks capabilities | the sandbox copy is described so it is not a stray orphan |
| alpha/run.sh | nightly | loads | named by its shortest unambiguous suffix |
| beta/run.sh | nightly | scores | named the same way |

| 決策 | 狀態 | 日期 | 重跑 |
|---|---|---|---|
| 某個決定 | 已採用 | 2026-09-02 | platform/thing/cited.sh |
EOF
printf '#!/bin/sh
' > "$SANDBOX/platform/thing/cited.sh"
git -C "$SANDBOX" add -A >/dev/null 2>&1
CAPABILITY_GRAPH_INTERNAL='{"platform/thing/hidden.sh":"platform/thing/front_door.sh","platform/thing/helper.sh":"platform/thing/front_door.sh"}'   run_cmd python3 "$CAP" --check
assert_rc 1 "catches: being cited in someone else's table row is not being described"
assert_output_contains "cited.sh" "names the capability that is only cited"
git -C "$SANDBOX" rm -q --cached "platform/thing/cited.sh" >/dev/null 2>&1
rm -f "$SANDBOX/platform/thing/cited.sh"
git -C "$SANDBOX" add -A >/dev/null 2>&1

# --- control: the floor must refuse a collapsed enumeration -----------------
CAPABILITY_GRAPH_MIN=999 CAPABILITY_GRAPH_INTERNAL='{}' run_cmd python3 "$CAP" --check
assert_rc 2 "refuses to report when the enumeration found fewer than the floor"
assert_output_contains "enumeration has broken" "says why a collapsed scan is refused rather than reported clean"

unset CAPABILITY_GRAPH_ROOT CAPABILITY_GRAPH_MIN
suite_summary

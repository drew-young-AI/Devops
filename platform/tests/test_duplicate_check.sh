#!/usr/bin/env bash
# Two pages must not claim the same subject.
#
# WHY THIS SUITE EXISTS (2026-09-02), AND WHY REACHABILITY DID NOT COVER IT.
#
# test_capability_graph.sh prevents ONE route to duplicate work: you cannot
# find the existing thing, so you build a second. It says nothing about the
# route that actually happened here, which is worse:
#
#     BOTH copies were documented. BOTH were reachable. They had drifted
#     completely apart, and each was shown to the same reader as current.
#
# Eight architecture diagrams existed twice -- a hand-drawn SVG set from
# 2026-08-25 embedded in the stage report, and a mermaid set built for the
# offline deck. Same eight subjects, independently written, near-zero shared
# label text; the older set still said "31 tests" and had no Kubernetes in it.
# Management would have seen one architecture on the board and a different one
# in the deck, both labelled current.
#
# The control below is that exact case: "DevOps 流程圖" and "DevOps 流程"
# normalise to one subject, so two pages carrying them is a finding.
#
# ON WHAT THIS DELIBERATELY DOES NOT DO: no similarity scoring. A threshold on
# prose similarity is a judgement call wearing a number, and it produces false
# positives -- which is how a check gets muted. Exact match after
# normalisation is weaker and every hit it reports is real.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="duplicate-check"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== two pages must not claim the same subject =="

DUP="$REPO_ROOT/platform/docs/duplicate_check.py"
assert_file_exists "$DUP" "duplicate_check.py exists"

run_cmd python3 "$DUP" --check
assert_rc 0 "no subject in this repository is claimed by two pages"
assert_output_contains "plates.offline.html" \
  "the generated/source pair is recorded as allowed rather than silently filtered"

# --- a sandbox ---------------------------------------------------------------
SANDBOX="$(mktemp -d)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT
mkdir -p "$SANDBOX/docs/diagrams" "$SANDBOX/docs/report" "$SANDBOX/platform/docs"
cp "$DUP" "$SANDBOX/platform/docs/duplicate_check.py"
git -C "$REPO_ROOT" init -q "$SANDBOX" 2>/dev/null
export DUPLICATE_CHECK_ROOT="$SANDBOX"
export DUPLICATE_CHECK_MIN=1

# --- control: THE case, reconstructed ---------------------------------------
printf '<html><head><title>DevOps 流程圖</title></head><body>old svg</body></html>\n' \
  > "$SANDBOX/docs/diagrams/devops-flow.html"
printf '<html><body><h2>DevOps 流程</h2>new mermaid</body></html>\n' \
  > "$SANDBOX/docs/report/plates.src.html"
git -C "$SANDBOX" add -A >/dev/null 2>&1
run_cmd python3 "$SANDBOX/platform/docs/duplicate_check.py" --check
assert_rc 1 "catches: 'DevOps 流程圖' and 'DevOps 流程' are one subject in two pages"
assert_output_contains "devops-flow.html" "names the first page"
assert_output_contains "plates.src.html" "names the second, so the pair is actionable"
assert_output_contains "eight diagrams diverged" "says which real failure the rule is made of"

# --- control: one subject in one page is not a finding ----------------------
rm -f "$SANDBOX/docs/diagrams/devops-flow.html"
git -C "$SANDBOX" add -A >/dev/null 2>&1
run_cmd python3 "$SANDBOX/platform/docs/duplicate_check.py" --check
assert_rc 0 "a subject appearing once is not a duplicate"

# --- control: a generic heading must not create findings --------------------
#
# Every decision record has a 決定 section. If those counted, the check would
# report dozens of duplicates on day one and be switched off by day two.
printf '<html><body><h2>決定</h2>a</body></html>\n' > "$SANDBOX/docs/a.html"
printf '<html><body><h2>決定</h2>b</body></html>\n' > "$SANDBOX/docs/b.html"
git -C "$SANDBOX" add -A >/dev/null 2>&1
run_cmd python3 "$SANDBOX/platform/docs/duplicate_check.py" --check
assert_rc 0 "a heading too generic to mean anything does not create a finding"

# --- control: an empty scan must be refused ---------------------------------
EMPTY="$(mktemp -d)"
git -C "$REPO_ROOT" init -q "$EMPTY" 2>/dev/null
DUPLICATE_CHECK_ROOT="$EMPTY" DUPLICATE_CHECK_MIN=5 \
  run_cmd python3 "$DUP" --check
assert_rc 2 "refuses to report on a scan that found nothing"
assert_output_contains "not a result" "says why an empty scan is refused rather than passed clean"
rm -rf "$EMPTY"

unset DUPLICATE_CHECK_ROOT DUPLICATE_CHECK_MIN
suite_summary

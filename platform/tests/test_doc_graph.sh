#!/usr/bin/env bash
# Every document must be reachable from README.md, or be a recorded exception.
#
# WHY THIS SUITE EXISTS (2026-09-02).
#
# README.md is declared to be the single index. That claim was never checked,
# and an audit found five documents nothing linked to -- including
# `platform/README.md`, which is the entry point for the whole platform
# directory and contained a SECOND, STALE copy of the capability index.
#
# Two indexes is not a duplication problem, it is a divergence problem. Nobody
# updates both, so one of them starts lying, and it reads exactly like the one
# that does not. The stale copy claimed "everything locally achievable is done,
# the only thing left is a public URL" -- written before Kubernetes, the second
# machine, the cross-architecture image guard, and everything after.
#
# The pattern behind all five orphans was the same and is worth naming: the
# tree existed IN PROSE and not IN LINKS. `platform/README.md` said "see
# nginx/README.md" in backticks; `pilots/README.md` never mentioned its own
# pilot as a link; ADR-0002 referenced `Spark-Design.md` four times, every one
# of them in backticks. A human cannot click a backtick and an agent cannot
# follow one.
#
# WHAT A DOCUMENT NOBODY LINKS TO ACTUALLY COSTS.
#
# Not tidiness. Nobody opens it, so nobody notices it going stale; and the next
# person writes a second copy because they could not find the first. That is
# how a repository ends up with two conflicting descriptions of one subsystem
# and no way to tell which is current -- which is exactly what was found.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="doc-graph"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== the documentation tree must have no orphans and no broken links =="

GRAPH="$REPO_ROOT/platform/docs/doc_graph.py"
assert_file_exists "$GRAPH" "doc_graph.py exists"

# --- the real tree ----------------------------------------------------------
run_cmd python3 "$GRAPH" --check
assert_rc 0 "every tracked document is reachable from README.md or explicitly exempt"

REPORT="$(mktemp)"
python3 "$GRAPH" --json > "$REPORT" 2>/dev/null

field() {
  python3 -c "
import json,sys
print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$REPORT" "$1" 2>/dev/null || echo ERR
}

assert_equals "[]" "$(field orphans)" "no orphaned documents"
assert_equals "[]" "$(field broken)" "no broken relative links"
assert_equals "[]" "$(field exempt_stale)" "no exemptions naming files that no longer exist"

# Reachability is only meaningful if the walk is actually walking. A parser
# that stopped finding links would report zero orphans out of three documents
# reached, which is a clean bill of health derived from having looked at almost
# nothing -- the same shape as the rotation sweep passing over an empty set.
REACHED="$(field reached)"
if [ "$REACHED" -ge 40 ] 2>/dev/null; then
  _pass "the walk reaches the whole tree ($REACHED documents), not a stub of it"
else
  _fail "the walk reaches the whole tree" "only $REACHED document(s) reached -- the link parser has broken"
fi
rm -f "$REPORT"

# --- control: an orphan must be caught -------------------------------------
#
# Synthetic, and restored in a trap so an interrupted run cannot leave a stray
# document in the repository.
ORPHAN="$REPO_ROOT/docs/_doc_graph_control.md"
cleanup_orphan() { rm -f "$ORPHAN"; }
trap cleanup_orphan EXIT
cat > "$ORPHAN" <<'EOF'
---
type: reference
title: 控制項
description: "Temporary file written by test_doc_graph.sh; deleted immediately."
tags:
  - test
---
Nothing links to this.
EOF
# git ls-files only reports tracked paths, so the control has to be staged for
# the walk to see it at all -- which is itself the point: an untracked scratch
# file is not part of the tree and must not be reported as an orphan.
git -C "$REPO_ROOT" add -N "docs/_doc_graph_control.md" >/dev/null 2>&1
run_cmd python3 "$GRAPH" --check
assert_rc 1 "catches: a tracked document that nothing links to"
assert_output_contains "_doc_graph_control.md" "names the orphan rather than just failing"
git -C "$REPO_ROOT" rm --cached --quiet "docs/_doc_graph_control.md" >/dev/null 2>&1
rm -f "$ORPHAN"
trap - EXIT

# --- control: a broken link must be caught ---------------------------------
#
# In a sandbox copy, because the alternative is editing README.md in place and
# relying on a restore -- and this suite runs alongside others that read it.
SANDBOX="$(mktemp -d)"
mkdir -p "$SANDBOX/platform/docs" "$SANDBOX/docs"
cp "$GRAPH" "$SANDBOX/platform/docs/doc_graph.py"
git -C "$REPO_ROOT" init -q "$SANDBOX" 2>/dev/null
cat > "$SANDBOX/README.md" <<'EOF'
# sandbox
[a real one](docs/real.md)
[a dead one](docs/gone.md)
EOF
printf '# real\n' > "$SANDBOX/docs/real.md"
git -C "$SANDBOX" add -A >/dev/null 2>&1
# MIN_REACHED would refuse this tiny tree, which is correct for the real repo
# and unhelpful here, so the control lowers the floor rather than deleting it.
sed -i '' 's/^MIN_REACHED = .*/MIN_REACHED = 1/' "$SANDBOX/platform/docs/doc_graph.py" 2>/dev/null \
  || sed -i 's/^MIN_REACHED = .*/MIN_REACHED = 1/' "$SANDBOX/platform/docs/doc_graph.py"
run_cmd python3 "$SANDBOX/platform/docs/doc_graph.py" --check
assert_rc 1 "catches: a link whose target does not exist"
assert_output_contains "gone.md" "names the dead link"
rm -rf "$SANDBOX"

# --- control: the floor must refuse a stub walk ----------------------------
STUB="$(mktemp -d)"
mkdir -p "$STUB/platform/docs"
cp "$GRAPH" "$STUB/platform/docs/doc_graph.py"
git -C "$REPO_ROOT" init -q "$STUB" 2>/dev/null
printf '# alone\n' > "$STUB/README.md"
git -C "$STUB" add -A >/dev/null 2>&1
run_cmd python3 "$STUB/platform/docs/doc_graph.py" --check
assert_rc 2 "refuses to report on a walk that reached almost nothing"
assert_output_contains "visited almost nothing" "says why a stub walk is refused rather than reported clean"
rm -rf "$STUB"

suite_summary

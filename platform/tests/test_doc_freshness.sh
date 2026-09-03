#!/usr/bin/env bash
# Every rendered page under docs/ must be generated, or must say why it is
# allowed to be maintained by hand.
#
# WHY THIS SUITE EXISTS (2026-09-02).
#
# test_doc_graph.sh proves a document can be REACHED. That is a real property
# and it found five orphans. It is not the property that hurt.
#
# `docs/System-State.html` was reachable, prominently linked as the page to read
# first, and wrong: it said data governance and process visualisation were
# "almost empty" nine days after both were built. A second, `docs/Platform-Report.html`,
# still claimed 6,172,492 fact rows (6,503,799) and "31 tests". Both would have
# passed a reachability check with full marks.
#
# The guard is deliberately not "no hand-written pages" -- a dated milestone
# SHOULD be frozen, and the mermaid source of the eight plates is hand-authored
# by design. It is: declare which one it is. A page that is neither generated
# nor a recorded curated page fails, so the third System-State.html cannot be
# added silently. The sentence you have to write to declare one is usually the
# moment you notice what you are about to build.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="doc-freshness"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== every rendered page must be generated, or say why it is hand-maintained =="

FRESH="$REPO_ROOT/platform/docs/doc_freshness.py"
assert_file_exists "$FRESH" "doc_freshness.py exists"

# --- the real repository ----------------------------------------------------
run_cmd python3 "$FRESH" --check
assert_rc 0 "every rendered page is declared, and every generator's check passes"
assert_output_contains "GENERATED" "the report distinguishes generated pages from curated ones"
assert_output_not_contains "UNDECLARED" "no undeclared rendered page in the repository"

# --- a sandbox, so the controls never touch the real docs tree --------------
SANDBOX="$(mktemp -d)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT
mkdir -p "$SANDBOX/docs"
git -C "$REPO_ROOT" init -q "$SANDBOX" 2>/dev/null
printf '<html><body>kept</body></html>\n' > "$SANDBOX/docs/keep.html"
printf '<html><body>rogue</body></html>\n' > "$SANDBOX/docs/rogue.html"
git -C "$SANDBOX" add -A >/dev/null 2>&1

# The faults are injected as DATA through the environment rather than by
# editing doc_freshness.py and relying on a restore -- an interrupted run
# cannot then leave the real registry mangled.
export DOC_FRESHNESS_ROOT="$SANDBOX"
export DOC_FRESHNESS_MIN_PAGES=1

# --- control: an undeclared page must be caught -----------------------------
DOC_FRESHNESS_GENERATED='{}' \
DOC_FRESHNESS_CURATED='{"docs/keep.html":"declared"}' \
  run_cmd python3 "$FRESH" --check
assert_rc 1 "catches: a rendered page that is neither generated nor declared curated"
assert_output_contains "rogue.html" "names the undeclared page"
assert_output_contains "System-State" "says which past failure the rule is made of"

# --- control: both declared must pass --------------------------------------
DOC_FRESHNESS_GENERATED='{}' \
DOC_FRESHNESS_CURATED='{"docs/keep.html":"declared","docs/rogue.html":"declared"}' \
  run_cmd python3 "$FRESH" --check
assert_rc 0 "accepts: every page declared curated with a reason"

# --- control: a declaration naming a deleted file must be caught ------------
DOC_FRESHNESS_GENERATED='{}' \
DOC_FRESHNESS_CURATED='{"docs/keep.html":"d","docs/rogue.html":"d","docs/gone.html":"d"}' \
  run_cmd python3 "$FRESH" --check
assert_rc 1 "catches: a declaration for a file that no longer exists"
assert_output_contains "gone.html" "names the stale declaration"

# --- control: a generator whose check fails must be caught ------------------
#
# The distinction that matters: the page is DECLARED generated, so the earlier
# controls all pass -- what fails is the proof that it still matches its
# source. A page can be correctly registered and still have drifted.
DOC_FRESHNESS_GENERATED='{"docs/keep.html":["false"]}' \
DOC_FRESHNESS_CURATED='{"docs/rogue.html":"declared"}' \
  run_cmd python3 "$FRESH" --check
assert_rc 1 "catches: a generated page whose generator check does not pass"
assert_output_contains "CHECK FAILED" "says the generator failed rather than only that something is wrong"

# --- control: an empty scan must be refused, not reported clean -------------
EMPTY="$(mktemp -d)"
git -C "$REPO_ROOT" init -q "$EMPTY" 2>/dev/null
DOC_FRESHNESS_ROOT="$EMPTY" DOC_FRESHNESS_MIN_PAGES=2 \
DOC_FRESHNESS_GENERATED='{}' DOC_FRESHNESS_CURATED='{}' \
  run_cmd python3 "$FRESH" --check
assert_rc 2 "refuses to report on a scan that found no pages at all"
assert_output_contains "not seeing the tree" "says why an empty scan is refused rather than passed"
rm -rf "$EMPTY"

unset DOC_FRESHNESS_ROOT DOC_FRESHNESS_MIN_PAGES
suite_summary

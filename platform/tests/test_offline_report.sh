#!/usr/bin/env bash
# The offline report must actually work offline, and must not drift from the
# published one.
#
# WHY THIS SUITE EXISTS (2026-09-02).
#
# The eight-plate report existed only as a published Artifact. Two problems:
# it needs the network to open, and -- worse -- the working file lived in a
# session scratch directory and was gone the next day, leaving the published
# page as the only surviving copy. A deliverable whose only copy is somewhere
# you do not control is a bookmark, not a deliverable.
#
# So docs/report/plates.src.html is now the source, and build.sh generates the
# offline variant from it. This suite guards the two claims that make that
# arrangement worth anything:
#
#   1. OFFLINE MEANS OFFLINE. Zero external references -- not "we removed the
#      obvious one". A page that hangs on a font request and then silently
#      falls back still opens; a page that pulls its diagram library from a CDN
#      shows eight empty boxes. Both are discovered in the meeting room.
#
#   2. THE TWO VARIANTS CARRY THE SAME EIGHT DIAGRAMS. Not "someone remembered
#      to update both" -- checked, because two hand-edited files drift inside a
#      week and the drift is invisible until someone compares them side by side,
#      which nobody does.
#
# WHAT THIS SUITE CANNOT DO, STATED PLAINLY.
#
# It does not prove the diagrams RENDER. That needs a browser, and it was done
# by hand on 2026-09-02 against a real Chrome -- which is how the three defects
# below were found, none of which any static check would have caught:
#
#   * `<br/>` inside `<pre class="mermaid">` is a real HTML element, so
#     `pre.textContent` dropped it and mermaid never saw the line break.
#   * Eight concurrent `mermaid.render()` calls share one off-screen measuring
#     element and size each other's labels.
#   * `<pre>` is monospace by UA default. mermaid measured labels in a
#     sans-serif temp element on <body> and rendered them into that monospace
#     <pre>, so every label was wider than the box computed for it and clipped
#     at the border -- silently, with a clean console.
#
# All three produced a page where every diagram appeared and nothing errored.
# That is the reason the rendering check is a human one and is named as such
# rather than assumed away.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="offline-report"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== the offline report must open with no network, and match the source =="

REPORT="$REPO_ROOT/docs/report"
SRC="$REPORT/plates.src.html"
OUT="$REPORT/plates.offline.html"
BUILD="$REPORT/build.sh"

assert_file_exists "$SRC" "the source exists (docs/report/plates.src.html)"
assert_file_exists "$OUT" "the generated offline page exists"
assert_file_exists "$REPORT/assets/mermaid.min.js" "the diagram library is vendored, not fetched"

# --- 1. offline means offline -----------------------------------------------
#
# Any http(s) URL in a src or href is a request the browser will make. In a
# meeting room with no network that is a hang followed by a silent degradation,
# which is the worst of both: it still opens, and it is wrong.
EXTERNAL="$(grep -oE '(src|href)="https?://[^"]+"' "$OUT" 2>/dev/null | head -5 | tr '\n' ' ')"
assert_equals "" "$EXTERNAL" "the offline page makes no external requests"

# The library must be referenced by a RELATIVE path. An absolute file:// path
# would work on this machine and nowhere else, which is the failure that only
# shows up after the folder is copied to somebody's laptop.
if grep -q 'src="\./assets/mermaid\.min\.js"' "$OUT"; then
  _pass "the diagram library is loaded by relative path (the folder is portable)"
else
  _fail "the diagram library is loaded by relative path" "expected src=\"./assets/mermaid.min.js\""
fi

# --- 2. the three rendering defects must stay fixed -------------------------
#
# Each of these is a one-line property standing in for a defect that took a
# browser to find. They cannot prove the page renders; they can prove nobody
# quietly undid the fix.
if grep -q '&lt;br/&gt;' "$OUT"; then
  _pass "diagram sources are escaped, so <br/> survives pre.textContent"
else
  _fail "diagram sources are escaped, so <br/> survives pre.textContent" \
        "no escaped <br/> found -- line breaks will be dropped before mermaid sees them"
fi

if grep -q 'pre.mermaid { font-family: inherit; }' "$OUT"; then
  _pass "the <pre> monospace default is reset (labels are measured and drawn in one font)"
else
  _fail "the <pre> monospace default is reset" \
        "without this, mermaid measures in sans and draws in mono, and every label clips"
fi

# `Promise.all(` -- the CALL, not the word. The first version of this check
# grepped for the bare string and failed against the comment in build.sh that
# explains why Promise.all is not used. A guard that fires on its own
# documentation trains people to ignore it.
if grep -q 'Promise\.all(' "$OUT"; then
  _fail "diagrams render one at a time" \
        "a Promise.all() call was found -- concurrent renders share mermaid's measuring element"
else
  _pass "diagrams render one at a time (concurrent renders mis-size each other)"
fi

# --- 3. the two variants must carry the same diagrams -----------------------
#
# Compared by CONTENT, not by count. Eight diagrams where one silently became a
# copy of another would pass a count check and be wrong in the way that matters.
# Counted after stripping <style> and <script>, because prose about the markup
# is not the markup. The first version counted nine diagrams in an eight-diagram
# file: the ninth was a sentence in a CSS comment mentioning the tag it fixes.
count_plates() {  # <file>
  python3 - "$1" <<'PYCOUNT'
import re
import sys
doc = open(sys.argv[1]).read()
doc = re.sub(r"<style>[\s\S]*?</style>", "", doc)
doc = re.sub(r"<script[\s\S]*?</script>", "", doc)
print(len(re.findall(r'<pre class="mermaid">', doc)))
PYCOUNT
}
SRC_N="$(count_plates "$SRC")"
OUT_N="$(count_plates "$OUT")"
assert_equals "8" "$SRC_N" "the source still holds eight diagrams"
assert_equals "$SRC_N" "$OUT_N" "the offline page holds the same number"

SAME="$(python3 - "$SRC" "$OUT" <<'PY'
import html
import re
import sys


def plates(path):
    doc = open(path).read()
    # Same reason as the count above: strip prose before reading markup.
    doc = re.sub(r"<style>[\s\S]*?</style>", "", doc)
    doc = re.sub(r"<script[\s\S]*?</script>", "", doc)
    out = []
    for body in re.findall(r'<pre class="mermaid">([\s\S]*?)</pre>', doc):
        # The offline copy is escaped on purpose (see build.sh step 1b), so
        # unescape before comparing -- otherwise this check would compare the
        # transport encoding instead of the diagram.
        text = html.unescape(body)
        # The offline build retargets the font stack; that is a deliberate
        # difference, not drift, so it is normalised out rather than allowed to
        # fail the comparison every time.
        text = re.sub(r'"fontFamily":"[^"]*"', '"fontFamily":"X"', text)
        out.append(" ".join(text.split()))
    return out


a, b = plates(sys.argv[1]), plates(sys.argv[2])
if a == b:
    print("same")
else:
    diff = [i + 1 for i, (x, y) in enumerate(zip(a, b)) if x != y]
    print("differ:%s" % (diff or "length %d vs %d" % (len(a), len(b))))
PY
)"
assert_equals "same" "$SAME" "every diagram in the offline page is the one in the source"

# --- 4. the generated file must be current ----------------------------------
#
# A committed output that no longer matches what the source generates is the
# same class of problem as a stale index: it looks authoritative and is not.
run_cmd bash "$BUILD" --check
assert_rc 0 "the committed offline page is what the current source generates"

# --- 5. the build must refuse to lose a plate -------------------------------
#
# The control. A build that cheerfully emits seven diagrams when the source has
# seven produces a report that looks complete, and the missing plate is
# invisible by definition.
SANDBOX="$(mktemp -d)"
mkdir -p "$SANDBOX/assets"
cp "$REPORT/build.sh" "$SANDBOX/build.sh"
: > "$SANDBOX/assets/mermaid.min.js"
python3 - "$SRC" "$SANDBOX/plates.src.html" <<'PY'
import re
import sys
doc = open(sys.argv[1]).read()
# Remove exactly one diagram, leaving everything else intact.
doc = re.sub(r'<pre class="mermaid">[\s\S]*?</pre>', "", doc, count=1)
open(sys.argv[2], "w").write(doc)
PY
run_cmd bash "$SANDBOX/build.sh"
assert_rc 1 "catches: a source that has quietly lost a diagram"
assert_output_contains "invisible by definition" "says why a short build is refused rather than shipped"
rm -rf "$SANDBOX"

suite_summary

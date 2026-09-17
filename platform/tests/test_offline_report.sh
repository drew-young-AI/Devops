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

# --- 6. the plates must still be a projection of dag.py ---------------------
#
# WHY (2026-09-17). The plates claimed "every box is a board node" from the day
# they were drawn, and nothing checked it. Fifteen days later plate 02 still
# drew CI, Trivy, Registry and production-like -- four nodes retired on 09-10 --
# and eighteen live nodes appeared on no plate at all. The page opened, every
# diagram rendered, and it described a platform that no longer existed, to the
# reader least able to notice.
#
# The convention that makes this checkable: a mermaid node whose id starts with
# a LOWERCASE letter is a dag.py node, and its label's first line is that node's
# label verbatim. Uppercase ids are context (a database, a machine, a reader)
# and are free. So:
#   a. every dag node appears on some plate, labelled as the board labels it
#   b. no lowercase id is anything other than a live dag node (retired names fail)
#   c. every dag edge is drawn somewhere
#   d. no arrow between two dag nodes asserts a dependency dag.py does not have
plates_vs_dag() {  # <plates.src.html> -> prints "ok" or the violations
  python3 - "$1" "$REPO_ROOT/platform/statusdag/dag.py" <<'PYDAG'
import importlib.util
import re
import sys

spec = importlib.util.spec_from_file_location("dag", sys.argv[2])
dag = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dag)
labels = {n[0]: n[1] for n in dag.NODES}
edges = {tuple(e) for e in dag.EDGES}

doc = open(sys.argv[1], encoding="utf-8").read()
doc = re.sub(r"<style>[\s\S]*?</style>", "", doc)
doc = re.sub(r"<script[\s\S]*?</script>", "", doc)
SHAPE = r'([A-Za-z_]\w*)\s*(?:\[\(|\(\[|\(\(|\{\{|\[|\()\s*"([^"]*)"'
ARROW = r"\s*(?:-->|-\.->|==>|---|-\.-)\s*(?:\|\"[^\"]*\"\|\s*)?"
seen, drawn, bad = {}, set(), []
for body in re.findall(r'<pre class="mermaid">([\s\S]*?)</pre>', doc):
    for line in body.splitlines():
        s = line.strip()
        if not s or s.startswith(("%%", "classDef", "class ", "style ", "subgraph", "direction", "end", "flowchart")):
            continue
        for nid, label in re.findall(SHAPE, s):
            seen.setdefault(nid, set()).add(label.split("<br/>")[0])
        flat = re.sub(r'(?:\[\(|\(\[|\(\(|\{\{|\[|\()\s*"[^"]*"\s*(?:\)\]|\]\)|\)\)|\}\}|\]|\))', "", s)
        ids = [re.match(r"\s*([A-Za-z_]\w*)", seg).group(1)
               for seg in re.split(ARROW, flat) if re.match(r"\s*[A-Za-z_]", seg)]
        if re.search(ARROW, flat) and len(ids) >= 2:
            for a, b in zip(ids, ids[1:]):
                if a[0].islower() and b[0].islower():
                    drawn.add((a, b))
for nid, ls in sorted(seen.items()):
    if not nid[0].islower():
        continue
    if nid not in labels:
        bad.append("not a live dag node: %s" % nid)
    elif ls != {labels[nid]}:
        bad.append("label drift: %s drawn as %s, board says %s" % (nid, sorted(ls), labels[nid]))
bad += ["missing node: %s (%s)" % (n, l) for n, l in labels.items() if n not in seen]
bad += ["missing edge: %s -> %s" % e for e in sorted(edges - drawn)]
bad += ["invented edge: %s -> %s" % e for e in sorted(drawn - edges)]
print("\n".join(bad) if bad else "ok")
PYDAG
}
assert_equals "ok" "$(plates_vs_dag "$SRC")" \
  "every dag node and edge is on the plates, and nothing retired or invented is"

# The controls: a guard never shown to fail is indistinguishable from one that
# cannot. Each mutation is one the real drift actually took.
CTRL="$(mktemp -d)"
# Each mutation must actually change the file. The first version used literal
# string replacement; the plates were re-laid-out the same day, one pattern
# stopped matching, and that control silently became "run the check on the
# unmodified source" -- which passes, and so reported the guard as broken
# only because the assertion happened to expect a failure. A control that can
# be a no-op is the thing it exists to catch.
run_cmd python3 - "$SRC" "$CTRL" <<'PY'
import re
import sys
src, d = sys.argv[1], sys.argv[2]
doc = open(src, encoding="utf-8").read()
inject = "\n  trivy[\"映像漏洞掃描\"]\n"
mutations = {
    "retired": re.subn(r'(<pre class="mermaid">\n%%[^\n]*\nflowchart [A-Z]{2})', lambda m: m.group(1) + inject, doc, count=1),
    "lostedge": re.subn(r"\bbackup(\[\"[^\"]*\"\])?\s*-->\s*(\|\"[^\"]*\"\|\s*)?restore\b", "backup ~~~ restore", doc),
    "invented": re.subn(r"(<pre class=\"mermaid\">\n%%[^\n]*\nflowchart [A-Z]{2})", r'\1' + "\n  nginx[\"NGINX 入口\"] --> grafana[\"Grafana 檢視\"]\n", doc, count=1),
}
for name, (text, n) in mutations.items():
    if n == 0:
        print("MUTATION DID NOT APPLY: %s" % name)
        sys.exit(1)
    open("%s/%s.html" % (d, name), "w", encoding="utf-8").write(text)
PY
assert_rc 0 "every control mutation actually changed the source (none is a no-op)"
run_cmd plates_vs_dag "$CTRL/retired.html"
assert_output_contains "not a live dag node: trivy" "catches: a plate still drawing a retired node"
run_cmd plates_vs_dag "$CTRL/lostedge.html"
assert_output_contains "missing edge: backup -> restore" "catches: a dag edge no plate draws"
run_cmd plates_vs_dag "$CTRL/invented.html"
assert_output_contains "invented edge: nginx -> grafana" "catches: an arrow asserting a dependency dag.py does not have"
rm -rf "$CTRL"

# The Artifact host injects its own mermaid runtime into the page it serves.
# Reading the published page back and saving it as the source carried that
# block into git on 2026-09-02, and build.sh copied it into the offline page:
# a second renderer that calls mermaid.render() for every diagram at once --
# exactly defect #2 above -- in the host's palette instead of this one.
INJECTED="$(grep -l 'claude-mermaid-runtime\|/_runtime/mermaid' "$SRC" "$OUT" 2>/dev/null | tr '\n' ' ')"
assert_equals "" "$INJECTED" "no host-injected mermaid runtime in the source or the offline page"

# --- 7. the LAN route serves the built page and NOT the source --------------
#
# Conditional on the status vhost being up, like the README's own URL checks:
# on a machine without the platform this can only fail structurally, and an
# assertion that cannot fail for a real reason trains people to ignore the
# channel it reports on.
#
# WHY THE 404 MATTERS AS MUCH AS THE 200. docs/report/ holds two near-identical
# HTML files one directory apart, and only one of them draws anything -- the
# source has no renderer and opens as eight empty boxes. Routing the directory
# instead of an allowlist would put both a click apart from each other, in
# front of the person the report is for.
BOARD="$(scutil --get LocalHostName 2>/dev/null || true)"
if [ -n "$BOARD" ] && curl -s -m 4 -o /dev/null "http://${BOARD}.local:18085/healthz" 2>/dev/null; then
  code() { curl -4 -s -o /dev/null -w '%{http_code}' -m 8 "http://${BOARD}.local:18085$1" 2>/dev/null; }
  assert_equals "200" "$(code /report/plates.offline.html)" \
    "the built page is reachable on the status vhost"
  assert_equals "200" "$(code /report/assets/mermaid.min.js)" \
    "so is its diagram library (a 200 on the HTML alone renders nothing)"
  assert_equals "404" "$(code /report/plates.src.html)" \
    "the SOURCE stays unrouted -- it draws nothing and must not be presentable"
  assert_equals "404" "$(code /report/build.sh)" \
    "the build script stays unrouted"
else
  echo "  SKIP  status vhost not reachable -- the LAN route is UNVERIFIED"
fi

suite_summary

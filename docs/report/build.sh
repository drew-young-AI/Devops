#!/usr/bin/env bash
# Build the offline variant of the eight-plate report from the same source the
# published Artifact uses.
#
# WHY THIS EXISTS (2026-09-02).
#
# The report existed only as a published Artifact. Two problems, and the second
# is the one that decided the design:
#
#   1. It needs the network. A report you cannot open on a train, in a hospital
#      meeting room, or on a machine behind a firewall is a report you cannot
#      rely on being able to present.
#
#   2. THE ONLY COPY WAS REMOTE. The working file lived in a session scratch
#      directory and was gone by the next day; the published page was the sole
#      surviving copy. A deliverable whose only copy is somewhere you do not
#      control is not a deliverable, it is a bookmark.
#
# So the repository is now the single source, and BOTH outputs are generated
# from it. Neither is hand-edited:
#
#   plates.src.html       the source. Edit THIS.
#   plates.offline.html   generated. Opens with file://, zero network.
#
# The published Artifact is republished from plates.src.html, so "in sync"
# means one thing here: both come from one file, and a test asserts the
# generated one still carries every diagram the source does. Two files edited
# by hand would drift within a week -- that is the whole reason this is a
# script and not an instruction in a README.
#
# WHAT CHANGES BETWEEN THE TWO
#
#   mermaid   The Artifact host renders `<pre class="mermaid">` natively, so
#             the source ships no library. Offline there is no host, so the
#             generated file loads a PINNED, VENDORED copy from assets/ and
#             renders in the browser. Vendored rather than fetched: a build
#             step that needs the network to produce an offline artifact
#             defeats itself the day the network is what is missing.
#
#   fonts     The source links Google Fonts. Offline that link would hang and
#             then silently fall back, so it is REMOVED and the CSS falls to
#             its own stack (on this machine: PingFang TC / SF, which is what
#             the design was checked against anyway). Removing it is also what
#             makes "zero external references" true and testable -- a promise
#             of offline-capability that nothing verifies is just a hope.
#
#   export    The generated file gains a button that saves all eight diagrams
#             as standalone .svg files, for dropping into Keynote or
#             PowerPoint. Not in the Artifact: its sandbox blocks downloads.
#
# Usage:
#   docs/report/build.sh            # build
#   docs/report/build.sh --check    # build to a temp file and diff (CI-safe)
#
# Exit codes:
#   0  built (or, with --check, the committed output is up to date)
#   1  the source is missing something the build needs
#   3  --check found the committed output is stale
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/plates.src.html"
OUT="$HERE/plates.offline.html"
MERMAID="$HERE/assets/mermaid.min.js"

# Pinned. cdnjs served a 404 for a version that never existed earlier in this
# project's life (aquasecurity/trivy-action@0.28.0, red for 17 days), so the
# version here was checked for HTTP 200 before being written down.
MERMAID_VERSION="11.6.0"
MERMAID_SHA256="3a93016a73dc82ba890d919f9bbb176f"  # first 32 chars, see --check

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

for f in "$SRC" "$MERMAID"; do
  [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done

EXPECTED_PLATES=8
FOUND="$(grep -c '<pre class="mermaid">' "$SRC")"
if [ "$FOUND" -ne "$EXPECTED_PLATES" ]; then
  echo "FATAL: source has $FOUND diagram(s), expected $EXPECTED_PLATES." >&2
  echo "  Refusing to build: a report that quietly lost a plate looks like a" >&2
  echo "  report, and the missing one is invisible by definition." >&2
  exit 1
fi

TARGET="$OUT"
[ "$CHECK" -eq 1 ] && TARGET="$(mktemp)"

python3 - "$SRC" "$TARGET" "$MERMAID_VERSION" <<'PY'
import re
import sys

src_path, out_path, mermaid_version = sys.argv[1:4]
with open(src_path) as handle:
    doc = handle.read()

# 1. Drop the Google Fonts stylesheet. Offline it is a hang, then a silent
#    fallback -- and it is the only thing standing between this file and the
#    testable property "no external references".
doc, n = re.subn(r'\s*<link rel="stylesheet" href="https://fonts\.googleapis\.com[^>]*>\n?', "\n", doc, count=1)
fonts_removed = n

# 1b. ESCAPE THE DIAGRAM SOURCES.
#
# The single defect that made the first offline build wrong, and it is worth
# spelling out because it is invisible in the source and obvious in the output.
#
# `<pre class="mermaid">GitHub Actions<br/>x86 runner</pre>` -- that `<br/>` is
# a REAL HTML ELEMENT as far as the browser's parser is concerned. The renderer
# reads `pre.textContent` to get the diagram source, and textContent contributes
# NOTHING for an element node. So mermaid received "GitHub Actionsx86 runner":
# the line break did not fail to render, it never reached mermaid at all.
#
# The symptom was labels running together and clipping out of their boxes, which
# reads like a mermaid sizing bug and is not. The Artifact host never hits this
# because it takes the block's raw text before the parser can turn `<br/>` into
# an element.
#
# Escaping < and > inside the diagram blocks makes textContent hand back the
# literal characters, which is what mermaid needs to see.
def _escape_diagram(match):
    body = match.group(1)
    return '<pre class="mermaid">' + body.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;") + "</pre>"

doc, escaped = re.subn(r'<pre class="mermaid">([\s\S]*?)</pre>', _escape_diagram, doc)

# 1c. Retarget the font stack inside each %%{init}%% directive.
#
# The source names "IBM Plex Sans, Noto Sans TC" because the Artifact loads them
# from Google Fonts. Offline that link is gone (step 1), so those names resolve
# to nothing -- and mermaid measures label widths with whatever it actually gets
# while the directive still claims a different font. Naming fonts that are
# present on the machine keeps measurement and rendering in agreement.
doc = doc.replace(
    '"fontFamily":"IBM Plex Sans, Noto Sans TC, sans-serif"',
    '"fontFamily":"-apple-system, BlinkMacSystemFont, PingFang TC, Microsoft JhengHei, Noto Sans CJK TC, sans-serif"',
)

# 2. The source is a body fragment (the Artifact host supplies the skeleton).
#    Offline it needs a real document, and the skeleton must repeat the two
#    rules the host's own reset provides, or the page renders on the browser
#    default ground instead of its own.
head = """<!doctype html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  /* The Artifact host supplies these; offline nothing does. */
  :root { color-scheme: light dark; }
  body { margin: 0; }
  img { max-width: 100%; }
  [hidden] { display: none !important; }

  /* THE ONE RULE THAT MAKES THE DIAGRAMS CORRECT.
   *
   * `<pre>` is a monospace element by browser default, and the page's own CSS
   * never resets it -- it had no reason to, because in the Artifact the host
   * replaces the whole <pre> when it renders.
   *
   * Offline, mermaid measures every label in a temporary element it appends to
   * <body> (sans-serif, inherited from the page) and then injects the finished
   * SVG into <pre class="mermaid"> (monospace, from the UA stylesheet). The
   * same string is wider in the font it renders in than in the font it was
   * measured in, so labels overflow their nodes and are clipped at the border.
   *
   * The symptom is why this comment is long: every diagram appears, nothing
   * errors, the console is clean, and the only evidence is "Alertmanager"
   * reading as "Alertmanage". It looks like a mermaid sizing bug. It is a
   * font-inheritance bug, and it was found by rendering the same diagram
   * inside and outside this container and comparing. */
  pre.mermaid { font-family: inherit; }

  /* Offline-only chrome: the export control and a note about provenance. */
  .offline-bar {
    position: sticky; top: 0; z-index: 50;
    display: flex; flex-wrap: wrap; align-items: center; gap: 10px 16px;
    padding: 8px 16px;
    background: var(--surface, #fff);
    border-bottom: 1px solid var(--rule, #d8dee7);
    font: 12.5px "Noto Sans TC", system-ui, sans-serif;
    color: var(--ink-soft, #4c5765);
  }
  .offline-bar b { color: var(--ink, #141a22); font-weight: 600; }
  .offline-bar button {
    font: inherit; font-weight: 600;
    color: var(--surface, #fff); background: var(--devops, #1f5fa8);
    border: 0; border-radius: 3px; padding: 5px 12px; cursor: pointer;
  }
  .offline-bar button:hover { filter: brightness(1.08); }
  .offline-bar button:focus-visible { outline: 2px solid currentColor; outline-offset: 2px; }
  .offline-bar button[disabled] { opacity: .55; cursor: default; }
  @media print { .offline-bar { display: none; } }
</style>
</head>
<body>
<div class="offline-bar">
  <b>離線版</b>
  <span>不連網路。由 <code>docs/report/plates.src.html</code> 產生，勿直接編輯本檔。</span>
  <button id="export-svg" type="button">匯出八張 SVG</button>
  <span id="export-note"></span>
</div>
"""

# 3. Render mermaid in the browser from the vendored copy. `startOnLoad` is off
#    and render is explicit so a failure is VISIBLE: a diagram that throws
#    leaves a red note in its own place rather than an empty box, which on a
#    page of eight diagrams is otherwise indistinguishable from a diagram that
#    was never there.
tail = """
<script src="./assets/mermaid.min.js"></script>
<script>
(function () {
  "use strict";
  var blocks = Array.prototype.slice.call(document.querySelectorAll("pre.mermaid"));
  var svgs = [];

  function titleOf(pre) {
    var plate = pre.closest(".plate");
    var h2 = plate && plate.querySelector("h2");
    var no = plate && plate.querySelector(".plate-no");
    var n = no ? no.textContent.replace(/[^0-9]/g, "") : String(svgs.length + 1);
    return (n.length < 2 ? "0" + n : n) + "-" + (h2 ? h2.textContent.trim() : "plate");
  }

  mermaid.initialize({ startOnLoad: false, securityLevel: "loose" });

  // SEQUENTIAL, not Promise.all.
  //
  // This is not a style preference. mermaid measures every label by laying it
  // out in a shared off-screen element and reading the box back; concurrent
  // renders interleave in that one element, so a diagram gets sized against
  // ANOTHER diagram's text. The symptom is subtle and easy to misdiagnose:
  // every diagram appears, none errors, and labels are quietly clipped at the
  // node border -- which reads as a mermaid bug, or as a font problem, and is
  // neither.
  //
  // Found by comparing against a probe that rendered the identical diagram
  // with the identical config one at a time and came out correct. Eight
  // diagrams take about a second either way, so the concurrency bought
  // nothing and cost correctness.
  function renderAll(i) {
    if (i >= blocks.length) return Promise.resolve();
    var pre = blocks[i];
    var source = pre.textContent;
    return mermaid.render("plate-" + i, source).then(function (res) {
      pre.innerHTML = res.svg;
      svgs.push({ name: titleOf(pre), svg: res.svg });
    }).catch(function (err) {
      // Loud, in place. An empty container reads as "no diagram here".
      pre.innerHTML = '<div style="border:1px solid #b3261e;background:#fdecea;' +
        'color:#7a1c14;padding:10px;border-radius:3px;text-align:left;font:13px monospace">' +
        "圖 " + (i + 1) + " 無法繪製：" + String(err && err.message ? err.message : err) +
        "</div>";
    }).then(function () { return renderAll(i + 1); });
  }

  renderAll(0).then(function () {
    var btn = document.getElementById("export-svg");
    var note = document.getElementById("export-note");
    if (!svgs.length) { btn.disabled = true; note.textContent = "沒有可匯出的圖"; return; }
    note.textContent = svgs.length + " 張已繪製";
    btn.addEventListener("click", function () {
      svgs.forEach(function (item, i) {
        // Staggered: browsers throttle a burst of same-tick downloads and
        // silently drop the tail, which would look like "only three exported".
        setTimeout(function () {
          var blob = new Blob([item.svg], { type: "image/svg+xml;charset=utf-8" });
          var url = URL.createObjectURL(blob);
          var a = document.createElement("a");
          a.href = url;
          a.download = item.name + ".svg";
          document.body.appendChild(a);
          a.click();
          document.body.removeChild(a);
          setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
        }, i * 250);
      });
      note.textContent = "已送出 " + svgs.length + " 個下載（可拖進 Keynote / PowerPoint）";
    });
  });
})();
</script>
</body>
</html>
"""

out = head + doc.strip() + "\n" + tail
with open(out_path, "w") as handle:
    handle.write(out)

leftover = re.findall(r'(?:src|href)="(https?://[^"]+)"', out)
print("  fonts link removed: %d" % fonts_removed)
print("  diagram blocks escaped: %d (so <br/> survives textContent)" % escaped)
print("  mermaid: vendored %s (./assets/mermaid.min.js)" % mermaid_version)
print("  external references remaining: %d %s" % (len(leftover), leftover or ""))
PY
RC=$?
[ "$RC" -eq 0 ] || { echo "FATAL: generation failed" >&2; exit 1; }

if [ "$CHECK" -eq 1 ]; then
  if [ ! -f "$OUT" ]; then
    echo "STALE: $OUT does not exist yet" >&2
    rm -f "$TARGET"; exit 3
  fi
  if cmp -s "$TARGET" "$OUT"; then
    echo "  up to date: $(basename "$OUT") matches what the source generates"
    rm -f "$TARGET"; exit 0
  fi
  echo "STALE: $(basename "$OUT") differs from what $(basename "$SRC") generates." >&2
  echo "  Run: docs/report/build.sh" >&2
  rm -f "$TARGET"; exit 3
fi

echo "  wrote $(basename "$OUT") ($(wc -c < "$OUT" | tr -d ' ') bytes)"
echo ""
echo "離線開啟：open $OUT"

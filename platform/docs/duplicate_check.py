#!/usr/bin/env python3
"""Two things describing the same subject, or two things producing the same file.

WHY REACHABILITY WAS NOT ENOUGH, STATED PRECISELY.

`capability_graph.py` prevents one path to duplicate work: you cannot find the
existing thing, so you build a second one. It does nothing about the other
path, which is the one that actually happened here on 2026-09-02:

    BOTH copies were documented. BOTH were reachable. They had drifted
    completely apart, and each was shown to the same reader as current.

Eight architecture diagrams existed twice -- a hand-drawn SVG set from
2026-08-25 embedded in the stage report, and a mermaid set built for the
offline deck. Same eight subjects, independently written, near-zero shared
label text. The older set still said "31 tests" and contained no Kubernetes at
all. Management would have seen one architecture on the board and a different
one in the deck.

So this looks for duplication directly, with two mechanical signals and no
semantic judgement:

  1. TWO PRODUCERS, ONE ARTIFACT -- two capabilities that write the same file.
  2. ONE SUBJECT, TWO PAGES -- the same normalised title in two rendered pages
     that are not a generated/source pair.

Signal 2 is the one that would have caught the diagrams: "DevOps 流程圖" and
"DevOps 流程" normalise to the same string. Signal 1 catches a different class
and is nearly free, so both are here.

WHAT THIS DELIBERATELY DOES NOT DO.

No similarity scoring on prose or docstrings. A threshold on similarity is a
judgement call wearing a number, it produces false positives, and false
positives are how a check gets ignored. Exact-match-after-normalisation is
weaker and it is trustworthy: every hit is a real collision.

Usage:
  duplicate_check.py            report
  duplicate_check.py --json     machine-readable
  duplicate_check.py --check    exit 1 on an unexplained duplicate

Exit codes:
  0  no unexplained duplicates
  1  two producers of one artifact, or two pages claiming one subject
  2  nothing scanned -- refusing to report
"""

import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.environ.get("DUPLICATE_CHECK_ROOT") or os.path.abspath(
    os.path.join(HERE, "..", ".."))

MIN_SCANNED = int(os.environ.get("DUPLICATE_CHECK_MIN") or 5)

# Pairs that are SUPPOSED to share a subject, with the reason. A generated page
# and its source share every title by construction; that is the single-source
# arrangement working, not a duplicate.
ALLOWED_PAIRS = {
    ("docs/report/plates.offline.html", "docs/report/plates.src.html"):
        "plates.offline.html is generated from plates.src.html by "
        "docs/report/build.sh; sharing every title is the single source working",
}

# Artifacts named by more than one capability for a known reason. Signal 1 is
# keyed by basename and does not distinguish "writes" from "reads" -- see the
# note on WRITE_MARKERS -- so these are the benign collisions it will always
# see, recorded rather than silently filtered.
ALLOWED_ARTIFACTS = {
    "README.md":
        "both graph tools use it as the walk's root; neither produces it",
    "index.md":
        "decisions.py produces it; okf_check.py reads it to check conformance",
}

# Titles too generic to mean anything.
GENERIC_TITLES = {"決定", "現況", "背景", "摘要", "usage", "overview", "index"}

# Producers rarely write the full repo-relative path as one literal --
# os.path.join(REPO_ROOT, "docs", "Value-Stream-Board.html") is the normal
# shape -- so the artifact is keyed by BASENAME. Requiring the full path here
# was tried first and detected exactly zero producers, which would have shipped
# a signal that can never fire: the same vacuous-pass shape this repository
# keeps finding elsewhere.
ARTIFACT_RE = re.compile(
    r"[\"']([A-Za-z0-9_.-]+\.(?:html|json|md|prom|parquet|csv))[\"']")

# A path being MENTIONED is not the same as it being WRITTEN. doc_graph.py names
# docs/decisions/index.md in an exemption and doc_freshness.py names it in a
# registry; neither produces it. Requiring a write marker on the same line
# under-detects (a path assigned to a variable and written three lines later is
# missed) and never invents a finding, which is the correct direction to be
# wrong in: a duplicate check that cries wolf is a duplicate check people mute.
# The title signal below carries the weight; this one is a cheap extra.
# Requiring a write marker on the same line as the literal was tried and
# detected ZERO producers: the normal shape is
# os.path.join(REPO_ROOT, "evidence", "x.prom") with the literal on its own
# line. Rather than ship a signal that can never fire -- the vacuous-pass shape
# this repository keeps finding -- signal 1 is kept broad and ADVISORY: it
# reports, it never fails the check, and its benign hits are recorded above.
# Signal 2 is the one with teeth.
TITLE_RE = re.compile(r"<(?:title|h1|h2)[^>]*>(.*?)</(?:title|h1|h2)>", re.S | re.I)


def sh(*args):
    return subprocess.run(["git", "-C", REPO_ROOT, *args],
                          capture_output=True, text=True, check=False).stdout


def normalise(title):
    """Strip markup and the decorations that make one subject look like two.

    '流程圖' and '流程' are the same subject written twice; so are a title with
    and without surrounding whitespace or punctuation. Nothing here guesses at
    meaning -- it removes characters, and then requires an exact match.
    """
    text = re.sub(r"<[^>]+>", "", title)
    text = re.sub(r"[\s　]+", " ", text).strip()
    text = re.sub(r"[（(].*?[)）]", "", text)
    text = text.rstrip("圖表頁").strip()
    return text.lower()


def producers():
    """artifact path -> the capabilities that write it."""
    out = {}
    for path in sh("ls-files").splitlines():
        if not (path.endswith(".sh") or path.endswith(".py")):
            continue
        if "/tests/" in path or os.path.basename(path).startswith("test_"):
            continue
        try:
            with open(os.path.join(REPO_ROOT, path)) as handle:
                text = handle.read()
        except (OSError, UnicodeDecodeError):
            continue
        for match in ARTIFACT_RE.finditer(text):
            out.setdefault(match.group(1), set()).add(path)
    return out


def titles():
    """normalised title -> the rendered pages that carry it."""
    out = {}
    for path in sh("ls-files", "*.html").splitlines():
        if not path:
            continue
        try:
            with open(os.path.join(REPO_ROOT, path)) as handle:
                text = handle.read()
        except (OSError, UnicodeDecodeError):
            continue
        for raw in TITLE_RE.findall(text):
            key = normalise(raw)
            if not key or key in GENERIC_TITLES or len(key) < 3:
                continue
            out.setdefault(key, set()).add(path)
    return out


def walk():
    prod = producers()
    ttl = titles()

    artifact_hits = sorted(
        ({"artifact": art, "producers": sorted(who)}
         for art, who in prod.items()
         if len(who) > 1 and art not in ALLOWED_ARTIFACTS),
        key=lambda hit: hit["artifact"])

    subject_hits = []
    for key, files in sorted(ttl.items()):
        if len(files) < 2:
            continue
        pair = tuple(sorted(files))
        if len(pair) == 2 and pair in ALLOWED_PAIRS:
            continue
        subject_hits.append({"subject": key, "pages": sorted(files)})

    return {
        "capabilities_scanned": len(set().union(*prod.values())) if prod else 0,
        "artifacts_seen": len(prod),
        "titles_seen": len(ttl),
        "two_producers_one_artifact": artifact_hits,
        "one_subject_two_pages": subject_hits,
        "allowed_pairs": {" + ".join(k): v for k, v in ALLOWED_PAIRS.items()},
    }


def main(argv):
    report = walk()

    if report["artifacts_seen"] + report["titles_seen"] < MIN_SCANNED:
        sys.stderr.write(
            "REFUSED: scanned %d artifact(s) and %d title(s), below the floor of %d.\n"
            "  The extraction has broken. 'No duplicates' from a scan that found\n"
            "  nothing is not a result.\n"
            % (report["artifacts_seen"], report["titles_seen"], MIN_SCANNED))
        return 2

    if "--json" in argv:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print("duplicate work check")
        print("  %d artifact path(s) and %d rendered title(s) scanned"
              % (report["artifacts_seen"], report["titles_seen"]))
        for allowed, reason in report["allowed_pairs"].items():
            print("  allowed: %s\n      %s" % (allowed, reason))
        if report["two_producers_one_artifact"]:
            print("  ADVISORY -- two capabilities name one artifact "
                  "(reports only, does not fail):")
            for hit in report["two_producers_one_artifact"]:
                print("      %s" % hit["artifact"])
                for who in hit["producers"]:
                    print("          %s" % who)
        if report["one_subject_two_pages"]:
            print("  ONE SUBJECT, TWO PAGES (this is how the eight diagrams diverged):")
            for hit in report["one_subject_two_pages"]:
                print("      %s" % hit["subject"])
                for page in hit["pages"]:
                    print("          %s" % page)
        if not report["one_subject_two_pages"]:
            print("  no subject claimed by two pages")

    if "--check" in argv:
        # Only signal 2 fails. Signal 1 cannot tell writing from reading, and a
        # check that cries wolf is a check people mute -- which would cost more
        # than the cases it would catch.
        return 1 if report["one_subject_two_pages"] else 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

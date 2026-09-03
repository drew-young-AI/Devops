#!/usr/bin/env python3
"""Rendered pages: which ones are generated, and which are somebody's promise.

WHY THIS EXISTS, AND WHY REACHABILITY WAS NOT ENOUGH.

`doc_graph.py` proves you can REACH a document from the index. That is a real
property and it caught five orphans. It is also not the property that hurt.

The document that did the most damage here was `docs/System-State.html`: a
hand-curated status page, linked prominently from the README as the one to read
first, declaring that "data governance and process visualisation are almost
empty" -- nine days after both had been built. It was reachable. It was
current-looking. It was wrong, and it was wrong in the direction that made the
platform look worst at exactly the things it had most recently invested in.

A second one was found the same way: `docs/Platform-Report.html`, from
2026-08-20, still claiming 6,172,492 fact rows (6,503,799) and "31 tests".

Neither would have failed a reachability check. So the question this file asks
is the complementary one:

    IS THIS PAGE GENERATED, OR IS SOMEBODY PROMISING TO KEEP IT TRUE BY HAND?

THE RULE, AND WHY IT IS NOT "NO HAND-WRITTEN PAGES".

Banning curated pages would be wrong -- a milestone snapshot SHOULD be frozen,
and the mermaid source of the eight plates is hand-authored by design. The rule
is weaker and enforceable: every tracked rendered page under docs/ must either

    (a) be GENERATED, and its generator's own check must pass, or
    (b) be CURATED, and say in one line why it is allowed to go stale.

A page in neither list fails. That is the whole mechanism: adding a
hand-maintained status page is not forbidden, it just cannot be done silently,
and the sentence you have to write is usually the moment you notice you are
about to build the thing that already went wrong twice.

Markdown is deliberately out of scope. Prose is legitimately hand-written; the
failure mode being guarded is the RENDERED STATUS PAGE, which reads like a
dashboard and ages like a document.

Usage:
  doc_freshness.py            report
  doc_freshness.py --check    exit 1 on an undeclared page or a failing generator

Exit codes:
  0  every rendered page is declared, and every generator's check passes
  1  an undeclared page, a stale declaration, or a generator whose check failed
  2  fewer pages found than the floor -- the scan has stopped seeing things
"""

import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.environ.get("DOC_FRESHNESS_ROOT") or os.path.abspath(
    os.path.join(HERE, "..", ".."))

# The scan cannot silently collapse to nothing. "0 undeclared pages" out of two
# pages found is a different sentence from "0 out of zero".
MIN_PAGES = int(os.environ.get("DOC_FRESHNESS_MIN_PAGES") or 2)

# Generated, with the command that proves it has not drifted from its source.
# The command must exit 0. A generator without a check mode does not belong
# here -- claiming a page is generated without being able to show it is the
# same unverifiable promise the curated list at least states honestly.
GENERATED = {
    "docs/decisions/index.md":
        ["python3", "platform/docs/decisions.py", "--check"],
    "docs/report/plates.offline.html":
        ["docs/report/build.sh", "--check"],
}

# Hand-maintained on purpose. One line each, saying why it is allowed to age.
CURATED = {
    "docs/Milestone-2026-08-25.html":
        "a dated milestone snapshot; being frozen is the point, and its "
        "filename carries the date so no reader mistakes it for current state",
    "docs/report/plates.src.html":
        "the hand-authored source of the eight plates; plates.offline.html is "
        "generated FROM it, so this is the one file that must be edited by hand",
}


# Overridable so the controls in test_doc_freshness.sh can inject a fault as
# DATA instead of editing this file and relying on a restore. The registries
# below stay the real ones; nothing here changes what the repository declares.
_gen_override = os.environ.get("DOC_FRESHNESS_GENERATED")
if _gen_override is not None:
    GENERATED = json.loads(_gen_override)
_cur_override = os.environ.get("DOC_FRESHNESS_CURATED")
if _cur_override is not None:
    CURATED = json.loads(_cur_override)


def tracked_pages():
    out = subprocess.run(
        ["git", "-C", REPO_ROOT, "ls-files", "docs/*.html", "docs/**/*.html",
         "docs/decisions/index.md"],
        capture_output=True, text=True, check=False).stdout
    return sorted({p for p in out.splitlines() if p})


def main(argv):
    check = "--check" in argv
    pages = tracked_pages()

    if len(pages) < MIN_PAGES:
        sys.stderr.write(
            "REFUSED: found %d rendered page(s) under docs/, expected at least %d.\n"
            "  The scan is not seeing the tree any more, and 'nothing undeclared'\n"
            "  from a scan that found nothing is not a result.\n" % (len(pages), MIN_PAGES))
        return 2

    undeclared = [p for p in pages if p not in GENERATED and p not in CURATED]
    stale_decl = sorted((set(GENERATED) | set(CURATED)) - set(pages))

    failures = []
    print("rendered pages under docs/")
    for path in pages:
        if path in GENERATED:
            cmd = GENERATED[path]
            done = subprocess.run(cmd, cwd=REPO_ROOT, capture_output=True, text=True,
                                  check=False)
            ok = done.returncode == 0
            if not ok:
                failures.append((path, " ".join(cmd), done.returncode))
            print("  %-40s GENERATED  %s  (%s)"
                  % (path, "check ok" if ok else "CHECK FAILED rc=%d" % done.returncode,
                     " ".join(cmd)))
        elif path in CURATED:
            print("  %-40s curated    %s" % (path, CURATED[path]))

    if undeclared:
        print("  UNDECLARED (neither generated nor a recorded curated page):")
        for path in undeclared:
            print("      %s" % path)
        print("      A hand-maintained status page is allowed. An undeclared one is")
        print("      how docs/System-State.html sat wrong for nine days while being")
        print("      linked as the page to read first.")
    if stale_decl:
        print("  STALE DECLARATIONS (named here, no longer in the repository):")
        for path in stale_decl:
            print("      %s" % path)
    if failures:
        print("  GENERATOR CHECK FAILED (the page has drifted from its source):")
        for path, cmd, rc in failures:
            print("      %-40s %s -> rc=%d" % (path, cmd, rc))
    if not undeclared and not stale_decl and not failures:
        print("  every rendered page is declared, and every generator's check passes")

    if check:
        return 1 if (undeclared or stale_decl or failures) else 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

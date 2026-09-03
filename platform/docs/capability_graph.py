#!/usr/bin/env python3
"""Capabilities: can a person or an agent starting at README.md find this, and
learn what it is for?

WHY THIS IS A DIFFERENT QUESTION FROM doc_graph.py.

`doc_graph.py` asks whether every DOCUMENT is reachable. That is necessary and
it is not the thing that actually goes wrong. What goes wrong is an ORPHAN
CAPABILITY: a script that works, is called by other code, and appears in no
document anybody can reach from the index. Nothing is broken, so nothing
complains -- and the next person, or the next agent, cannot find it, so they
build a second one. That is how a repository grows two implementations of the
same thing, which is the failure this file exists to prevent, not untidiness.

When first run (2026-09-02) it found 10 of 77 capabilities in that state,
including four things a human is supposed to RUN: the rotation drill, the
one-time rotation-check AppRole setup, the per-secret rotation policy setter,
and the Alertmanager notification setup.

"CALLED BY CODE" IS NOT "DISCOVERABLE".

Every one of those ten was referenced by another script. That is exactly why
grep-based reasoning is not enough: a capability can be fully wired into the
system and still be invisible to everyone who has not already read the source.
Discoverability means a path from README.md, through links, to a sentence that
says what this thing does.

INTERNAL PIECES ARE ALLOWED, BUT THEY MUST NAME THEIR FRONT DOOR.

Not every file is an entry point. `check_health.py` is the engine behind
`check_health.sh`; documenting it separately would be noise. So an internal
piece is declared in INTERNAL as pointing at the capability that IS documented
-- and this file then CHECKS that the named entry point is itself described.
Without that second half, INTERNAL would be a place to hide anything.

Usage:
  capability_graph.py            report
  capability_graph.py --json     machine-readable
  capability_graph.py --catalog  write evidence/capabilities.json for agents
  capability_graph.py --check    exit 1 if a capability is undiscoverable

Exit codes:
  0  every capability is described, or is internal to one that is
  1  an undiscoverable capability, a stale entry, or an internal piece whose
     named entry point is itself undocumented
  2  fewer capabilities found than the floor -- refusing to report
"""

import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.environ.get("CAPABILITY_GRAPH_ROOT") or os.path.abspath(
    os.path.join(HERE, "..", ".."))
ROOT_DOC = "README.md"

# This repository cannot drop to a handful of scripts by accident. A smaller
# number means the enumeration broke, and "0 orphans out of 3" is a clean bill
# of health derived from having looked at almost nothing.
MIN_CAPABILITIES = int(os.environ.get("CAPABILITY_GRAPH_MIN") or 40)

# Internal pieces: {the file: the documented capability it belongs to}.
# The entry point named here is itself checked for being described, so this
# cannot be used to hide a capability -- only to attach one to its front door.
INTERNAL = {
    "platform/analytics/benchmark.py": "platform/analytics/benchmark.sh",
    "platform/analytics/mirror.py": "platform/analytics/run.sh",
    "platform/docs/context_cost.py": "platform/docs/context_cost.sh",
    "platform/observability/check_health.py": "platform/observability/check_health.sh",
    "platform/notify/send_mail.sh": "platform/notify/emit_event.sh",
    "platform/scheduler/record_gap.py": "platform/scheduler/run_job.sh",
    "pilots/station2-twin/app/vault_creds.py": "pilots/station2-twin/app/app.py",
    "pilots/station2-twin/ingest/probe_feed.py":
        "pilots/station2-twin/ingest/load_dimensional.py",
}

# Overridable so the controls in test_capability_graph.sh inject faults as DATA
# rather than editing this file and relying on a restore.
_internal_override = os.environ.get("CAPABILITY_GRAPH_INTERNAL")
if _internal_override is not None:
    INTERNAL = json.loads(_internal_override)

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)|href=\"([^\"]+)\"")


def sh(*args):
    return subprocess.run(["git", "-C", REPO_ROOT, *args],
                          capture_output=True, text=True, check=False).stdout


def reachable_docs():
    """Documents a reader can arrive at from the index, by clicking."""
    tracked = set(sh("ls-files").splitlines())
    reached, queue = {ROOT_DOC}, [ROOT_DOC]
    while queue:
        current = queue.pop(0)
        try:
            with open(os.path.join(REPO_ROOT, current)) as handle:
                text = handle.read()
        except (OSError, UnicodeDecodeError):
            continue
        base = os.path.dirname(current)
        for match in LINK_RE.finditer(text):
            target = (match.group(1) or match.group(2) or "").strip()
            target = target.split()[0] if target else ""
            if not target or target.startswith("#") or re.match(
                    r"^[a-zA-Z][a-zA-Z0-9+.-]*:", target):
                continue
            target = target.split("#", 1)[0]
            if not target:
                continue
            resolved = os.path.normpath(os.path.join(base, target) if base else target)
            if resolved.endswith(".md") and resolved in tracked and resolved not in reached:
                reached.add(resolved)
                queue.append(resolved)
    return sorted(reached)


def capabilities():
    """Executables under platform/ and pilots/, excluding the test suites.

    Test suites are excluded because their discoverability is a different and
    already-enforced property: every one must be registered in run_all.sh, and
    that registration is checked separately below.
    """
    out = []
    for path in sh("ls-files").splitlines():
        if not (path.endswith(".sh") or path.endswith(".py")):
            continue
        if not (path.startswith("platform/") or path.startswith("pilots/")):
            continue
        if "/tests/" in path or os.path.basename(path).startswith("test_"):
            continue
        out.append(path)
    return sorted(out)


def naming_suffix(path, caps):
    """The shortest trailing path fragment that identifies this capability alone.

    A bare basename is not always enough: there are four `run.sh` and two
    `deploy.sh` here, so a document saying "run.sh" would mark all four as
    described while describing at most one. A guard that reports everything as
    covered because it cannot tell two files apart is worse than no guard,
    because it reads exactly like a real pass.

    Widening to the shortest UNAMBIGUOUS suffix rather than demanding the full
    path is the difference between a rule people can follow and one they route
    around: `mlops/run.sh` is how a person naturally writes it in the pilot's
    own README, and it is unambiguous, so it counts.
    """
    parts = path.split("/")
    for depth in range(1, len(parts) + 1):
        suffix = "/".join(parts[-depth:])
        if sum(1 for c in caps if c == suffix or c.endswith("/" + suffix)) == 1:
            return suffix
    return path


def _is_capability_row(suffix, cells):
    """A row that DESCRIBES this capability, not one that merely cites it.

    The capability must be the row's SUBJECT -- first cell -- and the row must
    carry at least three filled cells. Without the first-cell rule the
    generated decision index qualified: its `rerun:` column names scripts, so
    `loki_coverage.py` was "described" by a row whose three columns were the
    ADR's title, status and date. The check passed and the generated catalogue
    published nonsense, which is worse than failing: it looked like an answer.
    """
    # Four filled cells: the capability itself plus when / what / guarantee.
    # Three was the first rule and it let three-column tables through, which
    # produced catalogue entries with an empty `guarantee` -- a machine-readable
    # answer with a hole in it, which an agent cannot tell from a real one.
    if len([c for c in cells if c]) < 4:
        return False
    return bool(cells) and suffix in cells[0]


def table_row_for(path, corpus, caps):
    """The row that describes this capability, split into its cells.

    Generated, never hand-written. A hand-maintained capability list is a
    second index, and two indexes are a divergence problem: nobody updates
    both, so one starts lying while reading exactly like the one that does not.
    Deriving it from the README tables means the catalogue cannot drift from
    the documentation without the documentation itself changing.
    """
    suffix = naming_suffix(path, caps)
    for doc, text in sorted(corpus.items()):
        for line in text.splitlines():
            stripped = line.lstrip()
            if suffix not in stripped or not stripped.startswith("|"):
                continue
            cells = [c.strip() for c in stripped.strip().strip("|").split("|")]
            if _is_capability_row(suffix, cells):
                return doc, cells
    return None, []


def strip_markdown(text):
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    return re.sub(r"[`*]", "", text).strip()


def catalog(report_caps, corpus, caps):
    """The agent-facing view: capability -> path, when, what, guarantee."""
    entries = []
    for cap in caps:
        doc, cells = table_row_for(cap, corpus, caps)
        if not cells:
            entry = {"path": cap, "described": False}
            if cap in INTERNAL:
                entry["internal_to"] = INTERNAL[cap]
            entries.append(entry)
            continue
        entries.append({
            "path": cap,
            "described": True,
            "described_in": doc,
            "when": strip_markdown(cells[1]) if len(cells) > 1 else "",
            "what": strip_markdown(cells[2]) if len(cells) > 2 else "",
            "guarantee": strip_markdown(cells[3]) if len(cells) > 3 else "",
            "run": cap,
        })
    return entries


def described_in(path, corpus, caps):
    """Documents that DESCRIBE this capability, not merely mention it.

    A description has to answer three things: when it runs, what it does, and
    what it guarantees. "See `foo.sh`" answers none of them, and under the
    first version of this rule it counted -- which meant the check passed on 52
    capabilities whose only trace was a passing mention in prose.

    Rather than try to judge prose, the requirement is structural: the mention
    must sit in a markdown table row carrying at least three filled cells
    beside it. A machine can verify the three columns exist; it cannot verify
    they are well written, and this file does not pretend otherwise. What it
    does buy is that adding a capability without saying anything about it is no
    longer possible by accident.
    """
    suffix = naming_suffix(path, caps)
    hits = []
    for doc, text in corpus.items():
        for line in text.splitlines():
            stripped = line.lstrip()
            if suffix not in stripped or not stripped.startswith("|"):
                continue
            cells = [c.strip() for c in stripped.strip().strip("|").split("|")]
            if _is_capability_row(suffix, cells):
                hits.append(doc)
                break
    return sorted(hits)


def unregistered_suites():
    try:
        with open(os.path.join(REPO_ROOT, "platform/tests/run_all.sh")) as handle:
            runner = handle.read()
    except OSError:
        return []
    return [p for p in sh("ls-files", "platform/tests/test_*.sh").splitlines()
            if p and os.path.basename(p) not in runner]


def walk():
    docs = reachable_docs()
    corpus = {}
    for doc in docs:
        try:
            with open(os.path.join(REPO_ROOT, doc)) as handle:
                corpus[doc] = handle.read()
        except (OSError, UnicodeDecodeError):
            continue

    caps = capabilities()
    described, orphans, internal_ok, internal_bad = [], [], [], []
    for cap in caps:
        if described_in(cap, corpus, caps):
            described.append(cap)
        elif cap in INTERNAL:
            entry = INTERNAL[cap]
            # The half that gives INTERNAL its teeth: an internal piece whose
            # front door is itself undocumented is not internal, it is hidden.
            (internal_ok if described_in(entry, corpus, caps) else internal_bad).append(
                {"file": cap, "entry": entry})
        else:
            orphans.append(cap)

    stale = sorted(set(INTERNAL) - set(caps))
    return {
        "root": ROOT_DOC,
        "reachable_docs": len(docs),
        "capabilities": len(caps),
        "described": len(described),
        "internal": internal_ok,
        "internal_without_documented_entry": internal_bad,
        "orphans": orphans,
        "stale_internal_entries": stale,
        "unregistered_test_suites": unregistered_suites(),
    }


def main(argv):
    report = walk()

    if report["capabilities"] < MIN_CAPABILITIES:
        sys.stderr.write(
            "REFUSED: found %d capabilit(ies), expected at least %d.\n"
            "  The enumeration has broken. Reporting '0 orphans' from a scan that\n"
            "  found almost nothing is the exact failure this file prevents.\n"
            % (report["capabilities"], MIN_CAPABILITIES))
        return 2

    if "--catalog" in argv:
        docs = reachable_docs()
        corpus = {}
        for doc in docs:
            try:
                with open(os.path.join(REPO_ROOT, doc)) as handle:
                    corpus[doc] = handle.read()
            except (OSError, UnicodeDecodeError):
                continue
        caps = capabilities()
        out = os.environ.get("CAPABILITY_CATALOG_OUT") or os.path.join(
            REPO_ROOT, "evidence", "capabilities.json")
        payload = {
            "generated_by": "platform/docs/capability_graph.py --catalog",
            "root": ROOT_DOC,
            "count": len(caps),
            "capabilities": catalog(report, corpus, caps),
        }
        os.makedirs(os.path.dirname(out), exist_ok=True)
        tmp = out + ".tmp"
        with open(tmp, "w") as handle:
            json.dump(payload, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        os.replace(tmp, out)
        print("wrote %s (%d capabilities)" % (os.path.relpath(out, REPO_ROOT), len(caps)))
        return 0

    if "--json" in argv:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print("capabilities discoverable from %s" % ROOT_DOC)
        print("  %d of %d described in a document reachable by clicking"
              % (report["described"], report["capabilities"]))
        print("  %d internal to a documented entry point" % len(report["internal"]))
        for item in report["internal"]:
            print("      %-52s -> %s" % (item["file"], item["entry"]))
        if report["internal_without_documented_entry"]:
            print("  INTERNAL, BUT ITS ENTRY POINT IS ALSO UNDOCUMENTED:")
            for item in report["internal_without_documented_entry"]:
                print("      %-52s -> %s" % (item["file"], item["entry"]))
        if report["stale_internal_entries"]:
            print("  STALE INTERNAL ENTRIES (file no longer exists):")
            for path in report["stale_internal_entries"]:
                print("      %s" % path)
        if report["unregistered_test_suites"]:
            print("  TEST SUITES NOT REGISTERED IN run_all.sh:")
            for path in report["unregistered_test_suites"]:
                print("      %s" % path)
        if report["orphans"]:
            print("  ORPHAN CAPABILITIES (they work; nobody can find them):")
            for path in report["orphans"]:
                print("      %s" % path)
            print("      Being called by another script is not discoverability.")
            print("      The next person who cannot find one builds a second one.")
        else:
            print("  no orphan capabilities")

    if "--check" in argv:
        bad = (len(report["orphans"]) + len(report["stale_internal_entries"])
               + len(report["internal_without_documented_entry"])
               + len(report["unregistered_test_suites"]))
        return 1 if bad else 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

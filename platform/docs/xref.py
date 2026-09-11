#!/usr/bin/env python3
"""xref.py -- do the names in this repository still mean anything?

WHY THIS IS A DIFFERENT QUESTION FROM EVERY OTHER LEDGER HERE (2026-09-11).

Five closure checks already exist and all five ask the same shape of question:

    doc_graph.py            is every DOCUMENT reachable
    capability_graph.py     is every SCRIPT described somewhere reachable
    COVERAGE (dag.py)       is every SERVICE and JOB watched by a node
    EVIDENCE_READS          does every artifact FIELD a probe reads exist
    test_sql_contract.sh    does every TABLE/COLUMN/VALUE a query names exist

Every one of them asks "is X covered, right now". Not one of them asks what
happens to the NAME of something that gets deleted. So the repository can pass
all five while a document confidently describes a node that no longer exists --
and it did. On 2026-09-10 four nodes (`ci`, `trivy`, `registry`, `prodlike`)
were removed from NODES. `platform/statusdag/README.md` was updated by hand.
`NEW_SERVICE_GUIDE.md` was not, and went on stating:

    `prodlike` 節點在板面上是 `superseded`

which is not stale, it is FALSE: the node is not on the board in any state. No
test could fail, because every test asked whether things that exist are
covered, and this is a reference to a thing that does not.

THE ERROR CLASS THIS CLOSES.

A deletion has an unbounded blast radius across prose. The person deleting sees
the definition; they do not see the 73 markdown files that might name it. Fixing
each discovered instance by hand is what produced this gap in the first place --
it is the same reactive method, and it only ever catches what someone happened
to look at.

DERIVED, NOT DECLARED.

The set of retired names is not hand-maintained here; a hand-written list of
"things we deleted" is one more thing the person who forgot to update the docs
can also forget to update. It is computed as

    RETIRED = (every name this file ever defined, from git history) - (defined now)

so it cannot disagree with reality. Four namespaces are checked with one
mechanism rather than four bespoke tests:

    node     platform/statusdag/dag.py NODES
    adr      docs/decisions/NNNN-*.md
    backlog  docs/Backlog.md item ids
    alert    platform/observability/prometheus/alerts/*.yml

Two directions are reported, and they are different defects:

    DANGLING      a retired name is still referenced in prose, with no marker
                  saying it is retired -> the reader is told something false
    UNDEFINED     a reference to a name that was NEVER defined -> a typo, or a
                  plan someone wrote down and never built
    UNDOCUMENTED  a defined name no document mentions -> exists, nobody can
                  find it

A retired name MAY be mentioned -- history has to be writable. It must carry an
explicit marker on the line or the line above (已移除/已退役/已刪除/REMOVED/
RETIRED/retired-ref). `superseded` is deliberately NOT a marker: it is a board
STATE, and the sentence that started all this used it to make a present-tense
claim about a node that is not on the board.
"""

import datetime
import json
import os
import re
import subprocess
import sys

ROOT = os.environ.get("XREF_ROOT") or os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
)

# A mention of a retired name is allowed only if the line, or the one before
# it, says so. Narrow on purpose -- see the module docstring on `superseded`.
RETIRE_MARK = re.compile(
    r"移除|退役|刪除|拿掉|不再|REMOVED|RETIRED|retired-ref|no longer", re.I
)


def _paras(text):
    """Blank-line-separated blocks. A disambiguation note is a sentence, and a
    sentence wraps; requiring the filename and the word 編號 on one physical
    line would just teach the next person to write a very long line."""
    return re.split(r"\n\s*\n", text)


def _declares_retired(lines, pat):
    """Does this FILE state, in one line, that THIS name is retired?

    Scope is the document and the rule is name-specific, and both halves were
    arrived at by getting it wrong first:

      - Line-local was too tight. `platform/statusdag/README.md` says
        「`ci`／`trivy`／`registry`／`prodlike` 已移除」 once, then lists where
        each went; those list lines carry no marker and are not wrong.
      - Section-scoped was too loose, and silenced the very finding this file
        was written for. `NEW_SERVICE_GUIDE.md` §「擁有權界線」 contains
        「`Architecture.md` 已於 2026-09-09 刪除」 -- a retirement marker about
        a DIFFERENT noun, sitting 3 lines above a present-tense claim that
        `prodlike` is on the board. A marker that does not name the thing it
        retires proves nothing.

    So: a document that mentions a dead name must say, once, that it is dead.
    """
    return any(pat.search(ln) and RETIRE_MARK.search(ln) for ln in lines)


SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "site-packages", "evidence",
             "__pycache__", ".pytest_cache", ".mypy_cache", "dist", "build"}
TEXT_EXT = {".md", ".py", ".sh", ".yml", ".yaml", ".json", ".conf", ".sql"}


def _shallow():
    """A shallow clone cannot answer what this file asks.

    `RETIRED` is derived from git history. With `fetch-depth: 1` there is no
    history, every retired set comes back empty, and DANGLING becomes
    unreportable -- the check passes by being unable to look. CI found this on
    2026-09-11: the run was green locally and the assertion 「retired set is
    empty」 fired on GitHub. Refusing is the only honest answer; the workflow
    now checks out full history.
    """
    out = subprocess.run(["git", "rev-parse", "--is-shallow-repository"],
                         cwd=ROOT, capture_output=True, text=True).stdout.strip()
    return out == "true"


def _git(*args):
    try:
        return subprocess.run(
            ["git"] + list(args), cwd=ROOT, capture_output=True, text=True, timeout=120
        ).stdout
    except Exception:
        return ""


def _nodes_from(text):
    """Node ids from a NODES block, or from raw diff lines (same tuple shape)."""
    return set(re.findall(r'^[-+ ]?\s*\("([a-z0-9_-]+)",\s*"', text, re.M))


def ns_node():
    src = os.path.join(ROOT, "platform/statusdag/dag.py")
    body = open(src, encoding="utf-8").read()
    i = body.index("NODES = [")
    cur = _nodes_from(body[i:body.index("\n]", i)])
    hist = cur | _nodes_from(
        "\n".join(
            ln for ln in _git("log", "-p", "--", "platform/statusdag/dag.py").splitlines()
            if ln.startswith("-")
        )
    )
    return cur, hist, src


def ns_adr():
    d = os.path.join(ROOT, "docs/decisions")
    cur = {f[:4] for f in os.listdir(d) if re.match(r"^\d{4}-", f)}
    deleted = _git("log", "--diff-filter=D", "--name-only", "--format=", "--", "docs/decisions/")
    hist = cur | {
        m for m in re.findall(r"docs/decisions/(\d{4})-", deleted)
    }
    return cur, hist, d


def ns_backlog():
    """Defined = MENTIONED ANYWHERE in Backlog.md, not "has an open §27 row".

    The first version of this function used the row regex, and it was wrong in
    the way this whole file exists to catch: a closed item loses its table row
    and keeps its prose record, so T13/T22/T25 came back as "never defined"
    while sitting in the file four times over. Closing an item is not deleting
    a name. There is no retired set here for that reason -- `hist == cur`.
    """
    src = os.path.join(ROOT, "docs/Backlog.md")
    body = open(src, encoding="utf-8").read()
    cur = set(re.findall(r"\b([TB]\d{1,3})\b", body))
    return cur, cur, src


def ns_alert():
    d = os.path.join(ROOT, "platform/observability/prometheus/alerts")
    cur = set()
    for f in sorted(os.listdir(d)):
        if f.endswith((".yml", ".yaml")):
            cur |= set(re.findall(r"^\s*-\s*alert:\s*(\w+)", open(os.path.join(d, f)).read(), re.M))
    hist = cur | set(
        re.findall(
            r"^-\s*-\s*alert:\s*(\w+)",
            _git("log", "-p", "--", "platform/observability/prometheus/alerts/"),
            re.M,
        )
    )
    return cur, hist, d


# `pattern(name)` must match a REFERENCE, not the definition. Node and backlog
# ids are short and collide with ordinary words (`ci`, `gate`, `facts`), so in
# prose they are required to be in backticks -- which is how every existing
# document already writes them (measured, not assumed).
NAMESPACES = {
    "node":    (ns_node,    lambda n: re.compile(r"`%s`" % re.escape(n))),
    "adr":     (ns_adr,     lambda n: re.compile(r"ADR-0?%s\b|decisions/%s-" % (re.escape(n.lstrip('0') or '0'), re.escape(n)))),
    "backlog": (ns_backlog, lambda n: re.compile(r"\b%s\b" % re.escape(n))),
    "alert":   (ns_alert,   lambda n: re.compile(r"\b%s\b" % re.escape(n))),
}


# A defined-but-unmentioned NODE is a real gap: the board shows a light nobody
# can look up. A backlog id or ADR number nothing cites is just an item.
UNDOCUMENTED_MATTERS = {"node", "alert"}


def scan_files():
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if os.path.splitext(fn)[1] in TEXT_EXT:
                yield os.path.join(dirpath, fn)


def main():
    files = []
    for p in scan_files():
        try:
            files.append((os.path.relpath(p, ROOT), open(p, encoding="utf-8").read().splitlines()))
        except (UnicodeDecodeError, OSError):
            continue

    generated = {
        rel for rel, lines in files
        if rel.endswith(".md") and any(ln.startswith("generator:") for ln in lines[:20])
    }

    report = {"namespaces": {}, "dangling": [], "undefined": [], "undocumented": [],
              "colliding": [], "generated_docs": sorted(generated)}

    # ── FOURTH DIRECTION: one id, two owners ───────────────────────────────
    #
    # The first three directions all assume an id has ONE meaning. On
    # 2026-09-11 that assumption broke: `Plan.md` 主線 B and `docs/Backlog.md`
    # both number items B1..B10, and B10 means 「流行病學週↔日曆日」 in one and
    # 「Telegram token 輪替」 in the other. `dag.py` cited a bare "B10" and sent
    # the reader to whichever list they opened first -- and this session's own
    # handover notes had already recorded the wrong one.
    #
    # Nothing is dangling and nothing is undocumented, so the other three
    # checks are all green. An ambiguous name is the failure that looks most
    # like health.
    rows = {}
    for rel, lines in files:
        if not rel.endswith(".md"):
            continue
        for line in lines:
            m = re.match(r"^\|\s*\*{0,2}([TB]\d{1,3})\*{0,2}\s*\|", line)
            if m:
                rows.setdefault(m.group(1), set()).add(rel)
    # A shared id space is allowed -- renumbering a historical plan is worse
    # than the ambiguity. What is NOT allowed is BOTH lists staying silent
    # about it: every owning document must name at least one of the others and
    # say the numbering is separate. One-sided is not enough; the reader who
    # got it wrong is the one holding the other document.
    by_file = {rel: lines for rel, lines in files}
    for name, owners in sorted(rows.items()):
        if len(owners) <= 1:
            continue
        owners = sorted(owners)
        silent = []
        for own in owners:
            others = [os.path.basename(o) for o in owners if o != own]
            txt = "\n".join(by_file.get(own, []))
            if not any(
                re.search(r"(編號|命名空間|id space|numbering)", ln) and any(o in ln for o in others)
                for ln in _paras(txt)
            ):
                silent.append(own)
        if silent:
            report["colliding"].append({"ns": "backlog", "name": name,
                                        "owners": owners, "silent": silent})

    if _shallow():
        print("REFUSED: shallow clone -- RETIRED is derived from git history, "
              "and with no history every retired set is empty. That is a check "
              "that cannot fail, not a clean repository. Use fetch-depth: 0.",
              file=sys.stderr)
        return 2

    for ns, (loader, patf) in NAMESPACES.items():
        cur, hist, src = loader()
        if not cur:
            print("REFUSED: namespace %s resolved to zero definitions" % ns, file=sys.stderr)
            return 2
        retired = hist - cur
        srcrel = os.path.relpath(src, ROOT)
        report["namespaces"][ns] = {
            "defined": sorted(cur), "retired": sorted(retired), "source": srcrel,
        }

        documented = set()
        for name in sorted(cur | retired):
            pat = patf(name)
            for rel, lines in files:
                declared = name in retired and _declares_retired(lines, pat)
                # The authoritative source defines the name; that is not a
                # reference to it.
                if rel == srcrel or rel.startswith(srcrel + os.sep):
                    continue
                for i, line in enumerate(lines):
                    if not pat.search(line):
                        continue
                    if name in cur:
                        # A GENERATED page is not documentation. Stage-Report.md
                        # lists only nodes that are not green, so a node
                        # "documented" there stops being documented the day it
                        # goes OK -- the status would flicker with the weather.
                        if rel.endswith(".md") and rel not in generated:
                            documented.add(name)
                        continue
                    if declared:
                        continue
                    report["dangling"].append(
                        {"ns": ns, "name": name, "file": rel, "line": i + 1,
                         "text": line.strip()[:160]}
                    )
        if ns in UNDOCUMENTED_MATTERS:
            for name in sorted(cur - documented):
                report["undocumented"].append({"ns": ns, "name": name})

    # UNDEFINED: a reference shaped like a governed id that resolves to nothing.
    for ns, rex in (("backlog", re.compile(r"\b([TB]\d{1,3})\b")),
                    ("adr", re.compile(r"\bADR-(\d{4})\b"))):
        cur = set(report["namespaces"][ns]["defined"]) | set(rows)
        ret = set(report["namespaces"][ns]["retired"])
        srcrel = report["namespaces"][ns]["source"]
        for rel, lines in files:
            if rel == srcrel or rel.startswith(srcrel + os.sep):
                continue
            for i, line in enumerate(lines):
                for m in rex.findall(line):
                    if m not in cur and m not in ret:
                        report["undefined"].append(
                            {"ns": ns, "name": m, "file": rel, "line": i + 1,
                             "text": line.strip()[:160]}
                        )

    if "--catalog" in sys.argv:
        # Same reason capability_graph.py has this mode (ADR-0019): the suite
        # runs this once per test run, and between two runs a document can be
        # edited into naming something that no longer exists. Writing the
        # answer where a probe can read it is what makes it continuous rather
        # than episodic.
        out = os.path.join(ROOT, "evidence", "docs", "xref.json")
        payload = {
            "generated_by": "platform/docs/xref.py --catalog",
            "generated_at": datetime.datetime.now(
                datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "namespaces_resolved": len(report["namespaces"]),
            "counts": {k: len(report[k]) for k in
                       ("dangling", "undefined", "colliding", "undocumented")},
            "namespaces": report["namespaces"],
            "dangling": report["dangling"],
            "undefined": report["undefined"],
            "colliding": report["colliding"],
            "undocumented": report["undocumented"],
        }
        os.makedirs(os.path.dirname(out), exist_ok=True)
        tmp = out + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        os.replace(tmp, out)
        print("wrote evidence/docs/xref.json (%d namespaces, %s)"
              % (payload["namespaces_resolved"], payload["counts"]))
    elif "--json" in sys.argv:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        for ns, d in report["namespaces"].items():
            print("%-8s defined=%-3d retired=%s" % (ns, len(d["defined"]), d["retired"] or "-"))
        print("\n== COLLIDING: %d ==" % len(report["colliding"]))
        for r in report["colliding"]:
            print("  [%s] %s rows in: %s  -- silent about it: %s"
                  % (r["ns"], r["name"], ", ".join(r["owners"]), ", ".join(r["silent"])))
        for k in ("dangling", "undefined", "undocumented"):
            print("\n== %s: %d ==" % (k.upper(), len(report[k])))
            for r in report[k][:40]:
                loc = "%s:%s" % (r["file"], r["line"]) if "file" in r else ""
                print("  [%s] %s  %s  %s" % (r["ns"], r["name"], loc, r.get("text", "")))
    return 1 if (report["dangling"] or report["undefined"]
                 or report["colliding"]) else 0


if __name__ == "__main__":
    sys.exit(main())

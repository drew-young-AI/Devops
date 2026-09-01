#!/usr/bin/env python3
"""Decision records: validate them, and generate the index.

THE PROBLEM THIS SOLVES.

Fifty-eight decisions were buried in Plan.md, mixed in with implementation
detail. Three months later the question is never "what did we decide" -- it is
"where is the number, and how do I get it again". Nobody finds it, so nobody
re-runs it; they re-estimate from memory instead, and a re-estimate is a guess
wearing the clothes of a measurement.

So the rule this file enforces is not "write decisions down". It is:

    EVERY MEASURED CLAIM CARRIES THE COMMAND THAT REPRODUCES IT,
    AND THAT COMMAND MUST POINT AT SOMETHING THAT EXISTS.

The second half is the part with teeth. A `rerun:` line naming a script that
was renamed six weeks ago is worse than no line at all: it reads as
reproducible right up until someone tries. This is the same rule the AIS
capability registry uses -- an entry without a working `verify` is treated as
unregistered, because a capability nobody can check is a zombie. A measurement
nobody can re-run is the same thing.

Checks:
  1. filename is NNNN-slug.md
  2. frontmatter carries a `decision` block with id / status / date
  3. id matches the filename, and no two records share one
  4. status is one of the allowed values
  5. measured: true REQUIRES a non-empty rerun command
  6. the rerun command's first token EXISTS as a file in this repo
  7. superseded_by / supersedes point at records that exist
  8. a superseded record must name what superseded it

Usage:
  decisions.py            validate, and write docs/decisions/index.md
  decisions.py --check    validate only (exit 1 on any problem)
"""
from __future__ import annotations

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
# Overridable so the suite can point this at a directory of deliberately broken
# records. Every check below is verified by breaking it first; a validator whose
# rules have never fired is a validator nobody knows the shape of.
DEC_DIR = os.environ.get("DECISIONS_DIR",
                         os.path.join(REPO_ROOT, "docs", "decisions"))
INDEX = os.path.join(DEC_DIR, "index.md")

NAME_RE = re.compile(r"^(\d{4})-[a-z0-9][a-z0-9-]*\.md$")
STATUS = {
    "accepted":   "已採用",
    "declined":   "已否決",
    "superseded": "已被取代",
    "proposed":   "提案中",
}


def load(path):
    import yaml
    text = open(path, encoding="utf-8").read()
    if not text.startswith("---"):
        return None, "no frontmatter"
    end = text.find("\n---", 3)
    if end < 0:
        return None, "frontmatter never closed"
    try:
        return yaml.safe_load(text[4:end]), None
    except Exception as exc:                                    # noqa: BLE001
        return None, f"frontmatter is not parseable YAML: {exc}"


def scan():
    records, problems = {}, []
    if not os.path.isdir(DEC_DIR):
        return records, [f"missing directory {DEC_DIR}"]

    for name in sorted(os.listdir(DEC_DIR)):
        if not name.endswith(".md") or name == "index.md":
            continue
        m = NAME_RE.match(name)
        if not m:
            problems.append(f"{name}: filename must be NNNN-slug.md")
            continue
        path = os.path.join(DEC_DIR, name)
        fm, err = load(path)
        if err:
            problems.append(f"{name}: {err}")
            continue

        d = (fm or {}).get("decision")
        if not isinstance(d, dict):
            problems.append(f"{name}: no `decision:` block in frontmatter")
            continue

        did = str(d.get("id", "")).zfill(4)
        if did != m.group(1):
            problems.append(f"{name}: decision.id {d.get('id')!r} does not match filename")
        if did in records:
            problems.append(f"{name}: duplicate decision id {did}")
        for field in ("status", "date"):
            if not d.get(field):
                problems.append(f"{name}: decision.{field} is missing")
        if d.get("status") not in STATUS:
            problems.append(f"{name}: status {d.get('status')!r} is not one of "
                            + "/".join(STATUS))

        # --- the rule with teeth ------------------------------------------
        if d.get("measured"):
            rerun = (d.get("rerun") or "").strip()
            if not rerun:
                problems.append(
                    f"{name}: measured: true but no rerun command. A number "
                    "without a way to reproduce it is an estimate.")
            else:
                first = rerun.split()[0]
                # Strip a leading env assignment (FOO=bar cmd ...)
                if "=" in first and not first.startswith("/"):
                    parts = rerun.split()
                    first = next((p for p in parts if "=" not in p), first)
                target = os.path.join(REPO_ROOT, first)
                if not os.path.exists(target):
                    problems.append(
                        f"{name}: rerun points at {first!r}, which does not "
                        "exist. A stale rerun reads as reproducible until "
                        "someone tries it.")

        records[did] = {"file": name, "title": fm.get("title", name),
                        "description": fm.get("description", ""), **d}

    # --- cross references -------------------------------------------------
    for did, r in records.items():
        sb = r.get("superseded_by")
        if sb and str(sb).zfill(4) not in records:
            problems.append(f"{r['file']}: superseded_by {sb} does not exist")
        if r.get("status") == "superseded" and not sb:
            problems.append(f"{r['file']}: status is superseded but nothing "
                            "says what superseded it")
        for s in (r.get("supersedes") or []):
            if str(s).zfill(4) not in records:
                problems.append(f"{r['file']}: supersedes {s} does not exist")
    return records, problems


def write_index(records):
    # NO frontmatter. `index.md` is a reserved filename in OKF v0.1 and reserved
    # files must not carry a frontmatter block -- the spec's way of saying an
    # index is not a concept document. platform/docs/okf_check.py enforces it,
    # and caught this generator emitting one.
    lines = [
        "# 決策紀錄索引",
        "",
        "<!-- 這份是產生的，不要手動編輯：platform/docs/decisions.py -->",
        "",
        "每一筆帶量測的決策**都必須附上重跑指令**，而那個指令必須指向存在的檔案——",
        "`decisions.py` 會擋下不符合的。理由：三個月後真正的失敗不是「忘記決定什麼」，",
        "是「找不到數字怎麼來的」，於是憑印象重估，而重估是穿著量測外衣的猜測。",
        "",
        "| # | 決策 | 狀態 | 日期 | 可重跑 |",
        "|---|---|---|---|---|",
    ]
    for did in sorted(records):
        r = records[did]
        mark = f"`{r['rerun']}`" if r.get("measured") else "—"
        lines.append(f"| {did} | [{r['title']}]({r['file']}) | "
                     f"{STATUS.get(r.get('status'), r.get('status'))} | "
                     f"{r.get('date')} | {mark} |")
    lines += ["", f"共 {len(records)} 筆。", ""]
    with open(INDEX, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))


def main(argv):
    records, problems = scan()
    for p in problems:
        print(f"FAIL  {p}")
    if problems:
        print(f"\n{len(problems)} problem(s) in {len(records)} decision record(s)")
        return 1
    if "--check" not in argv:
        write_index(records)
        print(f"artifact={INDEX}")
    measured = sum(1 for r in records.values() if r.get("measured"))
    print(f"OK    {len(records)} decision record(s), {measured} with a "
          "reproducible measurement")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

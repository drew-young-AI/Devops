#!/usr/bin/env python3
"""Every source this platform ingests must have a recorded publication cadence,
and every recorded cadence must carry its evidence.

WHY THIS IS CHECKED AT ALL.

docs/Backlog.md §20 contained a table of "actual update frequency" for five
sources, written from impression. When the publishers' catalogues were finally
queried, one of the five was wrong by two orders of magnitude: cdc-tb-caremag
was listed as annual and is declared `day` -- the dataset is titled
結核病每日縣市鄉鎮管理中個案. Nothing caught that for weeks, because an estimate
and a measurement look identical once they are both numbers in a table.

So the rule is not "have a cadence" but "have a cadence WITH ITS PROVENANCE",
and the provenance kinds are closed:

  declared     the publisher's own catalogue field (CKAN updated_freq)
  structural   the interface can only produce values that often (per-year URLs)
  no-evidence  neither exists, recorded as null and excluded from anything
               derived -- a default here would be a guess wearing the output
               format of a measurement

A source with ingest history and no row at all is the failure this is really
for: it is how a source ends up with no threshold, no alert, and no one
noticing it stopped.

Exit 0 if the table is complete and every row is justified, 1 otherwise.
"""
import argparse
import json
import subprocess
import sys

VALID_KINDS = {"declared", "structural", "no-evidence", "unknown"}

# The only intervals any evidence kind can currently yield. A number outside
# this set means someone typed one in, which is the thing the file exists to
# prevent -- so it is an error even though the number might be reasonable.
VALID_SECONDS = {None, 86400, 604800, 2592000, 31536000}


def ingested_sources(container):
    """The sources with ingest history, or None if the database is not here.

    FileNotFoundError is caught, not just a non-zero exit. `docker` is absent
    entirely on the Linux CI runner and on the ubu prod node, and an uncaught
    FileNotFoundError makes this exit with a traceback -- which the suite reads
    as "the cadence table is broken" rather than "there is no database here".
    A checker that crashes where its subject does not exist is a checker that
    turns a portability fact into a false defect. Found by running the tier-1
    suite on ubu (Linux) before pushing, rather than by CI afterwards.
    """
    try:
        out = subprocess.run(
            ["docker", "exec", container, "psql", "-U", "twin", "-d", "twin",
             "-At", "-c", "SELECT DISTINCT source FROM ingest_runs ORDER BY 1"],
            capture_output=True, text=True, timeout=60)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    return {s for s in out.stdout.strip().split("\n") if s}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--table", required=True)
    ap.add_argument("--container", default="station2-twin-db-1")
    ap.add_argument("--require-db", action="store_true",
                    help="fail rather than skip when the database is absent")
    args = ap.parse_args()

    table = json.load(open(args.table, encoding="utf-8"))
    problems = []

    if not table:
        problems.append("the cadence table is empty")

    for code, row in sorted(table.items()):
        kind = row.get("source")
        if kind not in VALID_KINDS:
            problems.append(f"{code}: provenance kind {kind!r} is not one of "
                            f"{sorted(VALID_KINDS)}")
        if not (row.get("evidence") or "").strip():
            problems.append(f"{code}: has no evidence line -- a number without "
                            f"provenance is an estimate")
        if row.get("seconds") not in VALID_SECONDS:
            problems.append(f"{code}: interval {row.get('seconds')!r} is not a "
                            f"value any evidence kind produces; it was typed in")
        if kind in ("no-evidence", "unknown") and row.get("seconds") is not None:
            problems.append(f"{code}: claims no evidence yet carries an interval")
        if kind in ("declared", "structural") and row.get("seconds") is None:
            problems.append(f"{code}: claims {kind} evidence yet has no interval")

    sources = ingested_sources(args.container)
    if sources is None:
        if args.require_db:
            problems.append("the database is unreachable and --require-db was given")
        else:
            print("  SKIP  database unreachable -- completeness UNVERIFIED",
                  file=sys.stderr)
    else:
        for code in sorted(sources - set(table)):
            problems.append(f"{code}: has ingest history but no row in the "
                            f"cadence table")
        for code in sorted(set(table) - sources):
            # Not an error: a source can be registered before its first load.
            print(f"  note  {code} is in the table but has never been ingested")

    kinds = {}
    for row in table.values():
        kinds[row.get("source")] = kinds.get(row.get("source"), 0) + 1
    print(f"  {len(table)} sources: " +
          ", ".join(f"{v} {k}" for k, v in sorted(kinds.items())))

    if problems:
        for p in problems:
            print(f"PROBLEM: {p}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

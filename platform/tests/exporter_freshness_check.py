#!/usr/bin/env python3
"""Cross-check the textfile-freshness thresholds against everything that
determines them.

Four facts have to agree, and they live in three different files:

  the rules file's THRESHOLD TABLE   what a human wrote down
  the rules file's EXPRESSION        what Prometheus actually evaluates
  platform/scheduler/jobs.conf       how often the writer really runs
  evidence/statusdag/*.prom          which files really exist

Any two of them agreeing proves nothing. The interesting failures are exactly
the disagreements: a cadence changed in jobs.conf and the threshold left
behind, a new exporter added with no rule, a threshold edited in the
expression while the comment still says the old number.

Exit 0 when all four agree, 1 otherwise, naming every disagreement.
"""
import argparse
import glob
import os
import re
import sys

import yaml

# "  #   host_disk.prom        disk            300        900"
TABLE_ROW = re.compile(
    r"^\s*#\s+([a-z_]+\.prom)\s+([a-z]+)\s+(\d+)\s+(\d+)\s*$", re.M)
# The matcher in the rules file is a regex on the full path, written in YAML as
#     file=~"(.*/)?host_disk\\.prom"
# so the literal text on disk contains a doubled backslash. This pulls the
# basename back out of it. Keyed on the basename because that is what the
# table, jobs.conf and the filesystem all agree on -- the directory prefix is a
# container mount detail and deliberately not part of the contract.
EXPR_TERM_RE = re.compile(
    r'node_textfile_mtime_seconds\{file=~"\(\.\*/\)\?'
    r'([a-z_]+)\\+\.prom"\}\s*>\s*(\d+)')


def expr_thresholds(text):
    return {f"{name}.prom": int(threshold)
            for name, threshold in EXPR_TERM_RE.findall(text)}


JOB_ROW = re.compile(r"^([a-z]+)\|(\d+)\|", re.M)

# The absent() rule cannot use a regex -- absent() propagates only equality
# matchers into its labels -- so it hardcodes node-exporter's mount target.
# That path is compose's, not the rule's, so it is read back out of compose
# and compared rather than trusted.
ABSENT_TERM_RE = re.compile(
    r'absent\(node_textfile_mtime_seconds\{file="([^"]+)"\}\)')
MOUNT_RE = re.compile(
    r"^\s*-\s*\S*evidence/statusdag:([^:\s]+)", re.M)

MULTIPLIER = 3  # two missed runs tolerated, the third alerts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rules", required=True)
    ap.add_argument("--jobs", required=True)
    ap.add_argument("--textfile-dir", required=True)
    ap.add_argument("--compose", required=True,
                    help="observability compose.yaml -- the mount target the "
                         "absent() matchers hardcode is read from here")
    args = ap.parse_args()

    rules_text = open(args.rules, encoding="utf-8").read()
    jobs_text = open(args.jobs, encoding="utf-8").read()

    table = {f: (job, int(iv), int(th))
             for f, job, iv, th in TABLE_ROW.findall(rules_text)}
    expr = expr_thresholds(rules_text)
    jobs = {j: int(iv) for j, iv in JOB_ROW.findall(jobs_text)}
    on_disk = {os.path.basename(p)
               for p in glob.glob(os.path.join(args.textfile_dir, "*.prom"))}
    compose_text = open(args.compose, encoding="utf-8").read()
    mounts = set(MOUNT_RE.findall(compose_text))
    absent_paths = ABSENT_TERM_RE.findall(rules_text)

    # A parser that stopped matching would report "0 rows, 0 disagreements,
    # all clean" -- the vacuous pass this repo keeps catching in its own gates.
    problems = []
    if not table:
        problems.append("the threshold table parsed to zero rows")
    if not expr:
        problems.append("the expression parsed to zero thresholds")
    if not jobs:
        problems.append("jobs.conf parsed to zero jobs")
    if not on_disk:
        problems.append(f"no .prom files under {args.textfile_dir}")
    if not mounts:
        problems.append("could not find the textfile mount in compose.yaml")
    if not absent_paths:
        problems.append("no absent() matcher found -- the never-appeared case is uncovered")

    for path in absent_paths:
        directory, base = os.path.split(path)
        if mounts and directory not in mounts:
            problems.append(
                f"{path}: absent() matcher points at {directory}, "
                f"compose mounts the textfile directory at {sorted(mounts)}")
        if base not in on_disk:
            problems.append(f"{path}: absent() matcher names a file nobody writes")
        if base not in table:
            problems.append(f"{path}: absent() matcher has no row in the threshold table")

    if not problems:
        for f in sorted(set(table) | set(expr) | on_disk):
            job, iv, th = table.get(f, (None, None, None))
            if f not in table:
                problems.append(f"{f}: written, but no row in the threshold table")
                continue
            if f not in expr:
                problems.append(f"{f}: in the table, but the expression never checks it")
            elif expr[f] != th:
                problems.append(
                    f"{f}: table says {th}s, expression says {expr[f]}s")
            if f not in on_disk:
                problems.append(
                    f"{f}: has a threshold, but no such file is written")
            if job not in jobs:
                problems.append(f"{f}: names writer job '{job}', absent from jobs.conf")
            elif jobs[job] != iv:
                problems.append(
                    f"{f}: table says {job} runs every {iv}s, "
                    f"jobs.conf says {jobs[job]}s")
            elif th != iv * MULTIPLIER:
                problems.append(
                    f"{f}: threshold {th}s is not {MULTIPLIER}x the "
                    f"{iv}s cadence ({iv * MULTIPLIER}s)")

    for f in sorted(table):
        job, iv, th = table[f]
        print(f"  {f:22s} {job:9s} every {iv:>6d}s   alert after {th:>6d}s")

    if problems:
        for p in problems:
            print(f"DISAGREEMENT: {p}", file=sys.stderr)
        return 1
    print(f"  absent() guards: {', '.join(sorted(absent_paths))}")
    print(f"  {len(table)} exporter(s); table, expression, jobs.conf, "
          f"compose mount and the written files all agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())

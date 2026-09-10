#!/usr/bin/env bash
# Does the SQL in the probes refer to things the database actually has?
#
# THE ERROR THIS EXISTS FOR, MADE THREE TIMES IN ONE SESSION.
#
#   probe_capability_catalog  guessed four JSON field names, missed all four,
#                             and reported 94 orphans while the generator that
#                             wrote the file reported zero.
#   a schema query            written against `surveillance_fact.quality_flag`,
#                             a column that does not exist anywhere.
#   a week lookup             written as `time_level = 'week'`. The values are
#                             'day', 'epi_week', 'year'. The query returned no
#                             rows -- which reads exactly like "there are no
#                             weekly facts", and would have been believed.
#
# The JSON half is covered by dag.EVIDENCE_READS. This is the SQL half, and it
# is deliberately DERIVED RATHER THAN DECLARED: a hand-written list of the
# columns each probe depends on is one more thing that can be written wrong by
# the same person who wrote the query wrong. Nothing here is typed twice --
# the tables, the columns and the compared literals are all extracted from the
# probe source and checked against information_schema and against the live
# column values.
#
# TIER 2. It needs the pilot database, because the whole claim is "the code and
# the schema agree" and half of that lives in the schema.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="sql-contract"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== 探針寫的 SQL 指得到資料庫真的有的東西 =="

run_cmd python3 - "$REPO_ROOT" <<'PY'
import re, pathlib, subprocess, sys

root = pathlib.Path(sys.argv[1])
src = (root / "platform" / "statusdag" / "dag.py").read_text(encoding="utf-8")

def q(sql):
    p = subprocess.run(["docker", "exec", "station2-twin-db-1", "psql", "-U", "twin",
                        "-d", "twin", "-tAc", sql], capture_output=True, text=True, timeout=30)
    if p.returncode != 0:
        sys.exit("REFUSING: cannot reach the pilot database: %s"
                 % " ".join(p.stderr.split())[:120])
    return [ln for ln in p.stdout.splitlines() if ln.strip()]

# ---- what the database has ------------------------------------------------
cols = {}
for row in q("SELECT table_name||'.'||column_name FROM information_schema.columns "
             "WHERE table_schema='public';"):
    t, c = row.split(".", 1)
    cols.setdefault(t, set()).add(c)
if len(cols) < 5:
    sys.exit("REFUSING: information_schema returned %d tables -- the scan is broken,"
             " not the schema" % len(cols))

# ---- what the probes say --------------------------------------------------
# Every psql("...") literal, including implicitly concatenated fragments.
statements = []
for m in re.finditer(r'psql\(\s*((?:"(?:[^"\\]|\\.)*"\s*)+)', src):
    statements.append(re.sub(r'"\s*"', "", m.group(1)).strip().strip('"'))
if len(statements) < 5:
    sys.exit("REFUSING: only %d SQL statements extracted from dag.py -- an empty"
             " scan is not a pass" % len(statements))

bad_table, bad_col, bad_value = [], [], []
for sql in statements:
    flat = " ".join(sql.split())
    # alias map: FROM/JOIN <table> [AS] <alias>
    alias = {}
    for t, a in re.findall(r"\b(?:FROM|JOIN)\s+([a-z_][a-z0-9_]*)\s*(?:AS\s+)?([a-z_][a-z0-9_]*)?",
                           flat, re.I):
        t = t.lower()
        if t in ("select", "on", "where"):
            continue
        # System catalogues are real and are not in information_schema's public
        # listing. probe_lineage queries pg_constraint deliberately -- it checks
        # that the CHECK constraint still EXISTS, which is the one thing a
        # dropped constraint does not tell you.
        if t.startswith("pg_") or t.startswith("information_schema"):
            continue
        if t not in cols:
            bad_table.append("%s (in: %s)" % (t, flat[:60]))
            continue
        alias[t] = t
        if a and a.lower() not in ("on", "where", "join", "left", "inner", "group",
                                   "order", "limit", "as", "filter"):
            alias[a.lower()] = t
    # qualified columns
    for a, c in re.findall(r"\b([a-z_][a-z0-9_]*)\.([a-z_][a-z0-9_]*)\b", flat):
        t = alias.get(a.lower())
        if t and c.lower() not in cols[t]:
            bad_col.append("%s.%s -> %s has no %s" % (a, c, t, c))
    # literals compared to a qualified column, checked against the real values
    for a, c, v in re.findall(r"\b([a-z_][a-z0-9_]*)\.([a-z_][a-z0-9_]*)\s*=\s*'([^']+)'", flat):
        t = alias.get(a.lower())
        if not t or c.lower() not in cols.get(t, ()):
            continue
        vals = q("SELECT DISTINCT %s FROM %s LIMIT 60;" % (c, t))
        if len(vals) < 60 and v not in vals:
            bad_value.append("%s.%s = '%s' but the column holds {%s}"
                             % (t, c, v, ", ".join(sorted(vals)[:6]) or "nothing"))

print("STATEMENTS %d" % len(statements))
print("TABLES %d" % len(cols))
print("BAD_TABLE %s" % ("; ".join(sorted(set(bad_table))) or "none"))
print("BAD_COLUMN %s" % ("; ".join(sorted(set(bad_col))) or "none"))
print("BAD_VALUE %s" % ("; ".join(sorted(set(bad_value))) or "none"))
PY
assert_rc 0 "the probes' SQL can be extracted and the schema read"
assert_output_contains "BAD_TABLE none" \
  "every table a probe queries exists"
assert_output_contains "BAD_COLUMN none" \
  "every qualified column a probe reads exists on the table it is read from"
assert_output_contains "BAD_VALUE none" \
  "every literal a probe compares a column against is a value that column actually holds -- 'week' vs 'epi_week' returns no rows and reads as 'there are none'"

# ---- the control: this guard must catch the two errors it was written for --
#
# A checker that says "none" over an extraction that found nothing passes just
# as loudly as one that checked everything. So the two mistakes actually made
# on 2026-09-10 are replayed here against a COPY of the probe source -- the
# file on disk is never touched -- and the checker must name both.
run_cmd python3 - "$REPO_ROOT" <<'PY'
import re, pathlib, subprocess, sys, tempfile, shutil, os
root = pathlib.Path(sys.argv[1])
src_path = root / "platform" / "statusdag" / "dag.py"
original = src_path.read_text(encoding="utf-8")

# The two real errors, verbatim in shape:
#   a column that does not exist anywhere  (surveillance_fact.quality_flag)
#   a literal that the column never holds  (time_level = 'week')
broken = original.replace("WHERE tp.time_level = 'epi_week' ",
                          "WHERE tp.time_level = 'week' ", 1)
broken = broken.replace("SELECT count(*) FROM data_source;",
                        "SELECT count(*) FROM data_source "
                        "WHERE data_source.quality_flag IS NULL;", 1)
if broken == original:
    sys.exit("REFUSING: neither mutation applied -- the control would pass "
             "without testing anything")

tmp = tempfile.mkdtemp()
try:
    shutil.copytree(root / "platform" / "statusdag", os.path.join(tmp, "statusdag"))
    open(os.path.join(tmp, "statusdag", "dag.py"), "w", encoding="utf-8").write(broken)
    # Re-run the same extraction against the mutated copy.
    src = broken
    def q(sql):
        p = subprocess.run(["docker", "exec", "station2-twin-db-1", "psql", "-U", "twin",
                            "-d", "twin", "-tAc", sql], capture_output=True, text=True,
                           timeout=30)
        return [ln for ln in p.stdout.splitlines() if ln.strip()]
    cols = {}
    for row in q("SELECT table_name||'.'||column_name FROM information_schema.columns "
                 "WHERE table_schema='public';"):
        t, c = row.split(".", 1)
        cols.setdefault(t, set()).add(c)
    statements = []
    for m in re.finditer(r'psql\(\s*((?:"(?:[^"\\]|\\.)*"\s*)+)', src):
        statements.append(re.sub(r'"\s*"', "", m.group(1)).strip().strip('"'))
    bad_col, bad_value = [], []
    for sql in statements:
        flat = " ".join(sql.split())
        alias = {}
        for t, a in re.findall(
                r"\b(?:FROM|JOIN)\s+([a-z_][a-z0-9_]*)\s*(?:AS\s+)?([a-z_][a-z0-9_]*)?",
                flat, re.I):
            t = t.lower()
            if t in cols:
                alias[t] = t
                if a and a.lower() not in ("on", "where", "join", "group", "order",
                                           "limit", "as", "filter"):
                    alias[a.lower()] = t
        for a, c in re.findall(r"\b([a-z_][a-z0-9_]*)\.([a-z_][a-z0-9_]*)\b", flat):
            t = alias.get(a.lower())
            if t and c.lower() not in cols[t]:
                bad_col.append("%s.%s" % (t, c))
        for a, c, v in re.findall(
                r"\b([a-z_][a-z0-9_]*)\.([a-z_][a-z0-9_]*)\s*=\s*'([^']+)'", flat):
            t = alias.get(a.lower())
            if not t or c.lower() not in cols.get(t, ()):
                continue
            vals = q("SELECT DISTINCT %s FROM %s LIMIT 60;" % (c, t))
            if len(vals) < 60 and v not in vals:
                bad_value.append("%s.%s='%s'" % (t, c, v))
    print("CONTROL_BAD_COLUMN %s" % (", ".join(sorted(set(bad_col))) or "none"))
    print("CONTROL_BAD_VALUE %s" % (", ".join(sorted(set(bad_value))) or "none"))
finally:
    shutil.rmtree(tmp, ignore_errors=True)
    print("UNTOUCHED %s" % (src_path.read_text(encoding="utf-8") == original))
PY
assert_rc 0 "the control runs against a copy"
assert_output_contains "CONTROL_BAD_COLUMN data_source.quality_flag" \
  "a column that exists nowhere is caught -- this is the mistake made three times on 2026-09-10"
assert_output_contains "CONTROL_BAD_VALUE time_period.time_level='week'" \
  "and a literal the column never holds is caught: 'week' returns no rows and reads as 'there are none'"
assert_output_contains "UNTOUCHED True" \
  "and the real source file was never modified"

suite_summary

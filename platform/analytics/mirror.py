#!/usr/bin/env python3
"""Read-only analytical mirror of the pilot database, as Parquet, read by DuckDB.

WHY IT EXISTS: measured, not assumed. See README.md -- aggregation queries go
from ~2.6s on Postgres to ~7ms here, and that is the difference between a
dashboard that can query live and one that has to precompute.

WHAT IT IS NOT: a replacement for Postgres. Postgres remains the source of
truth, handles writes, and still wins the indexed point query by 5.7x. This is
a derived, disposable, read-only copy.

THE ONLY RISK THAT MATTERS IS STALENESS.

A mirror that is 400x faster and quietly out of date is worse than the slow
query it replaced, because speed buys trust. So every mirror carries the
watermark it was built from, and `check` compares that against the live
database. A caller that skips the check gets refused, not warned: a warning
printed next to a number is read as a number.

Commands:
  build   rebuild the Parquet mirror and write the manifest
  check   compare the mirror's watermark against the live database
  query   run SQL against the mirror -- refuses if the mirror is stale
"""
from __future__ import annotations

import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
MIRROR_DIR = os.environ.get("MIRROR_DIR", os.path.join(HERE, "mirror"))
MANIFEST = os.path.join(REPO_ROOT, "evidence", "analytics", "mirror_manifest.json")

# The tables the mirror carries, and the name each is exposed as. Deliberately
# a short list: a mirror of everything is a second database to keep in sync,
# which is the operational cost this design exists to avoid.
TABLES = {
    "fact":   "surveillance_fact",
    "period": "time_period",
    "geo":    "geo_area",
    "disease": "disease",
    "metric": "metric",
}

RC_STALE = 1
RC_NOT_BUILT = 78          # same not-configured signal the rest of the platform uses


def pg_dsn():
    pw = os.environ.get("PGPASSWORD")
    if not pw:
        raise SystemExit("PGPASSWORD is not set. run.sh sources it from the "
                         "container without printing it.")
    return dict(host=os.environ.get("PGHOST", "127.0.0.1"),
                port=int(os.environ.get("PGPORT", "15432")),
                dbname=os.environ.get("PGDATABASE", "twin"),
                user=os.environ.get("PGUSER", "twin"),
                password=pw)


def live_watermark():
    """What the database says right now.

    Three components, because one is not enough: max(id) misses a rebuild that
    reuses ids, and a row count misses an in-place update. Together they catch
    every write path this pilot has -- every one of which goes through an
    ingest run.
    """
    import psycopg2
    with psycopg2.connect(**pg_dsn()) as conn, conn.cursor() as c:
        c.execute("SELECT coalesce(max(id), 0), coalesce(max(fetched_at)::text, '') "
                  "FROM ingest_runs")
        max_id, fetched = c.fetchone()
        c.execute("SELECT count(*) FROM surveillance_fact")
        (rows,) = c.fetchone()
    return {"max_ingest_id": int(max_id), "max_fetched_at": fetched,
            "fact_rows": int(rows)}


def read_manifest():
    if not os.path.isfile(MANIFEST):
        return None
    with open(MANIFEST, encoding="utf-8") as fh:
        return json.load(fh)


def cmd_build():
    import duckdb
    os.makedirs(MIRROR_DIR, exist_ok=True)
    os.makedirs(os.path.dirname(MANIFEST), exist_ok=True)

    # Read the watermark BEFORE the export, never after. Taking it afterwards
    # would record a watermark newer than the data actually copied if an ingest
    # lands mid-export -- a mirror that certifies itself fresher than it is.
    wm = live_watermark()

    d = duckdb.connect()
    d.execute("INSTALL postgres; LOAD postgres;")
    p = pg_dsn()
    d.execute(f"ATTACH 'host={p['host']} port={p['port']} dbname={p['dbname']} "
              f"user={p['user']} password={p['password']}' AS pg "
              "(TYPE postgres, READ_ONLY);")

    t0 = time.perf_counter()
    written = {}
    for alias, table in TABLES.items():
        out = os.path.join(MIRROR_DIR, f"{alias}.parquet")
        d.execute(f"COPY (SELECT * FROM pg.{table}) TO '{out}' (FORMAT parquet)")
        written[alias] = {"table": table, "bytes": os.path.getsize(out)}
        (n,) = d.execute(f"SELECT count(*) FROM '{out}'").fetchone()
        written[alias]["rows"] = int(n)
    elapsed = time.perf_counter() - t0

    # The mirror must agree with the source it claims to mirror. Checked, not
    # assumed -- a COPY that silently wrote 0 rows produces a valid Parquet file
    # and a dashboard full of zeroes.
    if written["fact"]["rows"] != wm["fact_rows"]:
        raise SystemExit(
            f"REFUSING: mirror has {written['fact']['rows']} fact rows, the "
            f"database has {wm['fact_rows']}. The export did not capture the "
            "table it claims to.")

    manifest = {
        "schema": "analytics-mirror/1",
        "built_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "build_seconds": round(elapsed, 2),
        "watermark": wm,
        "tables": written,
        "total_bytes": sum(t["bytes"] for t in written.values()),
    }
    with open(MANIFEST, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    mb = manifest["total_bytes"] / 1024 / 1024
    print(f"mirror rebuilt: {written['fact']['rows']:,} fact rows, "
          f"{mb:.0f} MB, {elapsed:.1f}s")
    print(f"artifact={MANIFEST}")
    return 0


def cmd_check(quiet=False):
    m = read_manifest()
    if m is None:
        if not quiet:
            print("mirror not built (no manifest). run: run.sh build")
        return RC_NOT_BUILT
    for alias in TABLES:
        if not os.path.isfile(os.path.join(MIRROR_DIR, f"{alias}.parquet")):
            if not quiet:
                print(f"mirror incomplete: {alias}.parquet is missing")
            return RC_NOT_BUILT
    live = live_watermark()
    if live != m["watermark"]:
        if not quiet:
            print("MIRROR IS STALE -- refusing to answer from it.")
            for k in live:
                if live[k] != m["watermark"].get(k):
                    print(f"  {k}: mirror={m['watermark'].get(k)!r} "
                          f"live={live[k]!r}")
            print("  rebuild: platform/analytics/run.sh build")
        return RC_STALE
    if not quiet:
        print(f"mirror is current (built {m['built_at']}, "
              f"{m['watermark']['fact_rows']:,} fact rows)")
    return 0


def cmd_query(sql):
    rc = cmd_check(quiet=True)
    if rc != 0:
        cmd_check()                      # print the reason
        return rc
    import duckdb
    d = duckdb.connect()
    for alias in TABLES:
        d.execute(f"CREATE VIEW {alias} AS SELECT * FROM "
                  f"'{os.path.join(MIRROR_DIR, alias + '.parquet')}'")
    t0 = time.perf_counter()
    rows = d.execute(sql).fetchall()
    cols = [c[0] for c in d.description]
    ms = (time.perf_counter() - t0) * 1000
    print("\t".join(cols))
    for r in rows[:200]:
        print("\t".join("" if v is None else str(v) for v in r))
    if len(rows) > 200:
        print(f"... {len(rows) - 200} more rows not shown")
    print(f"-- {len(rows)} rows in {ms:.1f} ms", file=sys.stderr)
    return 0


def cmd_refresh():
    """Rebuild only when the mirror is actually behind.

    The scheduled job runs this rather than `build`, because a rebuild costs 9
    seconds and the data changes on the order of days. Checking first makes the
    common case nearly free, and -- more importantly -- makes the job's log say
    "already current" instead of a rebuild that looks like work being done.
    """
    rc = cmd_check(quiet=True)
    if rc == 0:
        m = read_manifest()
        print(f"mirror already current (built {m['built_at']})")
        return 0
    print("mirror is behind; rebuilding" if rc == RC_STALE
          else "mirror not built; building")
    return cmd_build()


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    if cmd == "build":
        return cmd_build()
    if cmd == "check":
        return cmd_check()
    if cmd == "refresh":
        return cmd_refresh()
    if cmd == "query":
        if len(argv) < 3:
            print("usage: mirror.py query \"<sql>\"", file=sys.stderr)
            return 2
        return cmd_query(argv[2])
    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

#!/usr/bin/env python3
"""Pipeline metrics for the three things database constraints CANNOT catch.

WHY THIS IS NARROW ON PURPOSE.

Data QUALITY here is already enforced at write time: lineage is a CHECK
constraint, not a report, and 39 batches have converged under it. That layer
does not need monitoring -- a constraint cannot fail, it can only refuse. Adding
metrics over it would be a second source of truth for a question already
answered, which is how platforms end up with two dashboards that disagree.

So this covers only what constraints structurally cannot see:

  1. FRESHNESS   a source that SHOULD have updated and did not. A constraint
                 cannot see a thing that failed to happen.
  2. DRIFT       data that is valid but changed. Constraints check format and
                 conservation, never distribution.
  3. EXECUTION   how the batches themselves are going -- reject ratios, run
                 counts. `ingest_runs` has recorded this since day one and
                 nothing has ever turned it into a metric.

WHY YEAR-OVER-YEAR FOR DRIFT, AND NOT A TRAILING WINDOW.

This is epidemiological weekly data with heavy seasonality. "This week versus
the trailing eight weeks" would fire every single season change and be ignored
inside a month -- an alert that cries wolf on schedule is worse than no alert,
because it trains people to close it. Comparing an epi-week against THE SAME
epi-week a year earlier removes the seasonal term, which is the only comparison
that means anything here. Data spans 2005-2026, so the comparison exists.

WHAT THIS DELIBERATELY DOES NOT DO: it emits no verdicts and no thresholds.
Ratios and ages go out as gauges; what counts as too old or too different is an
alert rule, which lives with the other alert rules and can be reviewed as a
group. A threshold buried in a metrics exporter is a policy nobody can find.

CARDINALITY IS A DESIGN CONSTRAINT, NOT A DETAIL.
390 geo x 14 disease is 5,460 series per metric, on a laptop Prometheus with a
2 GB cap. Drift is therefore aggregated to per-disease, plus a COUNT of how many
geographies moved. The detail stays queryable in the mirror; only the summary
becomes a time series.

Usage:
  platform/dataops/run.sh                 # -> evidence/statusdag/dataops.prom
"""
from __future__ import annotations

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.environ.get("DATAOPS_PROM",
                     os.path.join(REPO_ROOT, "evidence", "statusdag", "dataops.prom"))

# A prior-year value below this makes the ratio meaningless: 1 case becoming 4
# is a 400% "drift" and is noise. Emitting it would bury the real signals.
YOY_FLOOR = 20
DRIFT_HIGH, DRIFT_LOW = 2.0, 0.5



# Sources whose ingest history is real but which will never be fetched again.
# Each needs a reason; a source with no reason does not belong here, and the
# zero-fact-rows assertion above is what stops this list from drifting.
RETIRED_SOURCES = {
    "cdc-rods": "the original combined RODS feed, replaced 2026-08-19 by the "
                "per-disease feeds; zero fact rows, no loader targets it",
}

def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"')


def pg():
    import psycopg2
    return psycopg2.connect(
        host=os.environ.get("PGHOST", "127.0.0.1"),
        port=int(os.environ.get("PGPORT", "15432")),
        dbname=os.environ.get("PGDATABASE", "twin"),
        user=os.environ.get("PGUSER", "twin"),
        password=os.environ["PGPASSWORD"])


def freshness_and_execution(lines):
    """Small tables, queried straight from Postgres -- the mirror would buy
    nothing here and would add a staleness question to a freshness metric,
    which is the one place that irony would actually cost something."""
    with pg() as conn, conn.cursor() as c:
        c.execute("""
            SELECT source,
                   extract(epoch FROM max(fetched_at))::bigint,
                   count(*),
                   coalesce(sum(rows_in_file), 0),
                   coalesce(sum(rows_accepted), 0),
                   coalesce(sum(rows_rejected), 0),
                   coalesce(sum(rows_inserted), 0),
                   count(*) FILTER (WHERE status <> 'ok')
            FROM ingest_runs GROUP BY 1 ORDER BY 1""")
        rows = c.fetchall()

        # Freshness is not reported for a source that has been retired.
        #
        # RETIRED IS A NAMED LIST, NOT A HEURISTIC.
        #
        # The first attempt inferred it -- "no fact rows means retired" -- and
        # immediately misclassified moi-admin-geography, which is live and
        # annual but loads geo_area, a table with no source_id at all. Guessing
        # a data mapping is how you get a metric that is confidently wrong, so
        # the list is explicit and the row count is an ASSERTION against it
        # rather than the thing that decides it.
        #
        # Why exclude at all: cdc-rods was the original combined RODS feed,
        # replaced by the per-disease feeds. It holds zero surveillance_fact
        # rows and is a target in no loader, so its age only ever increases --
        # a DataSourceStale warning, forever, about a source carrying nothing.
        # That alert was the ONLY thing that noticed the 14-day ingest outage
        # on 2026-09-03, and one permanently-warning member teaches people to
        # filter the whole class. Same rule and same reason as
        # reportable_tenants() in loki_coverage.py.
        #
        # Cumulative row counts below are unaffected: those are lineage, and
        # dropping them would be falsifying the history.
        c.execute("SELECT DISTINCT ds.code FROM surveillance_fact sf "
                  "JOIN data_source ds ON ds.source_id = sf.source_id")
        with_data = {r[0] for r in c.fetchall()}
        c.execute("SELECT DISTINCT ds.code FROM demographic_fact df "
                  "JOIN data_source ds ON ds.source_id = df.source_id")
        with_data |= {r[0] for r in c.fetchall()}

    known = {r[0] for r in rows}
    still_live = sorted(set(RETIRED_SOURCES) & with_data)
    if still_live:
        sys.exit(f"declared retired but still holding fact rows: {still_live}. "
                 f"Either the source came back or RETIRED_SOURCES is wrong; "
                 f"fix the list rather than the data.")
    retired = sorted(set(RETIRED_SOURCES) & known)
    fresh_rows = [r for r in rows if r[0] not in RETIRED_SOURCES]

    now = int(time.time())
    lines += [
        "# HELP dataops_source_last_fetch_timestamp_seconds Unix time of the "
        "most recent successful fetch for this source.",
        "# TYPE dataops_source_last_fetch_timestamp_seconds gauge",
    ]
    for (src, last, *_rest) in fresh_rows:
        lines.append(f'dataops_source_last_fetch_timestamp_seconds{{source="{esc(src)}"}} {last}')

    lines += [
        "# HELP dataops_source_age_seconds How long since this source last "
        "updated. A constraint cannot see a thing that failed to happen; this can.",
        "# TYPE dataops_source_age_seconds gauge",
    ]
    for (src, last, *_rest) in fresh_rows:
        lines.append(f'dataops_source_age_seconds{{source="{esc(src)}"}} {now - int(last)}')
    # Named, not silently dropped: a source that vanishes from freshness
    # without saying so is the same defect one level down.
    lines += [
        "# HELP dataops_source_retired 1 for a source with ingest history but no "
        "fact rows; excluded from freshness because it can never become fresh.",
        "# TYPE dataops_source_retired gauge",
    ] + [f'dataops_source_retired{{source="{esc(src)}"}} 1' for src in retired]

    lines += [
        "# HELP dataops_ingest_rows_total Cumulative rows by outcome, from "
        "ingest_runs -- recorded since day one, never surfaced until now.",
        "# TYPE dataops_ingest_rows_total counter",
    ]
    for (src, _last, _runs, in_file, acc, rej, ins, _bad) in rows:
        for outcome, n in (("in_file", in_file), ("accepted", acc),
                           ("rejected", rej), ("inserted", ins)):
            lines.append(f'dataops_ingest_rows_total{{source="{esc(src)}",'
                         f'outcome="{outcome}"}} {n}')

    lines += [
        "# HELP dataops_ingest_reject_ratio Rejected rows over rows in file. "
        "Emitted as a ratio, not a verdict -- the threshold is an alert rule.",
        "# TYPE dataops_ingest_reject_ratio gauge",
    ]
    for (src, _l, _r, in_file, _a, rej, _i, _b) in rows:
        ratio = (rej / in_file) if in_file else 0.0
        lines.append(f'dataops_ingest_reject_ratio{{source="{esc(src)}"}} {ratio:.6f}')

    lines += [
        "# HELP dataops_ingest_runs_failed_total Runs whose status was not ok.",
        "# TYPE dataops_ingest_runs_failed_total counter",
    ]
    for (src, *_m, bad) in rows:
        lines.append(f'dataops_ingest_runs_failed_total{{source="{esc(src)}"}} {bad}')
    return len(rows)


def drift(lines):
    """Year-over-year on the same epi-week, computed on the mirror.

    Returns the number of diseases reported. Emits nothing at all when the
    mirror is stale -- a drift number computed from an out-of-date copy is a
    statement about last week's data wearing this week's timestamp.
    """
    sys.path.insert(0, os.path.join(REPO_ROOT, "platform", "analytics"))
    import mirror as M                                            # noqa: E402

    stale = M.cmd_check(quiet=True)
    lines += [
        "# HELP dataops_mirror_stale 1 when drift could not be computed because "
        "the analytical mirror is not current.",
        "# TYPE dataops_mirror_stale gauge",
        f"dataops_mirror_stale {0 if stale == 0 else 1}",
    ]
    if stale != 0:
        return 0

    import duckdb
    d = duckdb.connect()
    for alias in M.TABLES:
        d.execute(f"CREATE VIEW {alias} AS SELECT * FROM "
                  f"'{os.path.join(M.MIRROR_DIR, alias + '.parquet')}'")

    # disease_id alone is unreadable on a dashboard a reviewer opens once a
    # month -- "disease_id 24 drifted" tells them nothing, "COVID-19 drifted"
    # tells them everything. Carried as a SECOND label rather than replacing
    # the id: the id is the join key and the stable one, the name is display.
    # A rename upstream must not silently become a different time series.
    names = {int(i): (n or c or str(i)) for i, c, n in d.execute(
        "SELECT disease_id, code, name_zh FROM disease").fetchall()}

    def lbl(dis):
        # Quotes and backslashes would break the exposition format. No name in
        # this dimension contains them today; sanitising anyway, because "no
        # bad data today" is a statement about today.
        nm = names.get(int(dis), str(dis)).replace("\\", "").replace('"', "")
        return f'disease_id="{dis}",disease="{nm}"'

    # WHICH WEEK COUNTS AS "SETTLED", AND WHY IT IS MEASURED RATHER THAN ASSUMED.
    #
    # The first version of this query stepped back a fixed `- 100` from the
    # latest week -- one whole YEAR -- on the stated reasoning that "the most
    # recent week is usually still filling in". The effect was that with data
    # running to 2026w32 it compared 2025w32 against 2024w32: the drift
    # detector was structurally blind to the entire current year, which is the
    # only year a pipeline fault could be introduced in. It still produced
    # numbers, and the numbers were plausible.
    #
    # The premise was also false for this source. Measured 2026-08-29: for
    # 12 of 13 diseases the newest week reports from as many geographies as
    # the median of the 12 weeks before it, and at least as many rows. This
    # feed publishes whole weeks after they close; it does not trickle.
    #
    # So the settle rule is now DATA-DRIVEN rather than a constant: take the
    # most recent week whose geographic coverage is at least the median of the
    # 12 weeks preceding it. If the source ever does start publishing partial
    # weeks, this steps back on its own instead of silently comparing a partial
    # week to a complete one -- and a constant tuned today would not.
    rows = d.execute(f"""
        WITH wk AS (
          SELECT f.disease_id, CAST(p.epi_year AS INTEGER) AS epi_year,
                 CAST(p.epi_week AS INTEGER) AS epi_week, f.geo_code,
                 SUM(f.value) AS v
          FROM fact f JOIN period p ON p.period_id = f.period_id
          WHERE p.epi_year IS NOT NULL AND p.epi_week IS NOT NULL
          GROUP BY 1,2,3,4
        ),
        cov AS (
          SELECT disease_id, epi_year * 100 + epi_week AS yw,
                 COUNT(DISTINCT geo_code) AS geos
          FROM wk GROUP BY 1,2
        ),
        cov_med AS (
          SELECT c.disease_id, c.yw, c.geos,
                 MEDIAN(p.geos) AS med_geos
          FROM cov c JOIN cov p
            ON p.disease_id = c.disease_id
           AND p.yw < c.yw AND p.yw >= c.yw - 12
          GROUP BY 1,2,3
        ),
        latest AS (
          SELECT disease_id, MAX(yw) AS ymax
          FROM cov_med WHERE geos >= med_geos GROUP BY 1
        ),
        cur AS (
          SELECT w.* FROM wk w JOIN latest l
            ON l.disease_id = w.disease_id
           AND w.epi_year * 100 + w.epi_week = l.ymax
        ),
        prev AS (
          SELECT w.* FROM wk w JOIN latest l
            ON l.disease_id = w.disease_id
           AND w.epi_year * 100 + w.epi_week = l.ymax - 100
        )
        SELECT c.disease_id,
               SUM(c.v)                                     AS cur_total,
               SUM(p.v)                                     AS prev_total,
               COUNT(*) FILTER (WHERE p.v >= {YOY_FLOOR}
                                  AND c.v / p.v > {DRIFT_HIGH})  AS n_up,
               COUNT(*) FILTER (WHERE p.v >= {YOY_FLOOR}
                                  AND c.v / p.v < {DRIFT_LOW})   AS n_down,
               COUNT(*) FILTER (WHERE p.v >= {YOY_FLOOR})        AS n_comparable
        FROM cur c JOIN prev p
          ON p.disease_id = c.disease_id AND p.geo_code = c.geo_code
        GROUP BY 1 ORDER BY 1""").fetchall()

    lines += [
        "# HELP dataops_yoy_ratio National total for the last settled epi-week "
        "over the same epi-week a year earlier. Year-over-year because this data "
        "is seasonal and a trailing window would fire every season.",
        "# TYPE dataops_yoy_ratio gauge",
    ]
    for (dis, cur, prev, _u, _dn, _n) in rows:
        if prev and prev >= YOY_FLOOR:
            lines.append(f'dataops_yoy_ratio{{{lbl(dis)}}} {cur / prev:.6f}')

    lines += [
        "# HELP dataops_yoy_geo_drift_count Geographies whose year-over-year "
        f"ratio left the {DRIFT_LOW}-{DRIFT_HIGH} band. Aggregated: 390 geo x 14 "
        "disease would be 5,460 series per metric on a 2 GB Prometheus.",
        "# TYPE dataops_yoy_geo_drift_count gauge",
    ]
    for (dis, _c, _p, up, down, _n) in rows:
        lines.append(f'dataops_yoy_geo_drift_count{{{lbl(dis)},'
                     f'direction="up"}} {up}')
        lines.append(f'dataops_yoy_geo_drift_count{{{lbl(dis)},'
                     f'direction="down"}} {down}')

    # Its own HELP/TYPE block, not squeezed into the loop above: the drift count
    # is meaningless without the denominator, and a metric with no HELP is a
    # number only its author can interpret.
    lines += [
        "# HELP dataops_yoy_geo_comparable_count Geographies with a prior-year "
        f"value of at least {YOY_FLOOR} -- the denominator for the drift count. "
        "Below that floor a ratio is noise: 1 case becoming 4 is not a 400% shift.",
        "# TYPE dataops_yoy_geo_comparable_count gauge",
    ]
    for (dis, _c, _p, _u, _d, comparable) in rows:
        lines.append(f'dataops_yoy_geo_comparable_count{{{lbl(dis)}}} '
                     f'{comparable}')
    return len(rows)


def main():
    lines = [
        "# Generated by platform/dataops/pipeline_metrics.py.",
        "# Covers only what write-time constraints cannot see: freshness, drift,",
        "# execution health. Data quality is enforced by CHECK constraints and is",
        "# deliberately NOT duplicated here.",
    ]
    n_src = freshness_and_execution(lines)
    n_dis = drift(lines)
    lines += [
        "# HELP dataops_metrics_generated_timestamp_seconds When this file was written.",
        "# TYPE dataops_metrics_generated_timestamp_seconds gauge",
        f"dataops_metrics_generated_timestamp_seconds {int(time.time())}",
        "",
    ]
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = OUT + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    # Atomic rename: node-exporter reads this directory continuously, and a
    # half-written .prom file makes it drop the whole scrape.
    os.replace(tmp, OUT)
    print(f"dataops metrics: {n_src} source(s), {n_dis} disease(s) with a "
          f"year-over-year comparison")
    print(f"artifact={OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

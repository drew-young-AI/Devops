"""Reproduce the numbers in README.md.

The README states that aggregation queries are 300-425x faster on the Parquet
mirror than on Postgres. A table of numbers with no way to re-run it is an
unverifiable claim, and this platform does not accept those from anyone --
including from itself. So the benchmark ships next to the claim.

Deterministic by construction: fixed queries, fixed order, one warm-up run
discarded, then N timed runs with the median reported. No random sampling and
no generated data -- the question is about THIS table, so it uses THIS table.

Three modes, because they differ in OPERATIONAL cost, not only in speed:
  pg        Postgres direct                zero new components (the baseline)
  duck_pg   DuckDB via postgres_scanner    one library, NO data copy
  duck_pq   DuckDB over the Parquet mirror one library + a copy to keep fresh

A mode that wins on time but needs a copy kept in sync has not necessarily won.
That is why duck_pq's export time and file size are reported alongside: they are
the price of the speed, and the freshness guard in mirror.py is what stops that
price from being paid in wrong answers.

Bounded on purpose (CLAUDE.md 5c): five short queries, N=5, seconds not minutes.
This is a laptop, and a benchmark that heats it up measures the cooling system.

Usage:
  platform/analytics/run.sh  is NOT used here -- this needs its own connection.
  PGPASSWORD=... PQ_PATH=platform/analytics/mirror venv/bin/python benchmark.py
"""

import os, statistics, sys, time
import duckdb, psycopg2

N = int(os.environ.get("BENCH_N", "5"))
PG = dict(host="127.0.0.1", port=15432, dbname="twin", user="twin",
          password=os.environ["PGPASSWORD"])
PQ = os.environ["PQ_PATH"]

# REFUSE to write into the live mirror. Learned by doing it: pointing PQ_PATH at
# platform/analytics/mirror/ made the benchmark overwrite the production Parquet
# files behind the manifest's back. It happened to be harmless -- same source,
# same data, so the watermark still matched -- but "happened to be harmless" is
# the description of a defect that has not bitten yet. A benchmark writes
# scratch data; it must not be able to touch the artifact the dashboard reads.
_MIRROR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mirror")
if os.path.abspath(PQ) == os.path.abspath(_MIRROR):
    raise SystemExit(
        "PQ_PATH points at the live mirror. Use a scratch directory -- this "
        "script rewrites the Parquet files it is given, and the mirror's "
        "manifest would then describe an export it did not make.")

QUERIES = {
"Q1 全國時間序列（折線圖）": """
  SELECT p.epi_year, p.epi_week, SUM(f.value) AS v
  FROM {F} f JOIN {T} p ON p.period_id = f.period_id
  WHERE f.disease_id = 5
  GROUP BY 1,2 ORDER BY 1,2""",

"Q2 地區排行 top 20（長條圖）": """
  SELECT f.geo_code, SUM(f.value) AS v
  FROM {F} f
  WHERE f.disease_id = 5
  GROUP BY 1 ORDER BY v DESC LIMIT 20""",

"Q3 疾病×年齡層 樞紐（熱圖）": """
  SELECT f.disease_id, f.age_band, SUM(f.value) AS v, COUNT(*) AS n
  FROM {F} f
  GROUP BY 1,2 ORDER BY 1,2""",

"Q4 全表彙總 group by geo（最壞情況）": """
  SELECT f.geo_code, COUNT(*) AS n, SUM(f.value) AS v, AVG(f.value) AS a
  FROM {F} f GROUP BY 1""",

"Q5 單點時間序列（索引友善）": """
  SELECT p.epi_year, p.epi_week, f.value
  FROM {F} f JOIN {T} p ON p.period_id = f.period_id
  WHERE f.geo_code = (SELECT geo_code FROM {F} LIMIT 1)
    AND f.disease_id = 5
  ORDER BY 1,2""",
}

def timed(fn, n=N):
    fn()                                  # warm-up, discarded
    ts = []
    for _ in range(n):
        t = time.perf_counter(); fn(); ts.append(time.perf_counter() - t)
    return statistics.median(ts), min(ts)

def main():
    results = {}

    # ---- mode pg -------------------------------------------------------
    conn = psycopg2.connect(**PG)
    def pg_run(sql):
        def f():
            with conn.cursor() as c:
                c.execute(sql); c.fetchall()
        return f
    for name, q in QUERIES.items():
        sql = q.format(F="surveillance_fact", T="time_period")
        results.setdefault(name, {})["pg"] = timed(pg_run(sql))
    conn.close()

    # ---- mode duck_pg --------------------------------------------------
    d = duckdb.connect()
    try:
        d.execute("INSTALL postgres; LOAD postgres;")
        d.execute("ATTACH 'host=127.0.0.1 port=15432 dbname=twin user=twin "
                  f"password={PG['password']}' AS pg (TYPE postgres, READ_ONLY);")
        for name, q in QUERIES.items():
            sql = q.format(F="pg.surveillance_fact", T="pg.time_period")
            results.setdefault(name, {})["duck_pg"] = timed(lambda s=sql: d.execute(s).fetchall())
    except Exception as e:
        print(f"duck_pg 不可用: {type(e).__name__}: {str(e)[:160]}", file=sys.stderr)

    # ---- mode duck_pq --------------------------------------------------
    t0 = time.perf_counter()
    d.execute(f"COPY (SELECT * FROM pg.surveillance_fact) TO '{PQ}/fact.parquet' (FORMAT parquet)")
    d.execute(f"COPY (SELECT * FROM pg.time_period) TO '{PQ}/period.parquet' (FORMAT parquet)")
    export_s = time.perf_counter() - t0
    d2 = duckdb.connect()
    for name, q in QUERIES.items():
        sql = q.format(F=f"'{PQ}/fact.parquet'", T=f"'{PQ}/period.parquet'")
        results.setdefault(name, {})["duck_pq"] = timed(lambda s=sql: d2.execute(s).fetchall())

    # ---- report --------------------------------------------------------
    print(f"\n  N={N}（丟棄 1 次暖身，取中位數）  單位：毫秒\n")
    print(f"  {'查詢':<34} {'pg':>10} {'duck_pg':>10} {'duck_pq':>10}   {'最快':>10}")
    print("  " + "-" * 82)
    for name, r in results.items():
        row = f"  {name:<34}"
        best, bestk = 1e9, ""
        for k in ("pg", "duck_pg", "duck_pq"):
            if k in r:
                ms = r[k][0] * 1000
                row += f" {ms:>10.1f}"
                if ms < best: best, bestk = ms, k
            else:
                row += f" {'—':>10}"
        row += f"   {bestk:>10}"
        print(row)
    print(f"\n  Parquet 匯出耗時：{export_s:.1f}s（這是 duck_pq 的維運成本，每次資料變動都要重跑）")
    sz = sum(os.path.getsize(os.path.join(PQ, f)) for f in os.listdir(PQ))
    print(f"  Parquet 大小：{sz/1024/1024:.0f} MB（Postgres heap 819 MB）")

main()

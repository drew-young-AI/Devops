#!/usr/bin/env python3
"""Load public-health feeds of different granularity into one fact table.

Four feeds, four different resolutions, no schema change between them:

  cdc-rods-ili     county   x epi_week   2007-2026   no denominator   flow
  cdc-nhi-ili      county   x epi_week   2016-2026   HAS denominator  flow
  cdc-tb-town      township x year       2005-2024   no denominator   flow
  cdc-tb-caremag   township x DAY        2016-2026   no denominator   STOCK

The last one is the finest granularity available in Taiwan CDC's open data --
found by calling package_show on all 73 datasets at data.cdc.gov.tw rather
than by guessing URLs. Nothing published is finer in both dimensions.

STOCK IS NOT FLOW, AND THE TABLE NOW SAYS SO.

CareMag publishes 管理中個案數: how many people are under TB treatment on that
date. That is a level, not a count of events. Summing it over a year counts
one patient once per day of a 6-9 month course, overstating by ~200x. Every
row therefore carries a metric whose measure_type is 'stock', and the
surveillance_rate view exposes it, so the query that would be wrong has to
first read the column saying it is wrong.

GEOGRAPHY COMES FROM AN AUTHORITY, NOT FROM THIS FILE.

Run load_geography.py first. Place names resolve by exact lookup against the
loaded 內政部 hierarchy, with non-exact spellings declared in
crosswalk/geo_alias.csv. A name that resolves to nothing is REJECTED. This
loader mints no keys -- that mistake is migration 005.

WHAT IS DELIBERATELY NOT DONE.

Age bands are stored verbatim. RODS uses 5 (0~6, 7~12, 13~18, 19~64, 65+), NHI
uses 9 with different cut points. Harmonising at load time destroys resolution
irreversibly and the schemes genuinely do not map onto each other.

CareMag's T_conf_* columns (sex, age, lab status breakdowns of the confirmed
count) are NOT loaded. They are overlapping subsets, not a partition:
T_conf_65plus and T_conf_afspos both count the same patients. Storing them as
age_band values would imply they sum to the total, which they do not.

MISSING IS NOT ZERO. Absent rows stay absent. Nothing defaults to 0, because a
reporting outage and an absence of disease must not look alike.

Usage:
  load_dimensional.py [--dry-run] [--sources rods,nhi,tb,caremag]
"""
import argparse
import csv
import hashlib
import io
import os
import re
import ssl
import sys
import urllib.request
from datetime import date, datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
      "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36")

_WS = re.compile(r"[\s　]+")


def norm(s):
    """Same normalisation as load_geography.py: whitespace out, 臺 -> 台."""
    return _WS.sub("", (s or "").strip()).replace("臺", "台")


# ── 度量：一個數字到底是什麼意思 ────────────────────────────────────────────
METRICS = {
    "ili_ed_visits": ("類流感急診就診人次", "flow", "人次",
                      "RODS 急診監測；期間內的事件計數，可沿時間加總"),
    "ili_visits": ("類流感健保就診人次", "flow", "人次",
                   "健保門診/住院；期間內的事件計數，可沿時間加總"),
    "tb_new_cases": ("結核病新案發生數", "flow", "人",
                     "年度內新通報個案；可沿時間加總"),
    "tb_under_management": ("結核病管理中個案數", "stock", "人",
                            "該日仍在治療管理中的人數；不可沿時間加總，"
                            "同一病人會在每一天各出現一次"),
    "tb_confirmed_under_management": ("結核病確診管理中個案數", "stock", "人",
                                      "管理中個案裡已確診者；同樣是存量"),
    "tb_mdr_under_management": ("多重抗藥性結核病管理中個案數", "stock", "人",
                                "管理中個案裡的 MDR-TB；同樣是存量"),
}

FEEDS = {
    "rods": dict(
        url="https://od.cdc.gov.tw/eic/RODS_Influenza_like_illness.csv",
        code="cdc-rods-ili", name="RODS 類流感急診監測",
        spatial="county", temporal="epi_week", denom=False,
        disease="influenza_like_illness", disease_zh="類流感",
        shape="county_week",
        measures=[("ili_ed_visits", "類流感急診就診人次", None)],
        visit_type="急診",
    ),
    "nhi": dict(
        url="https://od.cdc.gov.tw/eic/NHI_Influenza_like_illness.csv",
        code="cdc-nhi-ili", name="健保類流感就診統計",
        spatial="county", temporal="epi_week", denom=True,
        disease="influenza_like_illness", disease_zh="類流感",
        shape="county_week",
        measures=[("ili_visits", "類流感健保就診人次", "健保就診總人次")],
        visit_type=None,
    ),
    "tb": dict(
        url="https://od.cdc.gov.tw/chronic/tb_town_inc_num.csv",
        code="cdc-tb-town", name="結核病鄉鎮別新案發生數",
        spatial="township", temporal="year", denom=False,
        disease="tuberculosis", disease_zh="結核病",
        shape="township_year",
        measures=[("tb_new_cases", "發生數", None)],
        visit_type="通報",
    ),
    "caremag": dict(
        # Two files, one series: the source split it at the 2017 boundary.
        url=["https://od.cdc.gov.tw/chronic/CareMagOld.csv",
             "https://od.cdc.gov.tw/chronic/CareMagDailyList.csv"],
        code="cdc-tb-caremag", name="結核病每日縣市鄉鎮管理中個案",
        spatial="township", temporal="day", denom=False,
        disease="tuberculosis", disease_zh="結核病",
        shape="township_day",
        measures=[("tb_under_management", "manage_number", None),
                  ("tb_confirmed_under_management", "confirmed_number", None),
                  ("tb_mdr_under_management", "MDR_number", None)],
        visit_type="all",
    ),
}


def ssl_ctx():
    """certifi plus the intermediate od.cdc.gov.tw fails to send.

    See certs/README.md: the server presents a leaf issued by one TWCA CA and
    sends a different TWCA CA as the intermediate, so the chain does not link.
    Browsers fetch the real one via AIA; Python does not.
    """
    import certifi
    ctx = ssl.create_default_context(cafile=certifi.where())
    inter = HERE / "certs" / "twca-ssl-ca-2023.pem"
    if not inter.is_file():
        sys.exit(f"Missing pinned intermediate: {inter}")
    ctx.load_verify_locations(cafile=str(inter))
    return ctx


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, context=ssl_ctx(), timeout=600) as r:
        return r.read()


def rows_of(raw):
    """Lazy. CareMag is 1.55M rows; a list of dicts of it is ~2 GB of Python
    objects before a single row reaches the database."""
    return csv.DictReader(io.StringIO(raw.decode("utf-8-sig", "replace")))


class Geography:
    """Exact-lookup resolver over the loaded authority. Never guesses."""

    def __init__(self, cur):
        cur.execute("SELECT geo_code, geo_level, name, parent_code, code_system "
                    "FROM geo_area WHERE geo_level IN ('county','township')")
        self.by_code = {}
        self.county_by_name = {}
        self.town_by_county_name = {}
        rows = cur.fetchall()
        for code, level, name, parent, _sys in rows:
            self.by_code[code] = (level, name, parent)
            if level == "county":
                self.county_by_name[norm(name)] = code
        for code, level, name, parent, _sys in rows:
            if level == "township":
                self.town_by_county_name[(parent, norm(name))] = code
        cur.execute("SELECT source_code, raw_parent, raw_name, geo_code FROM geo_alias")
        self.alias = {(s, p, n): g for s, p, n, g in cur.fetchall()}
        if not self.by_code:
            sys.exit("geo_area is empty -- run load_geography.py first")

    def county(self, code, name):
        """RODS/NHI carry the official 5-digit code; trust it only if it exists."""
        if code in self.by_code and self.by_code[code][0] == "county":
            return code
        resolved = self.county_by_name.get(norm(name))
        if resolved:
            return resolved
        raise ValueError(f"county '{name}' / code '{code}' is not in the authority")

    def township(self, source_code, county_name, town_name):
        c_raw, t_raw = norm(county_name), norm(town_name)
        hit = self.alias.get((source_code, c_raw, t_raw))
        if hit:
            return hit
        county = self.county_by_name.get(c_raw)
        if county is None:
            raise ValueError(f"county '{county_name}' is not in the authority "
                             f"and has no alias for source {source_code}")
        town = self.town_by_county_name.get((county, t_raw))
        if town is None:
            raise ValueError(f"township '{county_name}{town_name}' is neither an "
                             f"official name nor a declared alias")
        return town


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--sources", default="rods,nhi,tb,caremag")
    args = ap.parse_args()
    wanted = [s.strip() for s in args.sources.split(",") if s.strip()]
    for w in wanted:
        if w not in FEEDS:
            sys.exit(f"unknown source '{w}'; known: {', '.join(FEEDS)}")

    import psycopg
    dsn = os.environ.get("DATABASE_URL") or (
        f"host={os.environ.get('PGHOST', '127.0.0.1')} "
        f"port={os.environ.get('PGPORT', '15432')} "
        f"dbname={os.environ.get('PGDATABASE', 'twin')} "
        f"user={os.environ.get('PGUSER', 'twin')} "
        f"password={os.environ.get('PGPASSWORD', '')}")
    conn = psycopg.connect(dsn, connect_timeout=10)
    cur = conn.cursor()
    geo = Geography(cur)

    def dim(table, pk, key, cols=(), vals=()):
        """Upsert one dimension row by its natural code, return the surrogate.

        DO UPDATE rather than DO NOTHING: DO NOTHING returns no row on
        conflict, so the RETURNING clause yields nothing and the second run of
        an unchanged pipeline fails on a None.
        """
        names = ", ".join(["code", *cols])
        ph = ", ".join(["%s"] * (1 + len(vals)))
        cur.execute(
            f"INSERT INTO {table} ({names}) VALUES ({ph}) "
            f"ON CONFLICT (code) DO UPDATE SET code = EXCLUDED.code RETURNING {pk}",
            (key, *vals))
        return cur.fetchone()[0]

    metric_id = {}
    for code, (zh, mtype, unit, note) in METRICS.items():
        metric_id[code] = dim("metric", "metric_id", code,
                              ("name_zh", "measure_type", "unit", "notes"),
                              (zh, mtype, unit, note))

    period_cache = {}

    def period(level, year, week, cal, seq):
        k = (level, year, week, cal)
        if k not in period_cache:
            cur.execute(
                "INSERT INTO time_period (time_level, epi_year, epi_week, cal_date, seq) "
                "VALUES (%s,%s,%s,%s,%s) "
                "ON CONFLICT (time_level, epi_year, epi_week, cal_date) "
                "DO UPDATE SET seq = EXCLUDED.seq RETURNING period_id",
                (level, year, week, cal, seq))
            period_cache[k] = cur.fetchone()[0]
        return period_cache[k]

    grand = {}
    for key in wanted:
        f = FEEDS[key]
        urls = f["url"] if isinstance(f["url"], list) else [f["url"]]
        raws, raw_len, sha = [], 0, hashlib.sha256()
        for u in urls:
            raw = fetch(u)
            sha.update(raw)
            raw_len += len(raw)
            raws.append(raw)
        digest = sha.hexdigest()
        print(f"\n  === {key} ===  {f['spatial']} x {f['temporal']}  "
              f"[{', '.join(m for m, _, _ in f['measures'])}]")
        print(f"  {raw_len:,} bytes  sha256 {digest[:16]}")
        if args.dry_run:
            first = next(iter(rows_of(raws[0])))
            print(f"  欄位: {list(first.keys())}")
            continue

        sid = dim("data_source", "source_id", f["code"],
                  ("name", "url", "spatial_level", "temporal_level", "has_denominator"),
                  (f["name"], urls[0], f["spatial"], f["temporal"], f["denom"]))
        did = dim("disease", "disease_id", f["disease"], ("name_zh",), (f["disease_zh"],))

        # PASS 1 -- parse to a compact shape, resolve geography, de-duplicate.
        #
        # One entry per SOURCE ROW, not per measurement, and the period is a
        # plain key rather than a database id. Expanding to metrics here would
        # triple the peak memory for CareMag, and resolving period ids here
        # would need the connection, which is about to be occupied by a COPY.
        #
        # THE SOURCE SHIPS DUPLICATES, AND ALSO SHIPS CONFLICTS. The two are
        # not the same thing and must not be handled the same way.
        #
        # CareMag repeats 187,724 byte-identical (county, township, date) rows
        # across 526 of its dates -- 12% of the file. Those are duplicates:
        # dropping the repeat loses nothing.
        #
        # But one pair collides with DIFFERENT values. 舊中縣/豐原市 and
        # 台中市/豐原區 both appear on 2021-08-23, and the alias correctly says
        # they are the same place -- yet one reports manage_number=1 and the
        # other 24. The first version of this loader compared keys only, so it
        # kept whichever row it met first and discarded the other without a
        # word. That is precisely the silent loss this pipeline exists to
        # refuse, committed by the de-duplicator meant to prevent it.
        #
        # So: identical values are a duplicate and are dropped quietly-but-
        # counted; differing values are a CONFLICT and the row is rejected with
        # its detail printed. Summing them would be a guess about whether the
        # two rows are disjoint cohorts or one restatement, and the data says
        # neither. `seen` therefore holds values, not just keys.
        staged, seen, rejected, dup, reasons, in_file = [], {}, 0, 0, {}, 0
        conflicts, conflict_samples = 0, []
        for raw in raws:
            for r in rows_of(raw):
                in_file += 1
                try:
                    if f["shape"] == "county_week":
                        year, week = int(r["年"]), int(r["週"])
                        if not (1 <= week <= 53):
                            raise ValueError(f"week out of range: {week}")
                        gcode = geo.county(r["縣市別代碼"].strip(), r["縣市"])
                        pkey = ("epi_week", year, week, None, year * 100 + week)
                        age = (r.get("年齡別") or "all").strip() or "all"
                        vtype = (r.get("就診類別") or f["visit_type"] or "all").strip()
                    elif f["shape"] == "township_year":
                        year = int(r["年別"])
                        gcode = geo.township(f["code"], r["縣市別"], r["鄉鎮別"])
                        pkey = ("year", year, None, None, year)
                        age, vtype = "all", f["visit_type"]
                    else:  # township_day
                        d = datetime.strptime(r["data_date"].split(" ")[0],
                                              "%Y/%m/%d").date()
                        gcode = geo.township(f["code"], r["city_name"], r["town_name"])
                        pkey = ("day", None, None, d, d.toordinal())
                        age, vtype = "all", f["visit_type"]

                    values = []
                    for mcode, vcol, dcol in f["measures"]:
                        v = (r.get(vcol) or "").strip()
                        if v == "":
                            # A blank cell is not a zero. Drop that measure,
                            # keep the row's others, and count it.
                            reasons[f"{mcode}: blank cell"] = \
                                reasons.get(f"{mcode}: blank cell", 0) + 1
                            rejected += 1
                            continue
                        denom = None
                        if dcol:
                            dv = (r.get(dcol) or "").strip()
                            denom = int(dv) if dv != "" else None
                        values.append((metric_id[mcode], int(v), denom))
                    if not values:
                        continue

                    natural = (gcode, pkey, age, vtype)
                    prior = seen.get(natural)
                    if prior is not None:
                        if prior == tuple(values):
                            dup += 1
                        else:
                            conflicts += 1
                            rejected += 1
                            if len(conflict_samples) < 5:
                                conflict_samples.append(
                                    f"{gcode} {pkey[3] or pkey[1]}: "
                                    f"{[v[1] for v in prior]} vs "
                                    f"{[v[1] for v in values]} "
                                    f"(來源 {r.get('city_name', '')}"
                                    f"{r.get('town_name', '')})")
                        continue
                    seen[natural] = tuple(values)
                    staged.append((gcode, pkey, age, vtype, values))
                except (ValueError, KeyError, TypeError) as exc:
                    rejected += 1
                    msg = str(exc)[:90]
                    reasons[msg] = reasons.get(msg, 0) + 1

        # PASS 2 -- create the periods this feed needs, once each.
        pid_of = {}
        for _g, pkey, _a, _v in ((s[0], s[1], s[2], s[3]) for s in staged):
            if pkey not in pid_of:
                pid_of[pkey] = period(pkey[0], pkey[1], pkey[2], pkey[3], pkey[4])

        # PASS 3 -- COPY into a temp table, then one set-based upsert.
        #
        # Row-at-a-time INSERT managed ~180 rows/sec, which is six hours for
        # this feed. TEMP so it dies with the connection and can never be
        # mistaken for real data.
        cur.execute("CREATE TEMP TABLE stage (LIKE surveillance_fact "
                    "INCLUDING DEFAULTS) ON COMMIT DROP")
        cur.execute("ALTER TABLE stage DROP COLUMN id, DROP COLUMN ingested_at")
        written = 0
        with cur.copy("COPY stage (source_id, disease_id, metric_id, geo_code, "
                      "period_id, age_band, visit_type, value, denominator) "
                      "FROM STDIN") as cp:
            for gcode, pkey, age, vtype, values in staged:
                pid = pid_of[pkey]
                for mid, value, denom in values:
                    cp.write_row((sid, did, mid, gcode, pid, age, vtype, value, denom))
                    written += 1
        cur.execute("""
            INSERT INTO surveillance_fact
                (source_id, disease_id, metric_id, geo_code, period_id,
                 age_band, visit_type, value, denominator)
            SELECT source_id, disease_id, metric_id, geo_code, period_id,
                   age_band, visit_type, value, denominator FROM stage
            ON CONFLICT ON CONSTRAINT surveillance_fact_natural DO UPDATE
                SET value = EXCLUDED.value,
                    denominator = EXCLUDED.denominator,
                    ingested_at = now()
        """)
        upserted = cur.rowcount

        cur.execute(
            "INSERT INTO ingest_runs (source, source_url, fetched_at, content_sha256, "
            " content_bytes, rows_in_file, rows_accepted, rows_rejected, rows_inserted, "
            " rows_updated, status, note) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
            (f["code"], " ".join(urls), datetime.now(timezone.utc), digest, raw_len,
             in_file, written, rejected, upserted, 0,
             "ok" if conflicts == 0 else "ok-with-conflicts",
             f"duplicates_in_source={dup} conflicts={conflicts} "
             f"metrics={len(f['measures'])} periods={len(pid_of)}"))
        conn.commit()

        print(f"  {in_file:,} 列  來源重複: {dup:,}   衝突: {conflicts:,}   "
              f"拒絕: {rejected:,}   事實列: {upserted:,}   期間: {len(pid_of):,}")
        for s in conflict_samples:
            print(f"    CONFLICT {s}")
        for msg, n in sorted(reasons.items(), key=lambda kv: -kv[1])[:4]:
            print(f"    reject x{n:,}: {msg}")
        grand[key] = upserted

    if not args.dry_run:
        cur.execute("SELECT COUNT(*) FROM surveillance_fact")
        print(f"\n  surveillance_fact 總列數: {cur.fetchone()[0]:,}")
        cur.execute("""
            SELECT s.code, m.measure_type, COUNT(*)
              FROM surveillance_fact f
              JOIN data_source s ON s.source_id = f.source_id
              JOIN metric      m ON m.metric_id = f.metric_id
             GROUP BY 1,2 ORDER BY 1,2""")
        for code, mt, n in cur.fetchall():
            print(f"    {code:<16} {mt:<6} {n:>10,}")
    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

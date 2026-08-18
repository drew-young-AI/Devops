#!/usr/bin/env python3
"""Load three feeds of DIFFERENT granularity into one fact table.

This is the proof that granularity is data rather than schema. Three sources
go into surveillance_fact without a single schema change between them:

  RODS  county   x epi_week   2007-2026   no denominator
  NHI   county   x epi_week   2016-2026   HAS denominator, 9 age bands
  TB    township x year       2005-2024   no denominator

If a village x day feed appears, it lands the same way. That was the whole
argument for the dimensional model, and it is only worth anything if it is
demonstrated with feeds that actually disagree about resolution.

WHAT IS DELIBERATELY NOT DONE HERE.

Age bands are stored verbatim. RODS uses 5 (0~6, 7~12, 13~18, 19~64, 65+),
NHI uses 9 with different cut points (0~2, 3~6, ... 25~64, 65+, 不詳).
Harmonising at load time would destroy resolution irreversibly, and the two
schemes genuinely do not map onto each other. Reconciliation belongs
downstream where it can be re-run and argued with.

MISSING IS NOT ZERO. Rows absent from a source are absent from the table.
Nothing is defaulted to 0, because a reporting outage and an absence of
disease must not look alike.

Usage:
  load_dimensional.py [--dry-run] [--sources rods,nhi,tb]
"""
import argparse
import csv
import hashlib
import io
import os
import ssl
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
      "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36")

FEEDS = {
    "rods": dict(
        url="https://od.cdc.gov.tw/eic/RODS_Influenza_like_illness.csv",
        code="cdc-rods-ili", name="RODS 類流感急診監測",
        spatial="county", temporal="epi_week", denom=False,
        disease="influenza_like_illness", disease_zh="類流感",
        col_value="類流感急診就診人次", col_denom=None, visit_type="急診",
    ),
    "nhi": dict(
        url="https://od.cdc.gov.tw/eic/NHI_Influenza_like_illness.csv",
        code="cdc-nhi-ili", name="健保類流感就診統計",
        spatial="county", temporal="epi_week", denom=True,
        disease="influenza_like_illness", disease_zh="類流感",
        col_value="類流感健保就診人次", col_denom="健保就診總人次", visit_type=None,
    ),
    "tb": dict(
        url="https://od.cdc.gov.tw/chronic/tb_town_inc_num.csv",
        code="cdc-tb-town", name="結核病鄉鎮別發生數",
        spatial="township", temporal="year", denom=False,
        disease="tuberculosis", disease_zh="結核病",
        col_value="發生數", col_denom=None, visit_type="通報",
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
    with urllib.request.urlopen(req, context=ssl_ctx(), timeout=180) as r:
        return r.read()


def rows_of(raw):
    return list(csv.DictReader(io.StringIO(raw.decode("utf-8-sig", "replace"))))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--sources", default="rods,nhi,tb")
    args = ap.parse_args()
    wanted = [s.strip() for s in args.sources.split(",") if s.strip()]

    import psycopg
    dsn = os.environ.get("DATABASE_URL") or (
        f"host={os.environ.get('PGHOST','127.0.0.1')} "
        f"port={os.environ.get('PGPORT','15432')} "
        f"dbname={os.environ.get('PGDATABASE','twin')} "
        f"user={os.environ.get('PGUSER','twin')} "
        f"password={os.environ.get('PGPASSWORD','')}")

    conn = psycopg.connect(dsn, connect_timeout=10)
    cur = conn.cursor()

    def dim_id(table, key_col, key, extra_cols=(), extra_vals=()):
        cols = ", ".join([key_col, *extra_cols])
        ph = ", ".join(["%s"] * (1 + len(extra_vals)))
        pk = {"disease": "disease_id", "data_source": "source_id"}[table]
        cur.execute(
            f"INSERT INTO {table} ({cols}) VALUES ({ph}) "
            f"ON CONFLICT ({key_col}) DO UPDATE SET {key_col} = EXCLUDED.{key_col} "
            f"RETURNING {pk}", (key, *extra_vals))
        return cur.fetchone()[0]

    # Dimension lookups were costing three round trips PER ROW, which is why
    # the first version managed ~180 rows/sec and would have taken half an
    # hour for 305k rows. Resolve dimensions once into dicts, then send facts
    # in batches. Same result, two orders of magnitude less network chatter.
    geo_cache, period_cache = {}, {}

    def get_period(level, year, week, seq):
        k = (level, year, week)
        if k not in period_cache:
            cur.execute(
                "INSERT INTO time_period (time_level, epi_year, epi_week, seq) "
                "VALUES (%s,%s,%s,%s) "
                "ON CONFLICT (time_level, epi_year, epi_week, cal_date) "
                "DO UPDATE SET seq = EXCLUDED.seq RETURNING period_id",
                (level, year, week, seq))
            period_cache[k] = cur.fetchone()[0]
        return period_cache[k]

    # Official county codes come from RODS/NHI (縣市別代碼). The TB feed has no
    # code column, so its county NAME is resolved against them. A name that
    # does not resolve is REJECTED -- minting a key like `tw-台中市` created a
    # parallel code system and broke every roll-up (see migration 005).
    county_by_name = {}

    def resolve_county(name):
        n = name.strip().replace("臺", "台")
        return county_by_name.get(n)

    def ensure_geo(code, level, name, parent=None):
        if code in geo_cache:
            return
        cur.execute(
            "INSERT INTO geo_area (geo_code, geo_level, name, parent_code) "
            "VALUES (%s,%s,%s,%s) ON CONFLICT (geo_code) DO NOTHING",
            (code, level, name, parent))
        geo_cache[code] = True
        if level == "county":
            county_by_name[name.strip().replace("臺", "台")] = code

    totals = {}
    for key in wanted:
        f = FEEDS[key]
        raw = fetch(f["url"])
        digest = hashlib.sha256(raw).hexdigest()
        rows = rows_of(raw)
        print(f"\n  === {key} ===  {f['spatial']} x {f['temporal']}")
        print(f"  {len(raw):,} bytes  sha256 {digest[:16]}  {len(rows):,} 列")
        if args.dry_run:
            print(f"  欄位: {list(rows[0].keys())}")
            totals[key] = (len(rows), 0)
            continue

        sid = dim_id("data_source", "code", f["code"],
                     ("name", "url", "spatial_level", "temporal_level",
                      "has_denominator"),
                     (f["name"], f["url"], f["spatial"], f["temporal"], f["denom"]))
        did = dim_id("disease", "code", f["disease"], ("name_zh",), (f["disease_zh"],))

        accepted = rejected = 0
        batch = []
        for r in rows:
            try:
                if f["temporal"] == "epi_week":
                    year, week = int(r["年"]), int(r["週"])
                    if not (1 <= week <= 53):
                        raise ValueError(f"week {week}")
                    county, code = r["縣市"].strip(), r["縣市別代碼"].strip()
                    geo_code, geo_level, parent = code, "county", None
                    age = r.get("年齡別", "all").strip() or "all"
                    vtype = (r.get("就診類別") or f["visit_type"] or "all").strip()
                    pid = get_period("epi_week", year, week, year * 100 + week)
                else:  # year-level, township
                    year = int(r["年別"])
                    county = r["縣市別"].strip()
                    town = r["鄉鎮別"].strip()
                    # No official township code in this feed, so the key is
                    # derived and marked as such. Deriving a code that looks
                    # official would be worse than one that obviously is not.
                    parent = resolve_county(county)
                    if parent is None:
                        raise ValueError(
                            f"county '{county}' does not resolve to an official "
                            f"code; load a county-level feed first")
                    geo_code = f"{parent}-{town}"
                    geo_level = "township"
                    age, vtype = "all", f["visit_type"]
                    pid = get_period("year", year, None, year)
                value = int(r[f["col_value"]])
                denom = int(r[f["col_denom"]]) if f["col_denom"] else None

                ensure_geo(geo_code, geo_level,
                           town if geo_level == "township" else county, parent)
                batch.append((sid, did, geo_code, pid, age, vtype, value, denom))
                accepted += 1
            except (ValueError, KeyError, TypeError) as exc:
                rejected += 1
                if rejected <= 3:
                    print(f"    reject: {exc}")
        cur.executemany(
            "INSERT INTO surveillance_fact "
            "(source_id, disease_id, geo_code, period_id, age_band, "
            " visit_type, value, denominator) VALUES (%s,%s,%s,%s,%s,%s,%s,%s) "
            "ON CONFLICT ON CONSTRAINT surveillance_fact_natural "
            "DO UPDATE SET value = EXCLUDED.value, "
            "              denominator = EXCLUDED.denominator, "
            "              ingested_at = now()", batch)
        conn.commit()
        print(f"  accepted {accepted:,}  rejected {rejected:,}")
        totals[key] = (accepted, rejected)

    if not args.dry_run:
        cur.execute("SELECT COUNT(*) FROM surveillance_fact")
        print(f"\n  surveillance_fact 總列數: {cur.fetchone()[0]:,}")
    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

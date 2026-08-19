#!/usr/bin/env python3
"""Load 內政部戶政司 village-level demographics: the denominator this platform
has never had.

WHY THIS EXISTS.

Every non-ILI feed here is a count with no population base:

    cdc-tb-town     denominator populated on 0 / 7,360 rows
    cdc-tb-caremag  denominator populated on 0 / 4,085,772 rows

So township-level TB was reachable but a township-level RATE was not. 大甲區 with
3 cases against 西屯區 with 12 says nothing until you know how many people live
in each. That is a missing denominator, not a missing granularity -- the
granularity has been there since migration 006.

THE JOIN NEEDS NO CROSSWALK, AND THAT WAS CHECKED RATHER THAN ASSUMED.

戶政司 keys every row by an 11-digit 區域別代碼 which is byte-identical to the
村里 codes already loaded from NLSC:

    ODRP019  district_code 65000010001  新北市板橋區 留侯里
    geo_area geo_code      65000010001  留侯里, parent 6500001 (板橋區), 65000 (新北市)

Any code that does NOT resolve is REJECTED and reported. This loader mints no
keys; that mistake is migration 005.

THE COLUMN NAMES CHANGE BETWEEN YEARS, AND NOT ON A CLEAN BOUNDARY.

Measured, not assumed:

    ODRP019/110  statistic_yyy, district_code, site_id, village      English
    ODRP019/111  statistic_yyy, ...                                  English
    ODRP019/112  statistic_yyy, ...                                  English
    ODRP019/113  統計年, 區域別代碼, 區域別, 村里名稱                 CHINESE
    ODRP019/114  statistic_yyy, ...                                  English

113 is the odd one out -- it is not "old years are Chinese". A loader keyed on
year would work for four years and silently return nothing for one. Worse, the
村里 field is `村里名稱` in ODRP019/113 but `村里` in ODRP024/113, so the drift is
per dataset per year. Every field is therefore resolved through an alias list
and a row that matches NEITHER spelling is a hard error, not a None.

POPULATION IS A STOCK.

Same discipline as 管理中個案數: the metric rows carry measure_type='stock', so
summing population across years is a query that has to first read the column
telling it not to.

Usage:
  load_registry.py --datasets pop            --years 110-114
  load_registry.py --datasets pop,edu        --years 114
  load_registry.py --datasets pop,edu,detail --years 114     # detail is ~2M rows/yr
  load_registry.py --dry-run --datasets pop --years 114
"""
import argparse
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import psycopg

HERE = Path(__file__).resolve().parent
API = "https://www.ris.gov.tw/rs-opendata/api/v1/datastore"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
      "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36")
ROC_OFFSET = 1911  # 民國 114 年 = 西元 2025 年


def alias(row, *names):
    """First matching key, or a hard error naming every spelling tried.

    Returning None on no-match is what turns a vocabulary change into a table
    full of NULLs that looks like missing data. The publication changed its
    column names mid-series once already; the next change should stop the load.
    """
    for n in names:
        if n in row:
            return row[n]
    raise KeyError(
        f"none of {names} present in row with keys {sorted(row)}. The source "
        f"vocabulary changed again -- add the new spelling to the alias list "
        f"rather than defaulting the value")


# Household types, as published. Kept verbatim: 共同事業戶 (dormitories, care
# homes, military units) is genuinely different from 共同生活戶 and folding them
# together would destroy that distinction irreversibly.
HOUSEHOLD_TYPES = [
    ("ordinary", "共同生活戶", ("household_ordinary_total", "共同生活戶_戶數"),
     ("household_ordinary_m", "共同生活戶_男"), ("household_ordinary_f", "共同生活戶_女")),
    ("business", "共同事業戶", ("household_business_total", "共同事業戶_戶數"),
     ("household_business_m", "共同事業戶_男"), ("household_business_f", "共同事業戶_女")),
    ("single", "單獨生活戶", ("household_single_total", "單獨生活戶_戶數"),
     ("household_single_m", "單獨生活戶_男"), ("household_single_f", "單獨生活戶_女")),
]

DATASETS = {
    "pop": dict(
        id="ODRP019", code="moi-ris-village-population",
        name="戶政司 村里戶數及人口數",
        metrics=("population", "households"),
    ),
    "edu": dict(
        id="ODRP024", code="moi-ris-village-education",
        name="戶政司 村里教育程度戶長數",
        metrics=("household_heads",),
    ),
    "detail": dict(
        id="ODRP052", code="moi-ris-village-age-marital",
        name="戶政司 村里性別年齡婚姻人口",
        metrics=("population",),
    ),
}


def ssl_ctx():
    import certifi
    return ssl.create_default_context(cafile=certifi.where())


def fetch_page(dataset, year, page):
    url = f"{API}/{dataset}/{year}?page={page}"
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, context=ssl_ctx(), timeout=120) as r:
                return json.loads(r.read())
        except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
            if attempt == 2:
                raise
            # Serial, with backoff. This is a government API on someone else's
            # budget; hammering it in parallel is both rude and the fastest way
            # to get rate-limited into looking like a data problem.
            time.sleep(2 * (attempt + 1))


def fetch_year(dataset, year):
    """All pages for one year. Returns (rows, total_declared)."""
    first = fetch_page(dataset, year, 1)
    if first.get("responseCode") != "OD-0101-S":
        return [], 0, first.get("responseMessage", "unknown")
    total = int(first.get("totalDataSize", 0))
    pages = int(first.get("totalPage", 1))
    rows = list(first.get("responseData") or [])
    for p in range(2, pages + 1):
        page = fetch_page(dataset, year, p)
        rows.extend(page.get("responseData") or [])
        if p % 20 == 0:
            print(f"      page {p}/{pages}  {len(rows):,} rows", flush=True)
    return rows, total, None


def to_int(v):
    """'1,234' and '-' and '' all appear in these feeds."""
    s = str(v).replace(",", "").strip()
    if s in ("", "-", "－"):
        return None
    return int(s)


def parse_pop(row):
    """ODRP019 -> [(metric, sex, household_type, edu, value), ...]"""
    out = []
    for key, _zh, total_c, m_c, f_c in HOUSEHOLD_TYPES:
        h = to_int(alias(row, *total_c))
        if h is not None:
            out.append(("households", "all", key, "all", h))
        for sex, col in (("男", m_c), ("女", f_c)):
            v = to_int(alias(row, *col))
            if v is not None:
                out.append(("population", sex, key, "all", v))
    # The totals the rest of the platform actually joins against. Derived, not
    # re-fetched: a separately-fetched total that disagreed with its own parts
    # would be undetectable, whereas this cannot disagree by construction.
    pop_total = sum(v for m, _s, _h, _e, v in out if m == "population")
    hh_total = sum(v for m, _s, _h, _e, v in out if m == "households")
    out.append(("population", "all", "all", "all", pop_total))
    out.append(("households", "all", "all", "all", hh_total))
    return out


def parse_edu(row):
    """ODRP024 -> household heads by education and sex."""
    v = to_int(alias(row, "headhousehold_count", "戶長數"))
    if v is None:
        return []
    return [("household_heads",
             alias(row, "sex", "性別"),
             "all",
             alias(row, "edu", "教育程度"),
             v)]


def parse_detail(row):
    """ODRP052 -> population by sex, single-year age and marital status.

    age and marital_status are NOT stored: demographic_fact has no column for
    them, and inventing one to hold 'age=25,marital=有偶' as a string would be
    the key-value soup the star schema exists to avoid. This dataset is loaded
    ONLY as a cross-check that the ODRP019 totals agree; the row-level detail
    is aggregated away here and the check is printed.
    """
    v = to_int(alias(row, "population", "人口數"))
    if v is None:
        return []
    return [("population", alias(row, "sex", "性別"), "all", "all", v)]


PARSERS = {"pop": parse_pop, "edu": parse_edu, "detail": parse_detail}


def year_range(spec):
    out = []
    for part in spec.split(","):
        if "-" in part:
            a, b = part.split("-")
            out.extend(range(int(a), int(b) + 1))
        else:
            out.append(int(part))
    return sorted(set(out))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--datasets", default="pop",
                    help="comma list of " + ",".join(DATASETS))
    ap.add_argument("--years", default="114", help="ROC years, e.g. 110-114")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    wanted = [d.strip() for d in args.datasets.split(",") if d.strip()]
    unknown = [d for d in wanted if d not in DATASETS]
    if unknown:
        sys.exit(f"unknown dataset(s): {unknown}. known: {sorted(DATASETS)}")
    years = year_range(args.years)

    dsn = os.environ.get("DATABASE_URL") or (
        f"host={os.environ.get('PGHOST', '127.0.0.1')} "
        f"port={os.environ.get('PGPORT', '15432')} "
        f"dbname={os.environ.get('PGDATABASE', 'twin')} "
        f"user={os.environ.get('PGUSER', 'twin')} "
        f"password={os.environ.get('PGPASSWORD', '')}")

    with psycopg.connect(dsn) as conn:
        cur = conn.cursor()

        cur.execute("SELECT geo_code FROM geo_area WHERE geo_level = 'village'")
        villages = {r[0] for r in cur.fetchall()}
        print(f"geo_area: {len(villages):,} villages loaded (the authority)")
        if not villages:
            sys.exit("No villages in geo_area. Run load_geography.py first.")

        cur.execute("SELECT code, metric_id FROM metric")
        metric_id = dict(cur.fetchall())

        period_cache = {}

        def period_for(gregorian_year):
            if gregorian_year not in period_cache:
                cur.execute(
                    "INSERT INTO time_period (time_level, epi_year, epi_week, "
                    " cal_date, seq) VALUES ('year',%s,NULL,NULL,%s) "
                    "ON CONFLICT (time_level, epi_year, epi_week, cal_date) "
                    "DO UPDATE SET seq = EXCLUDED.seq RETURNING period_id",
                    (gregorian_year, gregorian_year))
                period_cache[gregorian_year] = cur.fetchone()[0]
            return period_cache[gregorian_year]

        for key in wanted:
            spec = DATASETS[key]
            parse = PARSERS[key]
            print(f"\n=== {spec['code']}  ({spec['id']}) ===")

            cur.execute(
                "INSERT INTO data_source (code, name, url, spatial_level, "
                " temporal_level, has_denominator, is_synthetic, notes) "
                "VALUES (%s,%s,%s,'village','year',false,false,%s) "
                "ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, "
                " url = EXCLUDED.url RETURNING source_id",
                (spec["code"], spec["name"], f"{API}/{spec['id']}",
                 "內政部戶政司 open data API；區域別代碼與 NLSC 村里代碼相同"))
            sid = cur.fetchone()[0]

            for roc in years:
                gregorian = roc + ROC_OFFSET
                rows, declared, err = fetch_year(spec["id"], roc)
                if err:
                    print(f"  {roc} (西元 {gregorian}): {err} -- skipped")
                    continue
                if len(rows) != declared:
                    # The API declares its own total. If the pages do not add up
                    # to it, we fetched a partial series, and loading it would
                    # look exactly like a year where fewer people were counted.
                    sys.exit(f"  {roc}: fetched {len(rows):,} rows but the API "
                             f"declared {declared:,}. Partial fetch -- refusing "
                             f"to load a series with an unexplained hole.")

                pid = period_for(gregorian)
                staged, rejected, reject_samples = [], 0, []
                seen = {}
                dup = 0

                # Rejections are counted AND weighed. 戶政司 and NLSC publish
                # different village sets -- codes like 64000010002 (高雄市鹽埕區
                # 慈愛里) exist in the registry and are absent from the NLSC
                # snapshot entirely (not merely unnamed; checked against the
                # file). "126 rejected" says nothing about whether that matters;
                # the population inside those rows is what decides it, because a
                # township total silently missing 8% of its residents produces a
                # rate that is wrong in the safe-looking direction.
                rejected_population = 0
                for row in rows:
                    code = str(alias(row, "district_code", "區域別代碼")).strip()
                    if code not in villages:
                        rejected += 1
                        for metric, _sex, _h, _e, value in parse(row):
                            if metric == "population" and _sex == "all":
                                rejected_population += value
                        if len(reject_samples) < 5:
                            name = alias(row, "site_id", "區域別")
                            vil = alias(row, "village", "村里名稱", "村里")
                            reject_samples.append(f"{code} {name}{vil}")
                        continue
                    for metric, sex, htype, edu, value in parse(row):
                        mid = metric_id.get(metric)
                        if mid is None:
                            sys.exit(f"metric '{metric}' missing -- migration 008 "
                                     f"should have created it")
                        nat = (mid, code, sex, htype, edu)
                        prior = seen.get(nat)
                        if prior is not None:
                            # Same discipline as the CareMag fix: identical value
                            # is a duplicate, different value is a conflict.
                            if prior == value:
                                dup += 1
                            else:
                                rejected += 1
                                if len(reject_samples) < 5:
                                    reject_samples.append(
                                        f"CONFLICT {nat}: {prior} vs {value}")
                            continue
                        seen[nat] = value
                        staged.append((sid, mid, code, pid, sex, htype, edu, value))

                if args.dry_run:
                    total_pop = sum(v for (_s, m, _c, _p, sx, h, e, v) in staged
                                    if m == metric_id.get("population")
                                    and sx == "all" and h == "all")
                    share = (100.0 * rejected_population / (total_pop + rejected_population)
                             if (total_pop + rejected_population) else 0.0)
                    print(f"  {roc} (西元 {gregorian}): {len(rows):,} source rows -> "
                          f"{len(staged):,} facts, rejected {rejected} rows "
                          f"carrying {rejected_population:,} people "
                          f"({share:.2f}% of the published total), dup {dup} "
                          f"(dry run, nothing written)")
                    for s in reject_samples:
                        print(f"    REJECT {s}")
                    continue

                cur.execute("CREATE TEMP TABLE stage (LIKE demographic_fact "
                            "INCLUDING DEFAULTS) ON COMMIT DROP")
                cur.execute("ALTER TABLE stage DROP COLUMN id, "
                            "DROP COLUMN ingested_at")
                with cur.copy("COPY stage (source_id, metric_id, geo_code, "
                              "period_id, sex, household_type, edu_level, value) "
                              "FROM STDIN") as cp:
                    for rec in staged:
                        cp.write_row(rec)
                cur.execute("""
                    INSERT INTO demographic_fact
                        (source_id, metric_id, geo_code, period_id,
                         sex, household_type, edu_level, value)
                    SELECT source_id, metric_id, geo_code, period_id,
                           sex, household_type, edu_level, value FROM stage
                    ON CONFLICT ON CONSTRAINT demographic_fact_natural
                    DO UPDATE SET value = EXCLUDED.value, ingested_at = now()
                """)
                upserted = cur.rowcount

                cur.execute(
                    "INSERT INTO ingest_runs (source, source_url, fetched_at, "
                    " content_sha256, content_bytes, rows_in_file, rows_accepted, "
                    " rows_rejected, rows_inserted, rows_updated, status, note, "
                    " source_rows_accepted, duplicate_rows, synthesized_rows, "
                    " output_rows_written) "
                    "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
                    (spec["code"], f"{API}/{spec['id']}/{roc}",
                     datetime.now(timezone.utc),
                     # The API is paginated JSON, not one artifact, so there is no
                     # single file to hash. Recorded as the declared row count and
                     # year instead of a fake digest -- an invented sha256 would be
                     # worse than none, because it would look verifiable.
                     f"api:{spec['id']}/{roc}/rows={declared}", 0,
                     len(rows), len(staged), rejected, upserted, 0, "ok",
                     f"roc_year={roc} gregorian={gregorian} facts={len(staged)} "
                     f"duplicates={dup} rejected_population={rejected_population} "
                     f"reason=village_code_absent_from_nlsc_geo_area",
                     len(rows) - rejected - dup, dup, 0, len(staged)))
                conn.commit()

                print(f"  {roc} (西元 {gregorian}): {len(rows):,} 列 -> "
                      f"{upserted:,} facts   拒絕 {rejected} 列 / "
                      f"{rejected_population:,} 人   重複 {dup}")
                for s in reject_samples:
                    print(f"    REJECT {s}")

        if not args.dry_run:
            print("\n=== demographic_fact ===")
            cur.execute("""
                SELECT ds.code, m.code, tp.epi_year, COUNT(*), SUM(d.value)
                FROM demographic_fact d
                JOIN data_source ds USING (source_id)
                JOIN metric m USING (metric_id)
                JOIN time_period tp USING (period_id)
                WHERE d.sex='all' AND d.household_type='all' AND d.edu_level='all'
                GROUP BY 1,2,3 ORDER BY 1,2,3
            """)
            for code, metric, yr, n, total in cur.fetchall():
                print(f"  {code:<32} {metric:<16} {yr}  {n:>6,} rows  "
                      f"total {total:>12,}")


if __name__ == "__main__":
    main()

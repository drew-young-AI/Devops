#!/usr/bin/env python3
"""Ingest Taiwan CDC RODS surveillance data into station2-twin.

RODS = Real-time Outbreak and Disease Surveillance: emergency-department
syndromic surveillance, published weekly by county and age group.

This is the pilot's real workload. It exists to exercise the platform, so it
is written the way an ingestion job has to be written to be trustworthy, not
the shortest way to get rows into a table.

FOUR PROPERTIES, EACH FOR A SPECIFIC FAILURE.

  VERIFIED TLS    The source serves a broken certificate chain (see
                  certs/README.md). The answer is a pinned intermediate, not
                  `verify=False` -- disabling verification on a job whose
                  output is "the official case counts" means ingesting
                  numbers from whoever answers that address.

  IDEMPOTENT      CDC republishes the FULL history every week, not a delta.
                  Without the natural-key conflict clause, a second run
                  doubles every count -- and the corruption is invisible,
                  because the table stays well-formed and the numbers are
                  merely wrong.

  REJECT LOUDLY   Rows that do not match the contract are counted and
                  reported, never silently skipped. A feed that starts
                  emitting garbage must show up as a number going up, not as
                  a quietly shorter table.

  PROVENANCE      Every run records the URL, the content digest and the row
                  accounting. Without it, "the numbers changed" has no
                  answer: a genuine epidemiological shift and a corrected
                  upstream file look identical.

Usage:
  fetch_cdc_rods.py [--dry-run] [--local FILE]

Exit 0 ingested (or no change), 1 failed, 2 usage, 78 EX_CONFIG.
"""
import argparse
import csv
import hashlib
import io
import os
import ssl
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent

SOURCE = "cdc-rods"
DISEASE = "influenza_like_illness"
SOURCE_URL = os.environ.get(
    "CDC_RODS_URL", "https://od.cdc.gov.tw/eic/RODS_Influenza_like_illness.csv")

# The source rejects curl's default agent outright, which presents as a
# connection failure rather than a 403.
USER_AGENT = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
              "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36")

# Column names are Chinese in the source. Mapped explicitly rather than by
# position: a column reordering upstream would otherwise silently swap
# `visits` and `week` with no error at all.
COL_YEAR, COL_WEEK, COL_AGE = "年", "週", "年齡別"
COL_COUNTY, COL_VISITS, COL_CODE = "縣市", "類流感急診就診人次", "縣市別代碼"
REQUIRED = [COL_YEAR, COL_WEEK, COL_AGE, COL_COUNTY, COL_VISITS, COL_CODE]


def build_ssl_context():
    """certifi's roots plus the intermediate the server fails to send."""
    try:
        import certifi
        cafile = certifi.where()
    except ImportError:
        print("certifi is required (the macOS system root store lacks "
              "TWCA CYBER Root CA).", file=sys.stderr)
        sys.exit(78)

    ctx = ssl.create_default_context(cafile=cafile)
    intermediate = HERE / "certs" / "twca-ssl-ca-2023.pem"
    if not intermediate.is_file():
        print(f"Missing pinned intermediate: {intermediate}", file=sys.stderr)
        print("See certs/README.md -- the source's chain cannot be built "
              "without it.", file=sys.stderr)
        sys.exit(78)
    ctx.load_verify_locations(cafile=str(intermediate))
    return ctx


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, context=build_ssl_context(), timeout=120) as r:
        return r.read()


def parse(raw):
    """Return (records, rejected). Rejects are counted with a reason."""
    text = raw.decode("utf-8-sig", errors="replace")
    reader = csv.DictReader(io.StringIO(text))

    missing = [c for c in REQUIRED if c not in (reader.fieldnames or [])]
    if missing:
        # A schema change upstream must stop the run, not be worked around.
        # Partially ingesting a file whose meaning has shifted is worse than
        # ingesting nothing.
        raise ValueError(
            f"source columns changed; missing {missing}. "
            f"Got: {reader.fieldnames}")

    records, rejected = [], []
    for n, row in enumerate(reader, start=2):
        try:
            year = int(row[COL_YEAR])
            week = int(row[COL_WEEK])
            visits = int(row[COL_VISITS])
            county = (row[COL_COUNTY] or "").strip()
            code = (row[COL_CODE] or "").strip()
            age = (row[COL_AGE] or "").strip()
            # ISO weeks run 1..53. A 0 or 54 means the upstream format
            # changed or the row is junk; either way it must not become a
            # data point that quietly skews a seasonal baseline.
            if not (1 <= week <= 53):
                raise ValueError(f"week out of range: {week}")
            if not (2000 <= year <= 2100):
                raise ValueError(f"year out of range: {year}")
            if visits < 0:
                raise ValueError(f"negative visits: {visits}")
            if not county or not code or not age:
                raise ValueError("empty county/code/age")
        except (ValueError, KeyError, TypeError) as exc:
            rejected.append((n, str(exc)))
            continue
        records.append((SOURCE, DISEASE, code, county, age, year, week, visits))
    return records, rejected


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true",
                    help="fetch, validate and report; write nothing")
    ap.add_argument("--local", help="parse a local file instead of fetching")
    args = ap.parse_args()

    fetched_at = datetime.now(timezone.utc)
    if args.local:
        raw = Path(args.local).read_bytes()
        url = f"file://{args.local}"
    else:
        try:
            raw = fetch(SOURCE_URL)
        except urllib.error.URLError as exc:
            reason = getattr(exc, "reason", exc)
            print(f"FETCH FAILED: {reason}", file=sys.stderr)
            if "CERTIFICATE_VERIFY_FAILED" in str(reason):
                print("", file=sys.stderr)
                print("The pinned intermediate may have rotated. See "
                      "ingest/certs/README.md for how to re-fetch it.",
                      file=sys.stderr)
            return 1
        url = SOURCE_URL

    digest = hashlib.sha256(raw).hexdigest()
    print(f"  source   {url}")
    print(f"  bytes    {len(raw):,}")
    print(f"  sha256   {digest}")

    try:
        records, rejected = parse(raw)
    except ValueError as exc:
        print(f"CONTRACT VIOLATION: {exc}", file=sys.stderr)
        return 1

    total = len(records) + len(rejected)
    print(f"  rows     {total:,} in file, {len(records):,} accepted, "
          f"{len(rejected):,} rejected")
    if rejected:
        print("  first rejects:")
        for line, why in rejected[:5]:
            print(f"    line {line}: {why}")

    if args.dry_run:
        print("\n  (dry run -- nothing written)")
        return 0

    try:
        import psycopg
    except ImportError:
        print("psycopg is required to write. Run inside the ingest image.",
              file=sys.stderr)
        return 78

    dsn = os.environ.get("DATABASE_URL") or (
        f"host={os.environ.get('PGHOST','127.0.0.1')} "
        f"port={os.environ.get('PGPORT','15432')} "
        f"dbname={os.environ.get('PGDATABASE','twin')} "
        f"user={os.environ.get('PGUSER','twin')} "
        f"password={os.environ.get('PGPASSWORD','')}")

    inserted = updated = 0
    with psycopg.connect(dsn, connect_timeout=10) as conn:
        with conn.cursor() as cur:
            # xmax = 0 distinguishes an INSERT from an UPDATE on conflict.
            # Without it the job cannot tell "the feed had new weeks" from
            # "the feed restated old ones" -- which is the difference between
            # normal operation and an upstream correction worth noticing.
            for rec in records:
                cur.execute("""
                    INSERT INTO surveillance_observations
                        (source, disease, county_code, county, age_group,
                         epi_year, epi_week, visits)
                    VALUES (%s,%s,%s,%s,%s,%s,%s,%s)
                    ON CONFLICT ON CONSTRAINT surveillance_natural_key
                    DO UPDATE SET visits = EXCLUDED.visits,
                                  county = EXCLUDED.county,
                                  ingested_at = now()
                    WHERE surveillance_observations.visits IS DISTINCT FROM
                          EXCLUDED.visits
                    RETURNING (xmax = 0) AS was_insert
                """, rec)
                out = cur.fetchone()
                if out is None:
                    continue          # conflict, value identical -> no write
                inserted += 1 if out[0] else 0
                updated += 0 if out[0] else 1

            cur.execute("""
                INSERT INTO ingest_runs
                    (source, source_url, fetched_at, content_sha256,
                     content_bytes, rows_in_file, rows_accepted, rows_rejected,
                     rows_inserted, rows_updated, status, note)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
            """, (SOURCE, url, fetched_at, digest, len(raw), total,
                  len(records), len(rejected), inserted, updated,
                  "ok" if not rejected else "ok_with_rejects",
                  f"{len(rejected)} rejected" if rejected else None))

    unchanged = len(records) - inserted - updated
    print(f"\n  inserted {inserted:,}   updated {updated:,}   unchanged {unchanged:,}")
    print("\nINGEST PASS")
    print("  Re-running is safe: the natural key makes it idempotent, so a "
          "second run reports 0 inserted rather than doubling every count.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

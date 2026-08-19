#!/usr/bin/env python3
"""Load the official administrative geography, and the declared name aliases.

WHY GEOGRAPHY GETS ITS OWN LOADER.

Reference data and observations are different kinds of thing. Observations
arrive weekly and are appended; the map of Taiwan changes a handful of times a
decade and every change is a gazetted event with a date. Mixing them means a
surveillance load can silently invent a place -- which is exactly what
happened in migration 005, where the loader minted `tw-台中市` because the TB
feed had no code column.

THE AUTHORITY IS 內政部國土測繪中心 (api.nlsc.gov.tw).

It publishes the full three-level hierarchy and uses the same 5-digit county
codes that RODS/NHI already carry, so the surveillance feeds join to it with no
translation. Township codes are not published directly; they are the 7-char
prefix of the 11-char village id, which is verified here rather than assumed:
every village in a township must agree on the prefix, and no two townships may
share one.

VILLAGES ARE LOADED THOUGH NO FEED IS VILLAGE-LEVEL. 7,871 of them. The
dimension describes the country, not today's feeds. When a village-level feed
appears it lands with no schema change and no dimension backfill -- which is
the claim migration 004 made and this is what makes it true.

SNAPSHOTTED, NOT FETCHED AT LOAD TIME.

Building the reference costs ~390 API calls and several minutes. Worse, a
loader that depends on a live third-party API cannot be re-run to reproduce
last month's result. So the fetch is a separate, explicit `--refresh`, and the
normal path reads a dated snapshot committed to the repo. The snapshot's
sha256 goes into ingest_runs, so any load can be traced to the exact map of
Taiwan it used.

Usage:
  load_geography.py              # load newest snapshot in reference/
  load_geography.py --refresh    # re-fetch from NLSC, write a new snapshot
  load_geography.py --check      # validate only, touch nothing
"""
import argparse
import csv
import hashlib
import os
import re
import ssl
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET
from collections import defaultdict
from datetime import date, datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REFERENCE = HERE / "reference"
CROSSWALK = HERE / "crosswalk"
NLSC = "https://api.nlsc.gov.tw/other"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
      "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36")

# Normalisation applied to every place name before any lookup.
#
# The sources use U+3000 (ideographic space), pairs of ASCII spaces, and both
# 臺 and 台 -- sometimes all within one file. This is mechanical and carries no
# information, so it is code rather than a crosswalk row. The one thing that
# would make it dangerous is two DIFFERENT official names collapsing to the
# same string; that is asserted below, not assumed.
_WS = re.compile(r"[\s　]+")


def norm(s):
    return _WS.sub("", (s or "").strip()).replace("臺", "台")


def _comments_stripped(path):
    """Crosswalk files carry their reasoning inline, on `>`-prefixed lines."""
    return [ln for ln in path.read_text(encoding="utf-8").splitlines()
            if not ln.startswith(">")]


def read_crosswalk(name):
    return list(csv.DictReader(_comments_stripped(CROSSWALK / name)))


# ── 抓取（僅 --refresh） ────────────────────────────────────────────────────
def fetch(url, tries=3):
    ctx = ssl.create_default_context()
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            return urllib.request.urlopen(req, context=ctx, timeout=60).read()
        except Exception:
            if i == tries - 1:
                raise
            time.sleep(2)


def refresh_snapshot():
    counties = [dict(code=i.findtext("countycode"), name=i.findtext("countyname"),
                     code5=i.findtext("countycode01"))
                for i in ET.fromstring(fetch(f"{NLSC}/ListCounty"))]
    print(f"  counties: {len(counties)}")

    towns = []
    for c in counties:
        for i in ET.fromstring(fetch(f"{NLSC}/ListTown/{c['code']}")):
            towns.append(dict(county=c["code"], county5=c["code5"], countyname=c["name"],
                              code=i.findtext("towncode"), name=i.findtext("townname")))
    print(f"  townships: {len(towns)}")

    villages = []
    for n, t in enumerate(towns):
        for i in ET.fromstring(fetch(f"{NLSC}/ListVillage/"
                                     f"{t['county']}/{t['code']}")):
            villages.append(dict(county5=t["county5"], town=t["code"],
                                 vid=i.findtext("villageId"), name=i.findtext("villageName")))
        if n % 50 == 0:
            print(f"    {n}/{len(towns)} townships, {len(villages)} villages", flush=True)
    print(f"  villages: {len(villages)}")

    # Township codes are DERIVED from village ids, so the derivation is proved
    # before it is used: one prefix per township, and no prefix shared.
    prefixes = defaultdict(set)
    for v in villages:
        prefixes[(v["county5"], v["town"])].add(v["vid"][:7])
    split = {k: p for k, p in prefixes.items() if len(p) != 1}
    if split:
        sys.exit(f"REFUSED: {len(split)} townships whose villages disagree on the "
                 f"7-char code prefix, e.g. {list(split.items())[:3]}")
    flat = {k: next(iter(p)) for k, p in prefixes.items()}
    if len(set(flat.values())) != len(flat):
        sys.exit("REFUSED: two townships share one derived code prefix")

    rows = [("county", c["code5"], c["name"], "") for c in counties]
    for t in towns:
        code = flat.get((t["county5"], t["code"]))
        if code is None:
            print(f"    WARNING: no villages under {t['countyname']}{t['name']}, "
                  f"cannot derive a township code -- omitted")
            continue
        rows.append(("township", code, t["name"], t["county5"]))
    rows += [("village", v["vid"], v["name"], v["vid"][:7]) for v in villages]

    REFERENCE.mkdir(parents=True, exist_ok=True)
    out = REFERENCE / f"moi_admin_{date.today():%Y%m%d}.csv"
    with out.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(("geo_level", "geo_code", "name", "parent_code"))
        w.writerows(rows)
    print(f"  wrote {out.name}  {len(rows):,} rows  "
          f"sha256 {hashlib.sha256(out.read_bytes()).hexdigest()[:16]}")
    return out


def newest_snapshot():
    snaps = sorted(REFERENCE.glob("moi_admin_*.csv"))
    if not snaps:
        sys.exit(f"No geography snapshot in {REFERENCE}. Run with --refresh.")
    return snaps[-1]


# ── 驗證 ────────────────────────────────────────────────────────────────────
def validate(rows, derived):
    """Everything that must hold before a single row reaches the database."""
    problems = []

    by_code = {}
    for r in rows:
        if r["geo_code"] in by_code:
            problems.append(f"duplicate geo_code {r['geo_code']}")
        by_code[r["geo_code"]] = r

    for r in rows:
        p = r["parent_code"]
        if p and p not in by_code:
            problems.append(f"{r['geo_code']} points at missing parent {p}")

    # The assertion that makes whitespace normalisation safe. If two distinct
    # official names collapsed to the same normalised string within one parent,
    # every lookup after that would be a coin flip.
    #
    # Unnamed units are excluded, not because they are harmless but because
    # they are a different problem: they cannot collide by name since they have
    # no name. Folding them in here produced 159 false "collisions" that hid
    # the question worth asking, which is what an unnamed administrative unit
    # is and whether anything should reference it.
    seen = {}
    for r in rows:
        if not r["name"].strip():
            continue
        key = (r["parent_code"], norm(r["name"]), r["geo_level"])
        if key in seen and seen[key] != r["geo_code"]:
            problems.append(f"normalisation collision: {r['name']} and "
                            f"{by_code[seen[key]]['name']} under {r['parent_code']}")
        seen[key] = r["geo_code"]

    for d in derived:
        if d["geo_code"] in by_code:
            problems.append(f"declared derived code {d['geo_code']} already official")
        if d["parent_code"] not in by_code:
            problems.append(f"derived {d['geo_code']} points at missing parent")
        if "-" not in d["geo_code"]:
            problems.append(f"derived code {d['geo_code']} is not visibly derived")
    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--refresh", action="store_true",
                    help="re-fetch from api.nlsc.gov.tw and write a new snapshot")
    ap.add_argument("--check", action="store_true", help="validate only, write nothing")
    args = ap.parse_args()

    snapshot = refresh_snapshot() if args.refresh else newest_snapshot()
    raw = snapshot.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    rows = list(csv.DictReader(snapshot.open(encoding="utf-8")))
    derived = read_crosswalk("derived_townships.csv")
    aliases = read_crosswalk("geo_alias.csv")

    # THE SNAPSHOT IS THE AUTHORITY VERBATIM; THE LOADED SET IS NOT.
    #
    # NLSC returns 204 village records with an empty name, concentrated in
    # 連江縣, with a letter in place of the usual 4-digit village sequence
    # (e.g. 66000120S01). They are dropped here rather than stored as rows
    # named '', because nothing can reference a place by a name it does not
    # have, and a code-keyed village feed does not exist yet. If one appears,
    # its unmatched codes will fail the foreign key loudly -- which is the
    # right way to find out -- and this decision gets revisited.
    #
    # The snapshot file keeps them. Raw and loaded differ, and the difference
    # is printed rather than quietly absorbed.
    unnamed = [r for r in rows if not r["name"].strip()]
    rows = [r for r in rows if r["name"].strip()]

    counts = defaultdict(int)
    for r in rows:
        counts[r["geo_level"]] += 1
    print(f"\n  snapshot {snapshot.name}  sha256 {digest[:16]}")
    print(f"  {counts['county']} 縣市 / {counts['township']} 鄉鎮市區 / "
          f"{counts['village']} 村里   +{len(derived)} 宣告衍生   "
          f"{len(aliases)} 名稱對照")
    if unnamed:
        by_parent = defaultdict(int)
        for r in unnamed:
            by_parent[r["parent_code"]] += 1
        top = sorted(by_parent.items(), key=lambda kv: -kv[1])[:3]
        print(f"  略過 {len(unnamed)} 筆無名稱單元（權威來源即為空白）"
              f"，最多的鄉鎮：{', '.join(f'{k}×{v}' for k, v in top)}")

    problems = validate(rows, derived)
    if problems:
        print(f"\n  REFUSED -- {len(problems)} problem(s):")
        for p in problems[:20]:
            print(f"    {p}")
        return 1
    print("  validation: ok")
    if args.check:
        return 0

    import psycopg
    dsn = os.environ.get("DATABASE_URL") or (
        f"host={os.environ.get('PGHOST', '127.0.0.1')} "
        f"port={os.environ.get('PGPORT', '15432')} "
        f"dbname={os.environ.get('PGDATABASE', 'twin')} "
        f"user={os.environ.get('PGUSER', 'twin')} "
        f"password={os.environ.get('PGPASSWORD', '')}")
    conn = psycopg.connect(dsn, connect_timeout=10)
    cur = conn.cursor()

    # Parents must exist before children: county, township, village, then the
    # declared derived districts (which hang off counties).
    order = {"county": 0, "township": 1, "village": 2}
    ordered = sorted(rows, key=lambda r: order[r["geo_level"]])
    cur.executemany(
        "INSERT INTO geo_area (geo_code, geo_level, name, parent_code, code_system) "
        "VALUES (%s,%s,%s,%s,'moi') ON CONFLICT (geo_code) DO UPDATE "
        "SET name = EXCLUDED.name, parent_code = EXCLUDED.parent_code",
        [(r["geo_code"], r["geo_level"], r["name"], r["parent_code"] or None)
         for r in ordered])
    cur.executemany(
        "INSERT INTO geo_area (geo_code, geo_level, name, parent_code, code_system) "
        "VALUES (%s,'township',%s,%s,'derived') ON CONFLICT (geo_code) DO UPDATE "
        "SET name = EXCLUDED.name, parent_code = EXCLUDED.parent_code",
        [(d["geo_code"], d["town_name"], d["parent_code"]) for d in derived])

    # Aliases resolve by OFFICIAL NAME, and the name must exist. A crosswalk row
    # naming a place that is not in the authority is a typo or a bad assumption,
    # and either way must stop the load rather than be skipped.
    name_to_code = {}
    for r in rows:
        if r["geo_level"] in ("county", "township"):
            name_to_code[(r["parent_code"], norm(r["name"]))] = r["geo_code"]
    county_code = {norm(r["name"]): r["geo_code"] for r in rows
                   if r["geo_level"] == "county"}
    for d in derived:
        name_to_code[(d["parent_code"], norm(d["town_name"]))] = d["geo_code"]

    alias_rows, unresolved = [], []
    for a in aliases:
        cc = county_code.get(norm(a["official_county"]))
        target = name_to_code.get((cc, norm(a["official_town"]))) if cc else None
        if target is None:
            unresolved.append(f"{a['official_county']}{a['official_town']} "
                              f"(for {a['raw_county']}{a['raw_town']})")
            continue
        alias_rows.append((a["source_code"], norm(a["raw_county"]), norm(a["raw_town"]),
                           target, a["rule"], a["evidence"]))
    if unresolved:
        conn.rollback()
        print(f"\n  REFUSED -- {len(unresolved)} crosswalk target(s) not in the authority:")
        for u in unresolved:
            print(f"    {u}")
        return 1

    cur.executemany(
        "INSERT INTO geo_alias (source_code, raw_parent, raw_name, geo_code, rule, evidence) "
        "VALUES (%s,%s,%s,%s,%s,%s) "
        "ON CONFLICT (source_code, raw_parent, raw_name) DO UPDATE "
        "SET geo_code = EXCLUDED.geo_code, rule = EXCLUDED.rule, "
        "    evidence = EXCLUDED.evidence", alias_rows)

    # Lineage. rows_in_file is the SNAPSHOT's row count, not the loaded count:
    # the 204 unnamed villages are a rejection with a reason, and recording the
    # post-filter number as "in file" would erase the fact that a decision was
    # made. The 5 derived 新竹市/嘉義市 district codes are synthesised, so they
    # belong to output and never to source -- which is why output (8,059)
    # legitimately exceeds accepted (8,054), and why the old single
    # `rows_accepted` column made this run look like it accepted more rows than
    # the file contained.
    cur.execute(
        "INSERT INTO ingest_runs (source, source_url, fetched_at, content_sha256, "
        " content_bytes, rows_in_file, rows_accepted, rows_rejected, rows_inserted, "
        " rows_updated, status, note, source_rows_accepted, duplicate_rows, "
        " synthesized_rows, output_rows_written) "
        "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
        ("moi-admin-geography", f"{NLSC}/ListCounty|ListTown|ListVillage",
         datetime.now(timezone.utc), digest, len(raw),
         len(rows) + len(unnamed),
         len(rows) + len(derived), len(unnamed), 0, 0, "ok",
         f"snapshot={snapshot.name} derived={len(derived)} aliases={len(alias_rows)} "
         f"unnamed_excluded={len(unnamed)}",
         len(rows), 0, len(derived), len(rows) + len(derived)))
    conn.commit()

    cur.execute("SELECT geo_level, code_system, COUNT(*) FROM geo_area "
                "GROUP BY 1,2 ORDER BY 1,2")
    print("\n  geo_area:")
    for lvl, sysname, n in cur.fetchall():
        print(f"    {lvl:<9} {sysname:<8} {n:>6,}")
    cur.execute("SELECT rule, COUNT(*) FROM geo_alias GROUP BY 1 ORDER BY 1")
    print("  geo_alias:", ", ".join(f"{r}={n}" for r, n in cur.fetchall()))
    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

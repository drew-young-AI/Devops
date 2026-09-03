#!/usr/bin/env python3
"""Record, with provenance, how often each data source is actually published.

WHY THIS EXISTS.

`DataSourceStale` (14d) and `DataSourceVeryStale` (45d) applied one threshold
to every source. That is right for the 19 weekly-or-faster surveillance feeds
and wrong for the annual ones, which sit permanently in warning and escalate to
critical -- while being completely healthy. One permanently-red member teaches
people to filter the whole class, and that class is the only thing that noticed
the 14-day ingest outage on 2026-09-03 (ADR-0013). A permanently-red alert does
not just fail to inform; it disarms the alert next to it.

WHY THE CADENCE IS FETCHED AND NOT TYPED IN.

CLAUDE.md forbids guessing a data mapping. docs/Backlog.md §20 already recorded
a table of "actual update frequency" written from impression, and it was wrong:
it listed cdc-tb-caremag as annual, while the publisher declares `day` -- the
dataset is literally titled 結核病每日縣市鄉鎮管理中個案. An estimate that looks
like a measurement is the thing this platform is built to refuse.

TWO KINDS OF EVIDENCE, BOTH RECORDED AS SUCH.

  declared    CKAN `updated_freq` from the publisher's own catalogue.
              Note the field is `updated_freq`; §20 named `frequency`, which
              does not exist on these packages.
  structural  the API is keyed by period, so a new value CANNOT appear more
              often than that. The MOI household registry is fetched as
              ODRP019/<ROC year>, one resource per year, and the loader takes a
              --years range. This is stronger than a declared string: it is a
              property of the interface rather than a claim about intent.

A source with neither gets `null` and is EXCLUDED from the derived thresholds
rather than given a default. A default here would be a guess wearing the
output format of a measurement.

Usage:
  platform/dataops/refresh_source_frequency.py            rewrite the table
  platform/dataops/refresh_source_frequency.py --check    fail if it is stale
"""
import argparse
import json
import os
import ssl
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
INGEST = REPO_ROOT / "pilots" / "station2-twin" / "ingest"
OUT = REPO_ROOT / "pilots" / "station2-twin" / "ingest" / "source_frequency.json"
CKAN = "https://data.cdc.gov.tw/api/3/action"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0 Safari/537.36")

# The publisher's vocabulary, decoded. This IS a mapping, so it is explicit and
# short rather than inferred: every value the CDC catalogue actually uses is
# listed, and an unrecognised one is an error rather than a default.
#
# `non-scheduled` and `once` deliberately decode to None: "irregular" is not a
# period, and inventing one would turn "we do not know when the next update is"
# into a threshold that looks measured.
FREQ_SECONDS = {
    "day": 86400,
    "week": 604800,
    "month": 2592000,      # 30d
    "year": 31536000,      # 365d
    "non-scheduled": None,
    "once": None,
}

# Sources whose cadence comes from the interface rather than from a catalogue.
# Each entry must say WHY, because a hand-written entry is exactly what this
# file exists to avoid, and the only thing separating this from a guess is the
# evidence line.
STRUCTURAL = {
    "moi-ris-village-population": {
        "seconds": 31536000,
        "evidence": "ris.gov.tw ODRP019 is addressed per ROC year "
                    "(ODRP019/113, /114 ...); load_registry.py iterates a "
                    "--years range. One resource per year, so a new value "
                    "cannot appear more often than yearly.",
    },
    "moi-ris-village-education": {
        "seconds": 31536000,
        "evidence": "ris.gov.tw ODRP024, same per-ROC-year addressing as "
                    "ODRP019.",
    },
    "moi-ris-village-age-marital": {
        "seconds": 31536000,
        "evidence": "ris.gov.tw ODRP052, same per-ROC-year addressing.",
    },
}

# Sources whose publication cadence genuinely cannot be established, recorded
# as such rather than estimated. `null` here is a fact about the evidence, not
# a placeholder waiting to be filled with a plausible number.
NO_EVIDENCE = {
    "moi-admin-geography": "api.nlsc.gov.tw serves a full snapshot with no "
                           "period in the address and publishes no cadence, "
                           "so neither declared nor structural evidence "
                           "exists. Administrative boundaries move when they "
                           "move.",
    "cdc-rods": "retired 2026-08-19 (see RETIRED_SOURCES in "
                "platform/dataops/pipeline_metrics.py); it holds no fact rows "
                "and is a target in no loader, so it has no cadence to have.",
}


def ssl_ctx():
    import certifi
    ctx = ssl.create_default_context(cafile=certifi.where())
    inter = INGEST / "certs" / "twca-ssl-ca-2023.pem"
    if inter.is_file():
        ctx.load_verify_locations(cafile=str(inter))
    return ctx


def get(url, ctx):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, context=ctx, timeout=45) as r:
        return json.loads(r.read())


def db_sources():
    """(code, url) for everything this platform fetches.

    The UNION of data_source and ingest_runs, not just data_source. They are not
    the same set: moi-admin-geography has ingest history but no data_source row,
    because it loads geo_area and that table carries no source_id. A table built
    from data_source alone would silently omit it -- and omitting a source from
    a cadence table is exactly how it ends up with no threshold and no alert,
    which is the failure this file exists to close one level up.

    Read through the running container rather than through a client library so
    this works with no credential of its own: the cadence table is not secret
    and should not need one.
    """
    out = subprocess.run(
        ["docker", "exec", "station2-twin-db-1", "psql", "-U", "twin", "-d",
         "twin", "-At", "-F", "|", "-c",
         "SELECT code, coalesce(url,'') FROM data_source "
         "UNION "
         "SELECT ir.source, coalesce(ds.url,'') FROM ingest_runs ir "
         "LEFT JOIN data_source ds ON ds.code = ir.source "
         "ORDER BY 1"],
        capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        sys.exit(f"cannot read the source registry: {out.stderr.strip()}")
    rows = [r.split("|", 1) for r in out.stdout.strip().split("\n") if r]
    # A code appearing twice (once with a url, once without) keeps the url.
    merged = {}
    for code, url in rows:
        if url or code not in merged:
            merged[code] = url
    return merged


def catalogue_by_url(ctx):
    by_url = {}
    names = get(f"{CKAN}/package_list", ctx)["result"]
    for name in names:
        try:
            pkg = get(f"{CKAN}/package_show?id={urllib.parse.quote(name)}",
                      ctx)["result"]
        except Exception as exc:                      # noqa: BLE001
            print(f"# SKIP {name}: {type(exc).__name__}", file=sys.stderr)
            continue
        for res in pkg.get("resources", []):
            if res.get("url"):
                by_url[res["url"].strip()] = (name, pkg.get("updated_freq"))
    return by_url


def build():
    sources = db_sources()
    by_url = catalogue_by_url(ssl_ctx())
    table = {}
    for code, url in sorted(sources.items()):
        hit = by_url.get(url.strip())
        if hit:
            dataset, declared = hit
            if declared not in FREQ_SECONDS:
                sys.exit(f"{code}: catalogue declares updated_freq="
                         f"{declared!r}, which FREQ_SECONDS does not decode. "
                         f"Add it deliberately rather than defaulting.")
            table[code] = {
                "seconds": FREQ_SECONDS[declared],
                "source": "declared",
                "evidence": f"CKAN updated_freq={declared!r} on "
                            f"data.cdc.gov.tw dataset {dataset!r}",
            }
        elif code in STRUCTURAL:
            table[code] = dict(STRUCTURAL[code], source="structural")
        elif code in NO_EVIDENCE:
            table[code] = {"seconds": None, "source": "no-evidence",
                           "evidence": NO_EVIDENCE[code]}
        else:
            table[code] = {
                "seconds": None,
                "source": "unknown",
                "evidence": f"not in the CDC catalogue by url ({url!r}) and no "
                            f"structural evidence recorded",
            }
    return table


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="compare against the committed table, change nothing")
    args = ap.parse_args()

    table = build()
    text = json.dumps(table, ensure_ascii=False, indent=2, sort_keys=True) + "\n"

    if args.check:
        if not OUT.is_file():
            print(f"{OUT} does not exist", file=sys.stderr)
            return 1
        if OUT.read_text(encoding="utf-8") != text:
            print("the committed cadence table no longer matches the "
                  "publisher's catalogue -- rerun without --check",
                  file=sys.stderr)
            return 1
        print(f"{len(table)} sources, table matches the catalogue")
        return 0

    OUT.write_text(text, encoding="utf-8")
    known = sum(1 for v in table.values() if v["seconds"])
    print(f"wrote {len(table)} sources ({known} with an interval, "
          f"{len(table) - known} unknown) -> {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

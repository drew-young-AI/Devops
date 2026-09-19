#!/usr/bin/env python3
"""Enumerate CKAN catalogues and report what is actually publishable, not what
a URL guess suggests exists.

Why this is a script and not a one-off curl: the CDC feed we already depend on
(cdc-tb-caremag, township x day) was found by listing all datasets and reading
each one's resources. Guessing URLs from the naming pattern of the feeds we
already had would never have surfaced it, because the name does not follow the
pattern. Enumeration is the method; this file makes it repeatable.

    discover_sources.py cdc                 # data.cdc.gov.tw
    discover_sources.py moi --grep 人口     # data.gov.tw, filtered

Output is a TSV of (dataset id, resource format, resource url, title) so the
result can be diffed between runs -- a source that disappears should be visible
as a removed line, not as a loader that silently starts rejecting everything.
"""
import argparse
import json
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
      "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36")

CATALOGUES = {
    "cdc": "https://data.cdc.gov.tw/api/3/action",
    # data.gov.tw is the whole-government catalogue; MOI population and MOF
    # income statistics are published through it rather than on a ministry host.
    "gov": "https://data.gov.tw/api/v2",
}


def ssl_ctx():
    """certifi plus the intermediate the CDC host fails to send.

    Same defect as load_dimensional.py documents: od.cdc.gov.tw presents a leaf
    issued by one TWCA CA and sends a different TWCA CA as the intermediate, so
    the chain does not link without the pinned file.
    """
    import certifi
    ctx = ssl.create_default_context(cafile=certifi.where())
    inter = HERE / "certs" / "twca-ssl-ca-2023.pem"
    if inter.is_file():
        ctx.load_verify_locations(cafile=str(inter))
    return ctx


def get(url, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, context=ssl_ctx(), timeout=timeout) as r:
        return json.loads(r.read())


def ckan(base, grep):
    names = get(f"{base}/package_list")["result"]
    print(f"# {len(names)} datasets in catalogue", file=sys.stderr)
    hits = 0
    for name in names:
        try:
            pkg = get(f"{base}/package_show?id={urllib.parse.quote(name)}")["result"]
        except (urllib.error.HTTPError, urllib.error.URLError, KeyError) as exc:
            print(f"# SKIP {name}: {type(exc).__name__}", file=sys.stderr)
            continue
        title = pkg.get("title") or name
        blob = f"{name} {title} {pkg.get('notes') or ''}"
        if grep and not any(g in blob for g in grep):
            continue
        for res in pkg.get("resources", []):
            fmt = (res.get("format") or "").upper()
            print("\t".join([name, fmt, res.get("url") or "", title]))
            hits += 1
    print(f"# {hits} matching resources", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("catalogue", choices=sorted(CATALOGUES))
    ap.add_argument("--grep", action="append", default=[],
                    help="substring that must appear in name/title/notes; "
                         "repeatable, matches if ANY appears")
    args = ap.parse_args()
    ckan(CATALOGUES[args.catalogue], args.grep)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Print the header, row count and first rows of a remote CSV, without loading.

Exists because "the columns are the same as the feed we already handle" is an
assumption that has already been wrong once on this project (the MOI township
spellings). Checking costs one request; being wrong costs a reload.

    probe_feed.py https://od.cdc.gov.tw/eic/NHI_COVID-19.csv
    probe_feed.py <url> --rows 3
"""
import argparse
import csv
import hashlib
import io
import ssl
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
      "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36")


def ssl_ctx():
    import certifi
    ctx = ssl.create_default_context(cafile=certifi.where())
    inter = HERE / "certs" / "twca-ssl-ca-2023.pem"
    if inter.is_file():
        ctx.load_verify_locations(cafile=str(inter))
    return ctx


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("urls", nargs="+")
    ap.add_argument("--rows", type=int, default=2)
    args = ap.parse_args()

    for url in args.urls:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        try:
            with urllib.request.urlopen(req, context=ssl_ctx(), timeout=300) as r:
                raw = r.read()
        except Exception as exc:
            print(f"{url}\n  FETCH FAILED: {type(exc).__name__}: {exc}\n")
            continue
        text = raw.decode("utf-8-sig", "replace")
        rdr = csv.reader(io.StringIO(text))
        try:
            header = next(rdr)
        except StopIteration:
            print(f"{url}\n  EMPTY\n")
            continue
        body = list(rdr)
        print(f"{url}")
        print(f"  sha256   {hashlib.sha256(raw).hexdigest()[:16]}  bytes {len(raw):,}")
        print(f"  rows     {len(body):,}")
        print(f"  columns  {header}")
        for row in body[:args.rows]:
            print(f"    {row}")
        print()


if __name__ == "__main__":
    main()

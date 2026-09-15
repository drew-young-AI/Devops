#!/usr/bin/env python3
"""Give the scanner the URLs its spider can never invent.

WHY THIS EXISTS (2026-09-15)
----------------------------
`dast_coverage.py` measured the gap: the ZAP baseline profile reaches 4 of the
pilot's 10 routes. Six it cannot reach, and only ONE of those six is a real
limitation of a passive scan:

    write          POST. A baseline scan never sends it, and it must not --
                   that endpoint inserts into a 6.5M-row table.
    unlinked   x2  plain GETs that nothing links to, so a spider starting at
                   the root never finds them. Not a scanner limitation at all:
                   the scanner simply was never told the URL.
    parameterised x3  the path has a segment the spider must supply. It will
                   not guess an asset id or a county code -- nor should it.

So five of the six were never a property of the application. They were a
property of the SCAN CONFIGURATION, and the honest fix is to configure the
scan properly rather than to keep reporting 40% forever.

WHAT THIS REFUSES TO DO
-----------------------
Invent a parameter value. A made-up asset id produces a 404, the scanner
passively scans the 404 page, and coverage goes up while nothing new was
examined -- a green number over an unexamined route, which is the exact defect
this whole area exists to prevent. Every parameter here is resolved from a
REAL source and then VERIFIED against the running target; a value that does
not resolve, or that resolves to 404, is a refusal, never a guess.

Two resolvers, because the pilot has two kinds of parameter:

    from-api  the value is already published by a route the spider CAN reach.
              /surveillance/scan lists every county_code it scanned, so the
              county parameter is discoverable by following the data -- which
              is what a spider would do if this API linked anything.
    from-db   the value exists nowhere in the HTTP surface. `observations`
              holds the asset ids, so the seed comes from the database the
              application itself reads.

The output is an OpenAPI 3 document, because that is the form ZAP already
understands: `zap-api-scan.py -f openapi` imports every operation and requests
it. Expressing the seed as a spec rather than as a bespoke URL loop keeps the
scanning in the scanner.

POST IS EXCLUDED BY CONSTRUCTION, not by configuration -- see EXCLUDE_WRITES.
An OpenAPI document that describes the write endpoint is a document some
future run will happily POST to.

Usage:
  dast_seed.py --target http://127.0.0.1:18090 --spec-out /path/openapi.json
               [--app PATH] [--db-container NAME] [--json]

Exit codes:
  0  spec written; every operation in it was verified to resolve on the target
  2  refused -- a parameter could not be resolved to a real, verified value
"""

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dast_coverage import parse_routes  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_APP = os.path.join(REPO_ROOT, "pilots", "station2-twin", "app", "app.py")

# A spec that describes a write is a spec something will eventually write with.
EXCLUDE_WRITES = ("POST", "PUT", "PATCH", "DELETE")

# How to obtain a real value for each parameterised position. Keyed by the
# route template the parser produces, so a renamed route loses its resolver
# loudly (refusal) instead of silently keeping a stale value.
RESOLVERS = {
    ("/twin/{p1}", 1): ("from-db", "SELECT asset_id FROM observations "
                                   "ORDER BY observed_at DESC LIMIT 1"),
    ("/twin/{p1}/history", 1): ("from-db", "SELECT asset_id FROM observations "
                                           "ORDER BY observed_at DESC LIMIT 1"),
    ("/surveillance/{p1}", 1): ("from-api", ("/surveillance/scan",
                                             ("results", 0, "county_code"))),
}


def _get_json(url, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": "dast-seed/1"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def _status(url, timeout=20):
    req = urllib.request.Request(url, headers={"User-Agent": "dast-seed/1"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status
    except urllib.error.HTTPError as exc:
        return exc.code


def _dig(doc, path):
    for key in path:
        doc = doc[key]
    return doc


def _from_db(container, sql):
    out = subprocess.run(
        ["docker", "exec", "-i", container, "psql", "-U", "twin", "-d", "twin",
         "-Atc", sql],
        capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        return None, out.stderr.strip()[:200]
    value = out.stdout.strip().splitlines()
    if not value or not value[0]:
        return None, "query returned no rows"
    return value[0], None


def resolve(route, target, container, errors):
    """Return a concrete path for a route template, or None with a reason."""
    path = route["path"]
    concrete = path
    for index, segment in enumerate(p for p in path.split("/") if p):
        if not (segment.startswith("{p") and segment.endswith("}")):
            continue
        key = (path, index)
        rule = RESOLVERS.get(key)
        if rule is None:
            errors.append("%s: no resolver for segment %d -- refusing to invent "
                          "a value" % (path, index))
            return None
        kind, spec = rule
        if kind == "from-db":
            value, why = _from_db(container, spec)
            if value is None:
                errors.append("%s: database resolver failed (%s)" % (path, why))
                return None
        elif kind == "from-api":
            src, dig = spec
            try:
                value = _dig(_get_json(target.rstrip("/") + src), dig)
            except Exception as exc:  # noqa: BLE001
                errors.append("%s: API resolver %s failed (%s)"
                              % (path, src, type(exc).__name__))
                return None
        else:  # pragma: no cover -- guarded by the table above
            errors.append("%s: unknown resolver kind %r" % (path, kind))
            return None
        concrete = concrete.replace("/" + segment, "/" + str(value), 1)
    return concrete


def build(target, app_path, container):
    routes = [r for r in parse_routes(open(app_path).read())
              if r["method"] not in EXCLUDE_WRITES]
    errors = []
    paths, seeded = {}, []
    for route in routes:
        concrete = resolve(route, target, container, errors)
        if concrete is None:
            continue
        # Verified, not assumed. A 404 means the resolver produced a value the
        # application does not know, and scanning a 404 page is not coverage.
        code = _status(target.rstrip("/") + concrete)
        if code == 404:
            errors.append("%s -> %s returned 404; the resolved value is not "
                          "real" % (route["path"], concrete))
            continue
        paths[concrete] = {
            "get": {
                "operationId": concrete.strip("/").replace("/", "_") or "root",
                "responses": {str(code): {"description": "observed"}},
            }
        }
        seeded.append({"template": route["path"], "url": concrete,
                       "verified_status": code})
    spec = {
        "openapi": "3.0.0",
        "info": {"title": "station2-twin (DAST seed)", "version": "1"},
        "servers": [{"url": target.rstrip("/")}],
        "paths": paths,
    }
    return spec, seeded, errors


def main(argv):
    target = "http://127.0.0.1:18090"
    app_path = DEFAULT_APP
    container = "station2-twin-db-1"
    spec_out = None
    as_json = False

    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--target":
            target = argv[i + 1]; i += 2
        elif arg == "--app":
            app_path = argv[i + 1]; i += 2
        elif arg == "--db-container":
            container = argv[i + 1]; i += 2
        elif arg == "--spec-out":
            spec_out = argv[i + 1]; i += 2
        elif arg == "--json":
            as_json = True; i += 1
        else:
            sys.stderr.write("unknown argument: %s\n" % arg)
            return 2

    spec, seeded, errors = build(target, app_path, container)

    if errors:
        sys.stderr.write("REFUSED: could not resolve every route to a real, "
                         "verified value.\n")
        for line in errors:
            sys.stderr.write("  - %s\n" % line)
        sys.stderr.write(
            "  Seeding the scan with an invented value would raise coverage\n"
            "  while examining a 404 page. That is the defect this file exists\n"
            "  to prevent, so it refuses instead.\n")
        return 2

    if spec_out:
        with open(spec_out, "w") as handle:
            handle.write(json.dumps(spec, indent=2, ensure_ascii=False) + "\n")

    if as_json:
        print(json.dumps({"seeded": seeded, "spec_paths": len(spec["paths"])},
                         indent=2, ensure_ascii=False))
    else:
        print("DAST seed: %d GET operation(s), every one verified on %s"
              % (len(spec["paths"]), target))
        for item in seeded:
            print("  %-26s -> %-34s (%d)"
                  % (item["template"], item["url"], item["verified_status"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

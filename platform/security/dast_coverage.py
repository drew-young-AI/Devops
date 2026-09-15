#!/usr/bin/env python3
"""What the DAST scan did NOT look at.

WHY THIS EXISTS (2026-09-01)
----------------------------
`scan_dast.sh` reports `gate_result: PASS`, HIGH=0 MEDIUM=0. That line is true
and it is also badly misleading, because of what it leaves out:

    ZAP baseline = passive rules + a short spider. It sends GET requests to
    what it can discover by following links from the root. station2-twin
    serves a JSON API with no HTML and no links, so the spider discovers
    almost nothing -- and `POST /twin/<asset>/observation`, the only write
    path in the system, cannot be reached by a GET spider at all.

So "DAST PASS" currently means *the handful of URLs the spider stumbled onto
are clean*. It does not mean the application is clean, and nothing anywhere
said which of those two it meant. That is this platform's oldest failure shape
wearing security clothing: a green line whose real content is "almost nothing
was examined". VACUOUS is not PASS.

This script does not scan anything. It answers one question:

    of the routes this application actually serves, which ones is the
    configured scan STRUCTURALLY INCAPABLE of reaching?

That question is answerable deterministically, offline, with no attack traffic
and no risk to data -- which matters, because the write endpoint takes a JSON
body and inserts into a 6.5M-row table, and pointing an active scanner at it
without an isolated target would corrupt the very data the platform exists to
keep trustworthy.

WHY THE ROUTES ARE PARSED FROM SOURCE
-------------------------------------
The alternative is a hand-maintained list of routes, which drifts the first
time somebody adds an endpoint -- and a coverage report built on a stale
inventory reports full coverage of a surface that has grown. Parsing the
dispatcher means a new route shows up as a new uncovered route on the next
run, without anyone remembering to update anything.

The parser is specific to this pilot's dispatcher, and that is an accepted
trade: it is exact for the code that exists rather than approximate for code
that does not. The guard against it silently rotting is MIN_EXPECTED_ROUTES --
if the patterns stop matching, this exits non-zero instead of reporting a
comfortable "0 gaps" derived from 0 routes.

Usage:
  dast_coverage.py [--app PATH] [--observed PATH] [--out PATH] [--prom PATH]
                   [--json]

Exit codes:
  0  coverage computed
  2  the parser matched fewer routes than the floor -- refusing to report
  3  no scan observation -- refusing to fall back to a declared number
"""

import json
import os
import re
import sys
from datetime import datetime, timezone

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_APP = os.path.join(REPO_ROOT, "pilots", "station2-twin", "app", "app.py")
DEFAULT_OUT = os.path.join(REPO_ROOT, "evidence", "security", "dast_coverage.json")
DEFAULT_PROM = os.path.join(REPO_ROOT, "evidence", "statusdag", "dast_coverage.prom")

# If the dispatcher is refactored and these patterns stop matching, the honest
# output is an error, not "0 uncovered routes out of 0".
MIN_EXPECTED_ROUTES = 8

# A literal path the dispatcher compares directly: `if path == "/health/live":`
LITERAL = re.compile(r'if\s+path\s*==\s*"(/[^"]*)"')

# A fully literal segment list: `if parts == ["surveillance", "scan"]:`
EXACT_PARTS = re.compile(r'if\s+parts\s*==\s*\[([^\]]*)\]')

# A shaped match with positional constraints, which is how every parameterised
# route in this app is expressed:
#   if len(parts) == 3 and parts[0] == "twin" and parts[2] == "history":
SHAPED = re.compile(r'len\(parts\)\s*==\s*(\d+)((?:\s+and\s+parts\[\d\]\s*==\s*"[^"]+")+)')
SHAPED_PIN = re.compile(r'parts\[(\d)\]\s*==\s*"([^"]+)"')


def parse_routes(source):
    """Recover (method, path-template) pairs from the dispatcher.

    Method is decided by which handler the line falls in: everything before
    `def do_POST` is GET, everything after is POST. Crude, and correct for a
    BaseHTTPRequestHandler with exactly those two verbs -- and if a third verb
    is ever added, the floor check below is what makes that visible.
    """
    post_at = source.find("def do_POST")
    if post_at < 0:
        post_at = len(source)

    routes = []
    seen = set()

    def add(method, path):
        key = (method, path)
        if key not in seen:
            seen.add(key)
            routes.append({"method": method, "path": path})

    for match in LITERAL.finditer(source):
        method = "GET" if match.start() < post_at else "POST"
        add(method, match.group(1))

    for match in EXACT_PARTS.finditer(source):
        segs = re.findall(r'"([^"]+)"', match.group(1))
        if segs:
            method = "GET" if match.start() < post_at else "POST"
            add(method, "/" + "/".join(segs))

    for match in SHAPED.finditer(source):
        count = int(match.group(1))
        pins = {int(i): v for i, v in SHAPED_PIN.findall(match.group(2))}
        # Unpinned positions are path parameters. Naming them {p0}, {p1} keeps
        # the template honest about which segments the caller supplies.
        segs = [pins.get(i, "{p%d}" % i) for i in range(count)]
        method = "GET" if match.start() < post_at else "POST"
        add(method, "/" + "/".join(segs))

    return routes


def _template_regex(path):
    """A template matches the concrete paths the dispatcher would route to it."""
    parts = [seg for seg in path.split("/") if seg]
    pieces = []
    for seg in parts:
        if seg.startswith("{p") and seg.endswith("}"):
            pieces.append(r"[^/]+")
        else:
            pieces.append(re.escape(seg))
    return re.compile(r"^/" + "/".join(pieces) + r"/?$")


def _literal_count(path):
    return sum(1 for seg in path.split("/")
               if seg and not (seg.startswith("{p") and seg.endswith("}")))


def attribute(routes, observed):
    """Which route template each observed request belongs to.

    MOST-LITERAL WINS, because that is how the dispatcher itself resolves:
    `if parts == ["surveillance", "scan"]` is tested before
    `if len(parts) == 2 and parts[0] == "surveillance"`. Attributing an
    observed /surveillance/scan to the parameterised route would report the
    literal one as never reached while the scanner had just reached it, and
    would credit the parameterised route with a request that never carried a
    parameter -- one observation, two wrong answers.
    """
    hits = {}
    ordered = sorted(routes, key=lambda r: -_literal_count(r["path"]))
    compiled = [(r, _template_regex(r["path"])) for r in ordered]
    for request in observed:
        for route, pattern in compiled:
            if route["method"] == request.get("method") and pattern.match(request.get("path", "")):
                hits.setdefault((route["method"], route["path"]), []).append(request)
                break
    return hits


def classify(route, hits):
    """Did the scan actually touch this route, and if not, why not?

    THIS USED TO BE A DECLARATION. Until 2026-09-15 the reachable set was a
    four-element tuple of paths written into this file: a claim about what the
    spider finds, which stayed true by assertion no matter what any scan did.
    It survived the scan being repointed at a different application. It would
    have survived the scanner being broken. A coverage number that cannot be
    wrong is not a measurement, and this file's whole argument is that the
    denominator is the part that decides what a PASS is worth.

    Now `reachable` means one thing only: THE TARGET LOGGED THIS REQUEST FROM
    THE SCANNER, during the scan window. The reasons below explain a route the
    scan did NOT touch, and they still say different things to a reader:

      write        the verb is not GET. The scan profile never sends it, and
                   must not -- that endpoint inserts into a 6.5M-row table.
      parameterised  the path needs a value the scan was not given. Fixable by
                   seeding (platform/security/dast_seed.py), not by the spider.
      unlinked     a plain GET nothing links to, so a spider starting at the
                   root never finds it. Also fixable by seeding.
    """
    if (route["method"], route["path"]) in hits:
        return "reachable", True
    if route["method"] != "GET":
        return "write", False
    if "{p" in route["path"]:
        return "parameterised", False
    return "unlinked", False


def build(app_path, observation):
    with open(app_path, "r") as handle:
        source = handle.read()
    routes = parse_routes(source)

    if len(routes) < MIN_EXPECTED_ROUTES:
        return None, routes

    hits = attribute(routes, observation.get("requests") or [])
    for route in routes:
        reason, covered = classify(route, hits)
        route["reason"] = reason
        route["reachable_by_baseline"] = covered
        route["observed_requests"] = len(hits.get((route["method"], route["path"]), []))

    covered = [r for r in routes if r["reachable_by_baseline"]]
    gaps = [r for r in routes if not r["reachable_by_baseline"]]
    by_reason = {}
    for route in gaps:
        by_reason[route["reason"]] = by_reason.get(route["reason"], 0) + 1

    return {
        "schema": "dast-coverage/1",
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": os.path.relpath(app_path, REPO_ROOT),
        "scan_profile": "zap-api-scan -S (passive rules over a verified seed, GET only)",
        # Provenance, because this number used to be declared and now is not.
        # A reader must be able to tell which kind it is looking at without
        # reading this file.
        "coverage_provenance": "observed",
        "observed_from": observation.get("_path"),
        "observed_window": observation.get("window"),
        "observed_source": observation.get("source"),
        "observed_requests_total": len(observation.get("requests") or []),
        "routes_total": len(routes),
        "routes_reachable": len(covered),
        "routes_unreachable": len(gaps),
        "coverage_ratio": round(len(covered) / len(routes), 4),
        "unreachable_by_reason": by_reason,
        "routes": routes,
        "note": (
            "reachable_by_baseline describes what the CONFIGURED scan can "
            "touch, not whether a route is safe. An unreachable route has not "
            "been found clean -- it has not been looked at."
        ),
    }, routes


def render_prom(cov):
    lines = [
        "# Which of the application's routes the configured DAST scan can reach.",
        "# Written by platform/security/dast_coverage.py. A DAST PASS covers",
        "# only the reachable set -- see that file for why this is separate.",
        "# HELP devops_dast_routes_total Routes served by the application.",
        "# TYPE devops_dast_routes_total gauge",
        "devops_dast_routes_total %d" % cov["routes_total"],
        "# HELP devops_dast_routes_unscanned Routes the configured scan cannot reach.",
        "# TYPE devops_dast_routes_unscanned gauge",
        "devops_dast_routes_unscanned %d" % cov["routes_unreachable"],
        "# HELP devops_dast_coverage_ratio Reachable routes divided by total routes.",
        "# TYPE devops_dast_coverage_ratio gauge",
        "devops_dast_coverage_ratio %s" % cov["coverage_ratio"],
        "# HELP devops_dast_unscanned_by_reason Unreachable routes, by why the scan cannot reach them.",
        "# TYPE devops_dast_unscanned_by_reason gauge",
    ]
    for reason in sorted(cov["unreachable_by_reason"]):
        lines.append(
            'devops_dast_unscanned_by_reason{reason="%s"} %d'
            % (reason, cov["unreachable_by_reason"][reason])
        )
    return "\n".join(lines) + "\n"


def newest_observation(evidence_dir):
    """The most recent scan observation, by mtime.

    BY MTIME, NOT BY NAME. Sorting these by filename reads whichever stamp
    sorts last as current, and this repository has already shipped that bug
    once: the board read a three-day-old LLM review as the latest because the
    names happened to order that way. The newest file is the one most recently
    written, and nothing else.
    """
    import glob
    files = glob.glob(os.path.join(evidence_dir, "dast_observed_*.json"))
    if not files:
        return None
    return max(files, key=os.path.getmtime)


def load_observation(path):
    with open(path, "r") as handle:
        doc = json.load(handle)
    doc["_path"] = os.path.relpath(path, REPO_ROOT)
    return doc


def write_atomic(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as handle:
        handle.write(content)
    os.replace(tmp, path)


def main(argv):
    app_path = DEFAULT_APP
    out_path = DEFAULT_OUT
    prom_path = DEFAULT_PROM
    as_json = False
    write = True
    observed_path = None

    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--app":
            app_path = argv[index + 1]; index += 2
        elif arg == "--out":
            out_path = argv[index + 1]; index += 2
        elif arg == "--prom":
            prom_path = argv[index + 1]; index += 2
        elif arg == "--json":
            as_json = True; index += 1
        elif arg == "--observed":
            observed_path = argv[index + 1]; index += 2
        elif arg == "--no-write":
            write = False; index += 1
        else:
            sys.stderr.write("unknown argument: %s\n" % arg)
            return 2

    if observed_path is None:
        observed_path = newest_observation(os.path.dirname(DEFAULT_OUT))
    if observed_path is None or not os.path.exists(observed_path):
        sys.stderr.write(
            "REFUSED: no scan observation found.\n"
            "  Coverage is now what the scanner ACTUALLY touched, read from the\n"
            "  target's own request log (platform/security/dast_observe.py).\n"
            "  With no observation the only available answer is a declared one,\n"
            "  and a declared coverage number is precisely the defect this was\n"
            "  changed to remove. Run platform/security/scan_dast.sh first.\n")
        return 3

    observation = load_observation(observed_path)
    cov, routes = build(app_path, observation)
    if cov is None:
        sys.stderr.write(
            "REFUSED: parsed only %d route(s) from %s, expected at least %d.\n"
            "  The dispatcher patterns no longer match. Reporting coverage now\n"
            "  would describe a surface this parser can no longer see -- and\n"
            "  '0 gaps out of 0 routes' is the exact shape this file exists to\n"
            "  prevent.\n" % (len(routes), app_path, MIN_EXPECTED_ROUTES)
        )
        return 2

    if write:
        write_atomic(out_path, json.dumps(cov, indent=2, ensure_ascii=False) + "\n")
        write_atomic(prom_path, render_prom(cov))

    if as_json:
        print(json.dumps(cov, indent=2, ensure_ascii=False))
        return 0

    print("DAST route coverage  %s" % cov["scan_profile"])
    print(
        "  %d of %d routes reachable (%.0f%%)"
        % (cov["routes_reachable"], cov["routes_total"], cov["coverage_ratio"] * 100)
    )
    for route in cov["routes"]:
        mark = "scanned  " if route["reachable_by_baseline"] else "NOT SEEN "
        print("  %s %-6s %-32s %s" % (mark, route["method"], route["path"], route["reason"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

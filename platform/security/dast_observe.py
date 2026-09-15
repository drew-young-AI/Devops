#!/usr/bin/env python3
"""Turn the target's own request log into a record of what the scan touched.

Reads the application log on stdin (one JSON object per line, as
pilots/station2-twin/app/app.py emits) and writes the set of (method, path)
pairs the SCANNER requested during the scan window.

WHY THE SCANNER IS IDENTIFIED BY USER-AGENT, NOT BY TIME ALONE
--------------------------------------------------------------
The health probe requests /health/live every 10s and /metrics every 15s. Any
scan window wide enough to contain a scan also contains those, so a time-only
filter credits the scan with three routes it never sent -- and the emptier the
scan, the more of its apparent coverage would come from the health probe. That
is a coverage number that rises when the scanner does nothing.

WHY AN EMPTY RESULT IS WRITTEN RATHER THAN SUPPRESSED
-----------------------------------------------------
A scan that touched nothing must be visible as a scan that touched nothing.
Writing no file at all would let the previous run's observation stand in for
this one, which is how a stale artifact becomes a current claim.
"""

import argparse
import json
import re
import sys

# `"GET /twin/pump-01 HTTP/1.1" 200 -` -- the request line BaseHTTPRequestHandler
# formats. Anchored so a path containing a quote cannot shift the capture.
REQUEST_LINE = re.compile(r'^"([A-Z]+) (\S+) HTTP/[0-9.]+" (\d{3})')

# ZAP identifies itself in every request it makes. Matched case-insensitively
# and as a substring because the full string carries a version that changes.
SCANNER_MARK = "zap"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--from", dest="since", required=True)
    ap.add_argument("--to", dest="until", required=True)
    ap.add_argument("--source", required=True)
    ap.add_argument("--target", required=True)
    ap.add_argument("--agent-mark", default=SCANNER_MARK)
    args = ap.parse_args()

    seen, other_agents, lines_read, malformed = {}, set(), 0, 0
    for line in sys.stdin:
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        lines_read += 1
        try:
            record = json.loads(line)
        except ValueError:
            malformed += 1
            continue
        if record.get("event") != "http_request":
            continue
        agent = (record.get("agent") or "")
        match = REQUEST_LINE.match(record.get("message") or "")
        if not match:
            malformed += 1
            continue
        if args.agent_mark.lower() not in agent.lower():
            other_agents.add(agent.split("/")[0][:40] or "(none)")
            continue
        method, path, status = match.group(1), match.group(2), int(match.group(3))
        path = path.split("?")[0]
        key = (method, path)
        if key not in seen or status < seen[key]:
            seen[key] = status

    doc = {
        "schema": "dast-observed/1",
        "window": {"from": args.since, "to": args.until},
        "source": args.source,
        "target": args.target,
        "agent_mark": args.agent_mark,
        "log_lines_considered": lines_read,
        "malformed_lines": malformed,
        # Kept so "the scan touched nothing" can be told apart from "the log
        # had no requests at all". The first is a broken scan; the second is a
        # broken log pipeline, and they need different fixes.
        "other_agents_in_window": sorted(other_agents),
        # An explicit field rather than "len(requests) == 0", because the two
        # causes need different fixes and read identically otherwise: a scan
        # that requested nothing, versus a User-Agent filter that matches
        # nothing. The second one happened on the first run of this file --
        # ZAP's default agent is a plain browser string.
        "scanner_seen": bool(seen),
        "requests": [{"method": m, "path": p, "status": s}
                     for (m, p), s in sorted(seen.items())],
    }
    with open(args.out, "w") as handle:
        handle.write(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
    print("  scanner touched %d distinct route(s) at the target "
          "(%d log line(s) in window)" % (len(seen), lines_read))
    if not seen and lines_read:
        print("  WARNING: %d request(s) were logged in this window but none "
              "carried the agent mark %r -- the scan is unobservable, so "
              "coverage will read 0%%, not the previous run's number."
              % (lines_read, args.agent_mark))
    return 0


if __name__ == "__main__":
    sys.exit(main())

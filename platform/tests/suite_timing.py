#!/usr/bin/env python3
"""Turn one run's per-suite timings into a record and a five-line summary.

Read by nothing else yet, and that is the point: the cost of this suite was an
anecdote ("about eight minutes") with no attribution, so every decision about
what to speed up, split, or move to a nightly run was a guess. A total with no
breakdown also hides the opposite failure -- a suite that grows from 4s to 90s
never appears as anything but a slightly longer wait.

Input comes from the environment because the caller is bash and the rows are a
temp file it already owns:

  TIMING_FILE  lines of  name|tier|seconds|rc
  TOTAL        wall seconds for the whole run
  OUT          where to write the JSON record
  PLATFORM_TIERS / PLATFORM_SUITES  recorded so a partial run's numbers can
                                    never be read as a full run's

Prints the five most expensive suites with their share. Prints nothing and
exits 0 if there is no input: a missing cost report must not fail a test run.
"""
import json
import os
import sys
from datetime import datetime, timezone

path = os.environ.get("TIMING_FILE", "")
if not path or not os.path.exists(path):
    sys.exit(0)

rows = []
with open(path) as fh:
    for line in fh:
        parts = line.strip().split("|")
        if len(parts) != 4:
            continue
        name, tier, secs, rc = parts
        try:
            rows.append({"suite": name, "tier": int(tier),
                         "seconds": int(secs), "rc": int(rc)})
        except ValueError:
            continue
if not rows:
    sys.exit(0)

total = int(os.environ.get("TOTAL", "0") or 0)
measured = sum(r["seconds"] for r in rows)
record = {
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "total_seconds": total,
    # measured_seconds is the sum of the suites; total_seconds includes the
    # runner's own overhead (the cluster readyz probe, process spawn). Keeping
    # both means "where did the rest of the time go" is answerable instead of
    # being absorbed into whichever number is quoted.
    "measured_seconds": measured,
    "suite_count": len(rows),
    "platform_tiers": os.environ.get("PLATFORM_TIERS", ""),
    "platform_suites": os.environ.get("PLATFORM_SUITES", ""),
    "partial": bool(os.environ.get("PLATFORM_SUITES", "")),
    "suites": sorted(rows, key=lambda r: -r["seconds"]),
}

out = os.environ.get("OUT", "")
if out:
    try:
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "w") as fh:
            json.dump(record, fh, indent=2)
            fh.write("\n")
    except OSError as e:
        # A cost record that cannot be written is not a reason to fail a test
        # run; say so on stderr and carry on.
        print(f"suite_timing: could not write {out}: {e}", file=sys.stderr)

top = record["suites"][:5]
share = (lambda s: f"{s / measured * 100:4.1f}%" if measured else "   -")
print(f"COST  {measured}s measured across {len(rows)} suites"
      + (f" (run wall {total}s)" if total and total != measured else ""))
for r in top:
    print(f"  {share(r['seconds'])} {r['seconds']:>4}s  tier {r['tier']}  "
          f"{r['suite']}")
tail = measured - sum(r["seconds"] for r in top)
print(f"  {share(tail)} {tail:>4}s  the other {max(len(rows) - len(top), 0)}")

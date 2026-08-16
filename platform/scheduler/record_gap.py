#!/usr/bin/env python3
"""Record a coverage gap when a scheduled job ran much later than it should.

Called by run_job.sh with the previous and current run timestamps.

Why this is a separate concern from freshness: `status.sh` answers "is this
job running now", which resets the moment a late run completes. So a laptop
that slept for seven hours produces one catch-up run and then reports
ALL_FRESH, with nothing anywhere recording that nothing was watching for
seven hours. This file is that record.

The gap itself is not preventable -- a sleeping machine will not run checks,
and launchd deliberately coalesces missed StartInterval firings into a single
catch-up rather than replaying every one. Making it visible is the honest
alternative to pretending coverage was continuous.

Usage:
  record_gap.py <feed.jsonl> <job> <previous_iso> <current_iso> <interval_s>
"""

import json
import sys
from datetime import datetime

FMT = "%Y-%m-%dT%H:%M:%SZ"


def main():
    if len(sys.argv) != 6:
        return 0
    feed, job, previous, current, interval = sys.argv[1:]
    try:
        interval = int(interval)
        prev = datetime.strptime(previous, FMT)
        curr = datetime.strptime(current, FMT)
    except ValueError:
        # A malformed timestamp must not fail the job that just ran fine.
        return 0

    gap = (curr - prev).total_seconds()
    # Same grace window status.sh uses, so "was stale" and "had a gap" cannot
    # disagree about the same interval.
    if gap <= interval * 2 + 60:
        return 0

    with open(feed, "a", encoding="utf-8") as fh:
        fh.write(json.dumps({
            "job": job,
            "gap_seconds": int(gap),
            "gap_minutes": round(gap / 60, 1),
            "expected_interval_seconds": interval,
            "missed_runs": max(0, int(gap // interval) - 1),
            "from": previous,
            "to": current,
        }) + "\n")

    print(f"[{job}] COVERAGE GAP: {gap / 60:.0f} min with no run "
          f"(interval {interval // 60} min, ~{max(0, int(gap // interval) - 1)} missed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env bash
# Is the scheduler itself alive, and is every job actually running?
#
# THE PROBLEM THIS SOLVES:
#
# A scheduler cannot monitor itself. If launchd never loads the agent, or
# the plist is malformed, or the job dies on a PATH error, the result is
# not an alarm -- it is silence. And silence is exactly what a healthy
# system produces. Every scheduled check in the platform could be dead for a
# week and nothing would say so, because nothing was expecting to hear from
# them.
#
# So freshness is checked by the CONSUMER, not the producer. Each job records
# when it last ran; this reads those records and reports any job whose last
# run is older than it should be. A job that stopped running becomes STALE --
# a distinct, visible state, not an absence.
#
# Two thresholds, not one:
#   LATE   past its interval -- missed a slot, still within grace
#   STALE  past 2x its interval -- treat as not running
#
# One number cannot serve both a 15-minute job and a weekly one. With only
# the 2x rule, a DAILY job could be 47 hours old and still print ALL_FRESH
# directly above a row reading "39h ago, every 24h" -- a verdict more
# optimistic than the numbers beside it, which is worse than no verdict.
#
# Usage:
#   status.sh [--json]
#
# Exit: 0 all fresh and ok, 1 degraded/failed job, 2 critical, 3 a job is
# STALE or has never run -- deliberately the same "cannot determine" code
# check_health.sh uses, because it means the same thing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_DIR="$REPO_ROOT/evidence/scheduler"

AS_JSON=0
[ "${1:-}" = "--json" ] && AS_JSON=1

python3 - "$SCRIPT_DIR/jobs.conf" "$STATE_DIR" "$AS_JSON" <<'PY'
import json, os, sys, time
from datetime import datetime, timezone

jobs_conf, state_dir, as_json = sys.argv[1:]
as_json = int(as_json)

now = datetime.now(timezone.utc)
rows, worst = [], 0

for line in open(jobs_conf, encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    name, interval, timeout, command = line.split("|", 3)
    interval = int(interval)
    state_path = os.path.join(state_dir, f"{name}_last.json")

    if not os.path.isfile(state_path):
        # Never run at all. Not the same as "ran and failed", and worth
        # separating: it usually means the agent was never loaded.
        rows.append({"job": name, "status": "never-run", "age_seconds": None,
                     "interval_seconds": interval, "fresh": False,
                     "exit_code": None, "duration_seconds": None})
        worst = max(worst, 3)
        continue

    try:
        state = json.load(open(state_path, encoding="utf-8"))
    except Exception:
        rows.append({"job": name, "status": "unreadable-state", "age_seconds": None,
                     "interval_seconds": interval, "fresh": False,
                     "exit_code": None, "duration_seconds": None})
        worst = max(worst, 3)
        continue

    started = datetime.strptime(state["started_at"], "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=timezone.utc)
    age = int((now - started).total_seconds())
    # Two thresholds, because one number cannot serve a 15-minute job and a
    # weekly one. A 2x grace means a DAILY job can be 47 hours old and still
    # be called fresh -- the verdict then reads ALL_FRESH directly above a
    # row saying "39h ago, every 24h". A verdict that contradicts the
    # numbers printed beside it is worse than no verdict.
    late = age > interval + 60
    fresh = age <= (interval * 2 + 60)

    status = state.get("status", "unknown")
    rows.append({
        "job": name,
        "status": status,
        "age_seconds": age,
        "interval_seconds": interval,
        "fresh": fresh,
        # Distinct from stale: the job missed its slot but has not been gone
        # long enough to call it dead. Proportionate response, not silence.
        "late": late and fresh,
        "exit_code": state.get("exit_code"),
        "duration_seconds": state.get("duration_seconds"),
    })

    # Staleness outranks the recorded status. A job reporting "ok" from four
    # days ago is not ok -- it is a stale claim, and treating it as good news
    # is precisely the failure this script exists to prevent.
    if not fresh:
        worst = max(worst, 3)
    elif status in ("critical", "failed", "timeout"):
        worst = max(worst, 2)
    elif status in ("degraded", "unknown", "not-configured") or late:
        worst = max(worst, 1)

verdict = {0: "ALL_FRESH", 1: "DEGRADED_OR_LATE", 2: "CRITICAL",
           3: "STALE_OR_UNKNOWN"}[worst]

if as_json:
    print(json.dumps({"verdict": verdict, "exit_code": worst, "jobs": rows,
                      "checked_at": now.strftime("%Y-%m-%dT%H:%M:%SZ")},
                     indent=2, ensure_ascii=False))
    sys.exit(worst)

def human(seconds):
    if seconds is None:
        return "never"
    if seconds < 90:
        return f"{seconds}s ago"
    if seconds < 5400:
        return f"{seconds // 60}m ago"
    if seconds < 172800:
        return f"{seconds // 3600}h ago"
    return f"{seconds // 86400}d ago"

print(f"scheduler: {verdict}")
print()
print(f"  {'JOB':<10} {'STATUS':<14} {'LAST RUN':<12} {'EVERY':<8} FRESH")
print("  " + "-" * 56)
for r in rows:
    every = (f"{r['interval_seconds'] // 3600}h" if r["interval_seconds"] >= 3600
             else f"{r['interval_seconds'] // 60}m")
    mark = ("NO  <-- not running" if not r["fresh"]
            else "late" if r.get("late") else "yes")
    print(f"  {r['job']:<10} {r['status']:<14} {human(r['age_seconds']):<12} {every:<8} {mark}")

if any(r.get("late") for r in rows):
    print()
    print("  A job marked 'late' missed its slot but is still inside the grace")
    print("  window. Common cause: install.sh reloading an agent resets its")
    print("  StartInterval timer, which matters most for the weekly jobs.")

if worst == 3:
    print()
    print("  A job is STALE or has never run. The scheduler cannot report its")
    print("  own absence, which is why this check exists. Verify it is loaded:")
    print("    platform/scheduler/install.sh --status")
sys.exit(worst)
PY

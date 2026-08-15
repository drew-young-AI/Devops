#!/usr/bin/env bash
# Scheduler contract tests.
#
# The scheduler is the one component whose failure mode is SILENCE. A broken
# gate shouts; a scheduler that never fires produces exactly what a healthy
# one produces on a quiet day. So the assertions here concentrate on the
# machinery that turns absence into a visible state, and on the wrapper
# behaviours that keep one bad run from disabling a job forever.
#
# No launchd, no real jobs: everything runs against a temp state directory
# with fast synthetic jobs, so the suite stays runnable in CI.

set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="scheduler"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== scheduler contract =="

SANDBOX="$(make_sandbox)"
RUN="$SANDBOX/platform/scheduler/run_job.sh"
STATUS="$SANDBOX/platform/scheduler/status.sh"
STATE="$SANDBOX/evidence/scheduler"

# Synthetic jobs only -- fast, hermetic, and independent of whether docker or
# Vault happen to be running on the machine executing the tests.
cat > "$SANDBOX/platform/scheduler/jobs.conf" <<'CONF'
# name|interval|timeout|command
good|900|30|true
bad|900|30|false
slow|900|4|sleep 60
CONF

# --- argument handling ---------------------------------------------------

run_cmd "$RUN"
assert_rc 1 "no job name exits non-zero"

run_cmd "$RUN" nosuchjob
assert_rc 2 "unknown job exits 2"
assert_output_contains "Known jobs" "unknown job lists the valid ones"

# --- outcome recording ---------------------------------------------------

run_cmd "$RUN" good
assert_rc 0 "successful job exits 0"
assert_file_exists "$STATE/good_last.json" "successful run writes state"
assert_equals "ok" "$(python3 -c "
import json; print(json.load(open('$STATE/good_last.json'))['status'])")" \
  "successful run records status ok"

run_cmd "$RUN" bad
assert_rc 1 "failing job propagates its exit code"
assert_equals "failed" "$(python3 -c "
import json; print(json.load(open('$STATE/bad_last.json'))['status'])")" \
  "failing run records status failed"

# A failed run must still leave evidence. Otherwise "the job failed" and "the
# job never ran" look identical, which is the whole problem this component
# exists to solve.
assert_file_exists "$STATE/bad_last.json" "failing run still writes state"

# --- timeout -------------------------------------------------------------

# A hung job is worse than a failed one: it holds the lock, so every
# subsequent run is skipped while the schedule still reports green.
run_cmd "$RUN" slow
assert_rc 124 "hung job is killed and reported as timeout"
assert_equals "timeout" "$(python3 -c "
import json; print(json.load(open('$STATE/slow_last.json'))['status'])")" \
  "timeout is a distinct status, not a generic failure"

# --- locking -------------------------------------------------------------

LOCK="$STATE/.good.lock"
mkdir -p "$LOCK"
run_cmd "$RUN" good
assert_rc 0 "concurrent run exits cleanly rather than erroring"
assert_output_contains "already running" "concurrent run says why it skipped"
rm -rf "$LOCK"

# A lock left behind by a killed process would otherwise disable the job
# permanently, silently, and look exactly like a job that keeps being busy.
mkdir -p "$LOCK"
# Age it well past 2x the job's timeout.
touch -t 202001010000 "$LOCK"
run_cmd "$RUN" good
assert_rc 0 "stale lock does not permanently disable a job"
assert_output_contains "Stale lock" "stale lock is reported when broken"

# --- freshness: the check that catches a dead scheduler ------------------

# Narrow the config to the one healthy job. Deleting the failing jobs' STATE
# files is not equivalent -- they would still be listed in jobs.conf and so
# become "never-run", which is exit 3. That distinction is the point of the
# never-run state, so the test has to respect it rather than route around it.
cat > "$SANDBOX/platform/scheduler/jobs.conf" <<'CONF'
good|900|30|true
CONF
run_cmd "$RUN" good
run_cmd "$STATUS"
assert_rc 0 "status exits 0 when every job is fresh and ok"

# Backdate one job past its grace window (2x interval + 60s).
python3 - "$STATE/good_last.json" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
p = sys.argv[1]
d = json.load(open(p))
old = datetime.now(timezone.utc) - timedelta(seconds=d["interval_seconds"] * 5)
d["started_at"] = old.strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(d, open(p, "w"), indent=2)
PY
run_cmd "$STATUS"
assert_rc 3 "a job that stopped running reports exit 3, not success"
assert_output_contains "not running" "stale job is named in the output"

# Staleness must outrank the recorded status. A job reporting "ok" from four
# days ago is a stale claim, and reading it as good news is precisely the
# failure this component exists to prevent.
assert_output_contains "STALE_OR_UNKNOWN" "stale ok-status still verdicts as stale"

rm -f "$STATE/good_last.json"
run_cmd "$STATUS"
assert_rc 3 "a job that never ran is exit 3, distinct from a passing run"
assert_output_contains "never" "never-run job is shown as never, not as failed"

# --- jobs.conf sanity on the REAL config ---------------------------------

REAL_CONF="$REPO_ROOT/platform/scheduler/jobs.conf"
BAD_FIELDS="$(python3 - "$REAL_CONF" <<'PY'
import sys
bad = []
for n, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    parts = line.split("|")
    if len(parts) != 4:
        bad.append(f"line {n}: {len(parts)} fields")
        continue
    name, interval, timeout, _ = parts
    if not interval.isdigit() or not timeout.isdigit():
        bad.append(f"line {n}: non-numeric interval/timeout")
    # A timeout longer than the interval means a slow run is still holding
    # the lock when the next one fires -- the schedule silently halves.
    elif int(timeout) >= int(interval):
        bad.append(f"{name}: timeout {timeout}s >= interval {interval}s")
print("; ".join(bad))
PY
)"
assert_equals "" "$BAD_FIELDS" "real jobs.conf is well-formed and timeouts fit their intervals"

# Scheduling an interactive command would delete a human gate by accident:
# deploy.sh promote waits for someone to type PROMOTE.
FORBIDDEN="$(grep -E '\|.*(promote|rollback)' "$REAL_CONF" | grep -v '^#' || true)"
assert_equals "" "$FORBIDDEN" "no human-approval command is scheduled"

suite_summary

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

# --- never-run is three different claims ---------------------------------
#
# `never-run` used to mean `fresh: false` unconditionally, and probe_scheduler
# turns any not-fresh job into FAIL "not running: <job>". Every newly added job
# is never-run for its first interval, so adding the weekly `ingestslow` job on
# 2026-09-03 would have held that node red for six days about a job that was
# installed correctly and simply had not come due -- and that node is the one
# that detects a STOPPED job. A red guaranteed for a week is a red people wait
# out.
#
# The agent's install time now decides which of three claims is being made.
# All three are asserted, because the middle one is a softening and a softening
# that cannot be shown to still catch the hard case is just a disabled check.
NRSAND="$(make_sandbox)"
NRAGENTS="$NRSAND/agents"
mkdir -p "$NRAGENTS"
cat > "$NRSAND/platform/scheduler/jobs.conf" <<'CONF'
# name|interval|timeout|command
weekly|604800|60|true
CONF

# 1. no agent file at all -- the agent was never loaded. Must stay FAIL.
run_cmd env SCHEDULER_AGENT_DIR="$NRAGENTS" "$NRSAND/platform/scheduler/status.sh" --json
NR_STATUS="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
j=d['jobs'][0]
print(j['status'], j['fresh'])" "$LAST_STDOUT" 2>/dev/null || echo ERR)"
assert_equals "never-run False" "$NR_STATUS" \
  "a job with no launchd agent is never-run and NOT fresh"

# 2. agent written just now, interval a week -- not due yet, and fresh.
touch "$NRAGENTS/devops.platform.weekly.plist"
run_cmd env SCHEDULER_AGENT_DIR="$NRAGENTS" "$NRSAND/platform/scheduler/status.sh" --json
NR_STATUS="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
j=d['jobs'][0]
print(j['status'], j['fresh'])" "$LAST_STDOUT" 2>/dev/null || echo ERR)"
assert_equals "not-yet-due True" "$NR_STATUS" \
  "a job installed less than one interval ago is not-yet-due, not 'not running'"

# 3. THE ONE THAT MATTERS. Agent installed longer ago than the interval and
#    still no run: it was loaded, it came due, it never fired. Must be FAIL --
#    otherwise step 2 has quietly disabled the check instead of narrowing it.
#    The install time is faked by backdating the file, which is the only input
#    the rule reads.
touch -t 202001010000 "$NRAGENTS/devops.platform.weekly.plist"
run_cmd env SCHEDULER_AGENT_DIR="$NRAGENTS" "$NRSAND/platform/scheduler/status.sh" --json
NR_STATUS="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
j=d['jobs'][0]
print(j['status'], j['fresh'])" "$LAST_STDOUT" 2>/dev/null || echo ERR)"
assert_equals "never-run False" "$NR_STATUS" \
  "a job installed longer ago than its interval and never fired is still a failure"

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

# Long-interval jobs must not have their timers reset by routine config
# edits. install.sh used to bootout/bootstrap everything on every run, which
# is invisible for a 15-minute job and fatal for a weekly one: during active
# development the config changes far more often than every seven days, so
# the restore drill and SAST sweep never fired at all. `launchctl print`
# reported runs = 0 for them.
RELOAD_LOGIC="$(grep -c 'cmp -s "$plist.new" "$plist.installed"' "$REPO_ROOT/platform/scheduler/install.sh" || true)"
assert_equals "1" "$RELOAD_LOGIC" \
  "install.sh reloads only changed plists (avoids needless churn)"

# The real defence, asserted against WHAT IS INSTALLED rather than against
# the installer's source or its log messages.
#
# The previous version of this check grepped install.sh for the string
# "timer preserved". That passed for as long as nobody reworded an echo, and
# said nothing about whether the machine was actually scheduled correctly --
# a test of a log line, not of a behaviour.
#
# StartInterval counts from load, so any reload restarts it and a daily or
# weekly job can be starved indefinitely. StartCalendarInterval fires at an
# absolute time and survives reload (measured: an agent rebootstrapped 41
# seconds before its calendar time still fired at that time). So: every job
# at or above an hour must be calendar-scheduled, and every short one must
# not be -- a 15-minute calendar entry is not expressible.
if [ -d "$HOME/Library/LaunchAgents" ]; then
  WRONG_SCHED=""
  # Read the boundary from install.sh instead of restating it. The previous
  # version hardcoded 3600 here, so raising the threshold in install.sh turned
  # this assertion red while the installer was behaving exactly as intended --
  # a test that fails when the thing it tests is corrected is a test measuring
  # its own stale copy of a constant.
  CAL_THRESHOLD="$(grep -oE '^CALENDAR_THRESHOLD_SECONDS=[0-9]+' \
      "$REPO_ROOT/platform/scheduler/install.sh" | cut -d= -f2)"
  if [ -z "$CAL_THRESHOLD" ]; then
    _fail "install.sh declares CALENDAR_THRESHOLD_SECONDS" \
          "not found -- this assertion cannot be evaluated without it"
    CAL_THRESHOLD=86400
  else
    _pass "install.sh declares the calendar threshold as one named constant (${CAL_THRESHOLD}s)"
  fi

  while IFS='|' read -r name interval _ _; do
    p="$HOME/Library/LaunchAgents/devops.platform.${name}.plist"
    [ -f "$p" ] || continue
    if [ "$interval" -ge "$CAL_THRESHOLD" ]; then
      grep -q 'StartCalendarInterval' "$p" \
        || WRONG_SCHED="$WRONG_SCHED $name(interval=${interval}s uses StartInterval)"
    else
      grep -q 'StartCalendarInterval' "$p" \
        && WRONG_SCHED="$WRONG_SCHED $name(short job wrongly calendar-scheduled)"
    fi
  done < <(grep -vE '^\s*#|^\s*$' "$REAL_CONF")
  assert_equals "" "$WRONG_SCHED" \
    "installed plists: long jobs are calendar-scheduled, short jobs are not"
else
  _pass "installed plists: skipped (no LaunchAgents dir on this machine)"
fi

# A job that only ever ran because a human typed it is not a working
# schedule. run_job.sh must be able to tell the two apart, and a manual run
# must not overwrite the record of when the schedule last fired -- otherwise
# hand-running a job papers over a dead timer, which is exactly how every
# long-interval job here looked healthy while launchd showed runs = 0.
RUN_JOB="$REPO_ROOT/platform/scheduler/run_job.sh"
assert_equals "1" "$(grep -c 'XPC_SERVICE_NAME:-' "$RUN_JOB" || true)" \
  "run_job.sh distinguishes a scheduled run from a manual one"
assert_equals "1" "$(grep -cF 'LAST_SCHEDULED="$PREVIOUS_SCHEDULED"' "$RUN_JOB" || true)" \
  "a manual run preserves the last-scheduled timestamp rather than clearing it"

# Behavioural, not textual: drive run_job.sh both ways and read the record.
PROV_JOB="health"
env XPC_SERVICE_NAME="devops.platform.$PROV_JOB" "$RUN_JOB" "$PROV_JOB" >/dev/null 2>&1 || true
PROV_SCHED="$(python3 -c "
import json;d=json.load(open('$REPO_ROOT/evidence/scheduler/${PROV_JOB}_last.json'))
print(d.get('trigger'), d.get('last_scheduled_at') is not None)" 2>/dev/null || echo "err")"
assert_equals "scheduled True" "$PROV_SCHED" "a launchd-spawned run records trigger=scheduled"

"$RUN_JOB" "$PROV_JOB" >/dev/null 2>&1 || true
PROV_MANUAL="$(python3 -c "
import json;d=json.load(open('$REPO_ROOT/evidence/scheduler/${PROV_JOB}_last.json'))
print(d.get('trigger'), d.get('last_scheduled_at') is not None)" 2>/dev/null || echo "err")"
assert_equals "manual True" "$PROV_MANUAL" \
  "a manual run records trigger=manual WITHOUT erasing the schedule evidence"

UNCONDITIONAL="$(grep -cE '^\s*launchctl bootout .*\$\{label\}' "$REPO_ROOT/platform/scheduler/install.sh" || true)"
if [ "$UNCONDITIONAL" -le 2 ]; then
  _pass "no unconditional bootout in the install path"
else
  _fail "no unconditional bootout in the install path" \
    "found $UNCONDITIONAL -- a blanket bootout resets every StartInterval timer"
fi

suite_summary

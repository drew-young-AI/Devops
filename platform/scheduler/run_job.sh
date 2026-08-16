#!/usr/bin/env bash
# Runs one scheduled job, and leaves proof that it ran.
#
# The wrapper matters more than the schedule. A bare cron entry gives you a
# command that either worked or didn't, with the answer in a log nobody
# reads. Everything here exists because of a specific way that fails:
#
#   LOCKING     -- a slow job overlapping itself doubles load and can corrupt
#                  shared state (two backups writing the same archive dir).
#   TIMEOUT     -- a hung job is worse than a failed one. It holds the lock
#                  forever, so every later run is skipped while the schedule
#                  still looks green.
#   EVIDENCE    -- every run writes its outcome. "It never ran" and "it ran
#                  and was fine" are otherwise the same observation, which is
#                  the failure mode this whole platform keeps guarding
#                  against (see check_health.sh's exit 3).
#   STATE CHANGE-- notification fires on TRANSITION, not on every run. A job
#                  that reports failure every 15 minutes trains people to
#                  mute it, and a muted alert is a disabled one.
#   PATH        -- launchd hands a process almost no environment. Docker,
#                  python and the rest are simply absent unless set here.
#
# Usage:
#   run_job.sh <job-name>
#
# Exit code is the job's own, so launchd records it too.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
JOB="${1:?Usage: run_job.sh <job-name>}"

# launchd gives an agent a near-empty PATH -- /usr/bin:/bin:/usr/sbin:/sbin.
# docker, python3 from uv, semgrep and mkcert all live outside that, so a job
# that works in a terminal fails under launchd with "command not found" and
# nothing else. This is the single most common way a launchd job silently
# does nothing.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

STATE_DIR="$REPO_ROOT/evidence/scheduler"
LOG_DIR="$STATE_DIR/logs"
mkdir -p "$STATE_DIR" "$LOG_DIR"

STATE_FILE="$STATE_DIR/${JOB}_last.json"
LOG_FILE="$LOG_DIR/${JOB}.log"
LOCK_DIR="$STATE_DIR/.${JOB}.lock"

JOB_LINE="$(grep -E "^${JOB}\|" "$SCRIPT_DIR/jobs.conf" 2>/dev/null | head -1)"
if [ -z "$JOB_LINE" ]; then
  echo "Unknown job '$JOB'. Known jobs:" >&2
  grep -vE '^\s*#|^\s*$' "$SCRIPT_DIR/jobs.conf" | cut -d'|' -f1 | sed 's/^/  /' >&2
  exit 2
fi

IFS='|' read -r _ INTERVAL TIMEOUT COMMAND <<< "$JOB_LINE"

# mkdir is atomic, which is what makes it a correct lock. A lock FILE tested
# with -e and then created is a race with a window between the two.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  LOCK_AGE=$(( $(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || date +%s) ))
  # A lock older than twice the job's own timeout cannot belong to a live
  # run -- it is a leftover from a killed process. Left alone it silently
  # disables the job forever.
  if [ "$LOCK_AGE" -gt $((TIMEOUT * 2)) ]; then
    echo "Stale lock (${LOCK_AGE}s old, timeout ${TIMEOUT}s) -- breaking it." >&2
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || exit 3
  else
    echo "Job '$JOB' already running (lock ${LOCK_AGE}s old). Skipping."
    exit 0
  fi
fi
trap 'rm -rf "$LOCK_DIR"' EXIT

PREVIOUS_STATUS="unknown"
PREVIOUS_STARTED=""
if [ -f "$STATE_FILE" ]; then
  PREVIOUS_STATUS="$(python3 -c "
import json
try: print(json.load(open('$STATE_FILE')).get('status', 'unknown'))
except Exception: print('unknown')
" 2>/dev/null || echo unknown)"
  PREVIOUS_STARTED="$(python3 -c "
import json
try: print(json.load(open('$STATE_FILE')).get('started_at', ''))
except Exception: print('')
" 2>/dev/null || echo '')"
fi

STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
START_EPOCH="$(date +%s)"

{
  echo "=== $STARTED_AT  job=$JOB  cmd=$COMMAND"
} >> "$LOG_FILE"

cd "$REPO_ROOT"

# No `timeout` on macOS by default, and adding coreutils for one binary is a
# dependency this platform does not need: run in the background, poll, kill.
OUTPUT_FILE="$(mktemp)"
RC_FILE="$(mktemp)"
# The exit code is written to a file by the subshell rather than collected
# with `wait`. An earlier version used `wait "$JOB_PID"` plus `disown` to
# suppress bash's "Terminated: 15" chatter -- but disowning removes the job
# from the table, so `wait` can no longer retrieve its status and EVERY job
# reported success, including `false`. The scheduler looked perfect and was
# recording nothing but "ok". Caught by test_scheduler.sh, not by inspection.
( bash -c "$COMMAND" > "$OUTPUT_FILE" 2>&1; echo $? > "$RC_FILE" ) &
JOB_PID=$!
disown 2>/dev/null || true

TIMED_OUT=0
ELAPSED=0
while kill -0 "$JOB_PID" 2>/dev/null; do
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    kill -TERM "$JOB_PID" 2>/dev/null
    sleep 5
    kill -KILL "$JOB_PID" 2>/dev/null
    TIMED_OUT=1
    break
  fi
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done
RC="$(cat "$RC_FILE" 2>/dev/null || echo 1)"
[ -z "$RC" ] && RC=1
[ "$TIMED_OUT" -eq 1 ] && RC=124
rm -f "$RC_FILE"

DURATION=$(( $(date +%s) - START_EPOCH ))

# check_health.sh uses a graded exit code (0 healthy / 1 degraded /
# 2 critical / 3 unknown) rather than plain success-or-failure, so a generic
# `rc != 0 means broken` reading would call a DEGRADED platform simply
# "failed" and lose the distinction the exit codes exist to carry.
case "$JOB:$RC" in
  health:0) STATUS="ok" ;;
  health:1) STATUS="degraded" ;;
  health:2) STATUS="critical" ;;
  health:3) STATUS="unknown" ;;
  *:0)      STATUS="ok" ;;
  *:124)    STATUS="timeout" ;;
  # 78 = EX_CONFIG: the job ran fine and had nothing to do because it
  # was never configured. Neither a failure (daily noise people mute)
  # nor ok (which would claim work happened). A visible third state.
  *:78)     STATUS="not-configured" ;;
  *)        STATUS="failed" ;;
esac

tail -50 "$OUTPUT_FILE" >> "$LOG_FILE"
echo "=== finished rc=$RC status=$STATUS duration=${DURATION}s" >> "$LOG_FILE"

# Bounded log. The platform guards other services against filling the disk;
# it would be absurd for the scheduler's own logs to be the thing that does.
if [ "$(wc -c < "$LOG_FILE" | tr -d ' ')" -gt 1048576 ]; then
  tail -2000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

python3 - "$STATE_FILE" "$JOB" "$STARTED_AT" "$STATUS" "$RC" "$DURATION" \
  "$INTERVAL" "$COMMAND" "$OUTPUT_FILE" <<'PY'
import json, pathlib, sys
state_file, job, started, status, rc, duration, interval, command, out = sys.argv[1:]
tail = pathlib.Path(out).read_text(errors="replace").strip().splitlines()[-15:]
pathlib.Path(state_file).write_text(json.dumps({
    "job": job,
    "started_at": started,
    "status": status,
    "exit_code": int(rc),
    "duration_seconds": int(duration),
    "interval_seconds": int(interval),
    "command": command,
    "output_tail": tail,
}, indent=2) + "\n")
PY

rm -f "$OUTPUT_FILE"

# Notify only on transition. Two directions both matter: something broke,
# and something recovered -- a recovery nobody hears about leaves people
# acting on a problem that no longer exists.
if [ "$STATUS" != "$PREVIOUS_STATUS" ] && [ "$PREVIOUS_STATUS" != "unknown" ]; then
  "$SCRIPT_DIR/notify.sh" "$JOB" "$PREVIOUS_STATUS" "$STATUS" || true
fi

# Coverage gaps.
#
# launchd's StartInterval does not fire while the machine is asleep, and on
# wake it COALESCES: one catch-up run, not one per missed interval. A laptop
# that slept eight hours therefore produces a single late run -- after which
# freshness resets and the hole in coverage becomes invisible. Observed
# exactly that: 172- and 443-minute gaps between "every 15 minutes" health
# checks, with status.sh reporting ALL_FRESH immediately afterwards.
#
# The gap cannot be prevented here; a sleeping laptop is not going to run
# checks. What can be fixed is that it left no trace. Freshness answers "is
# it running now"; this answers "was there a period when nothing was
# watching" -- which is the question an incident review actually asks, and
# the one the platform could not answer.
if [ -n "$PREVIOUS_STARTED" ]; then
  python3 "$SCRIPT_DIR/record_gap.py" \
    "$STATE_DIR/coverage_gaps.jsonl" "$JOB" "$PREVIOUS_STARTED" \
    "$STARTED_AT" "$INTERVAL" || true
fi

echo "[$JOB] $STATUS (rc=$RC, ${DURATION}s)"
exit "$RC"

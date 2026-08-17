#!/usr/bin/env bash
# Install / remove the scheduled jobs as launchd user agents.
#
# launchd, not cron: it is the supported mechanism on macOS, it restarts
# agents after a reboot, and it runs jobs that were missed while the machine
# was asleep -- which matters on a laptop, where cron would simply skip a
# night's backup and never mention it.
#
# USER agents (~/Library/LaunchAgents), never system daemons. Nothing is
# written to /Library or /usr/local, and removal is one command. This is a
# persistent change to the machine, so it is reversible by design and the
# uninstall path is tested, not assumed.
#
# Usage:
#   install.sh              install (or refresh) every job
#   install.sh --status     show what launchd currently has loaded
#   install.sh --uninstall  remove every job
#
# Deliberately NOT installed: anything that needs a human decision mid-run.
# `deploy.sh promote` waits for someone to type PROMOTE and must never be
# scheduled -- automating it would delete the release gate by accident.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_DIR="$HOME/Library/LaunchAgents"
LABEL_PREFIX="devops.platform"

ACTION="install"
case "${1:-}" in
  --status)    ACTION="status" ;;
  --uninstall) ACTION="uninstall" ;;
  "")          ACTION="install" ;;
  *) echo "Usage: $0 [--status|--uninstall]" >&2; exit 1 ;;
esac

jobs() {
  grep -vE '^\s*#|^\s*$' "$SCRIPT_DIR/jobs.conf"
}

if [ "$ACTION" = "status" ]; then
  echo "=== launchd agents ($LABEL_PREFIX.*) ==="
  # Snapshot launchctl ONCE, then match against the string.
  #
  # The previous version ran `launchctl list | grep -q "$label"` per job and
  # reported 5 of 8 loaded agents as MISSING -- non-deterministically. Cause:
  # `grep -q` exits the instant it matches, launchctl gets SIGPIPE, and under
  # `set -o pipefail` the pipeline returns non-zero, so a successful match was
  # read as "not found". Whether it happened depended on whether launchctl had
  # finished writing, which is why the failures looked random.
  #
  # A status check that reports healthy agents as missing is worse than no
  # check: it would have sent someone reinstalling a scheduler that was
  # working fine.
  LOADED_AGENTS="$(launchctl list 2>/dev/null || true)"
  found=0
  while IFS='|' read -r name interval _ _; do
    label="${LABEL_PREFIX}.${name}"
    line="$(printf '%s\n' "$LOADED_AGENTS" | grep -F "$label" || true)"
    if [ -n "$line" ]; then
      echo "  loaded    $label   (every $((interval / 60))m)   [pid/status: $(echo "$line" | awk '{print $1"/"$2}')]"
      found=$((found + 1))
    else
      echo "  MISSING   $label"
    fi
  done < <(jobs)
  echo ""
  echo "$found agent(s) loaded. Job freshness (the check that matters):"
  echo "  platform/scheduler/status.sh"
  exit 0
fi

if [ "$ACTION" = "uninstall" ]; then
  echo "=== removing launchd agents ==="
  while IFS='|' read -r name _ _ _; do
    label="${LABEL_PREFIX}.${name}"
    plist="$AGENT_DIR/${label}.plist"
    launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
    rm -f "$plist" "$plist.installed" "$plist.new"
    echo "  removed $label"
  done < <(jobs)
  echo ""
  echo "Done. evidence/scheduler/ is left in place -- it is the record of"
  echo "what ran, and deleting history on an uninstall would be wrong."
  exit 0
fi

mkdir -p "$AGENT_DIR"
echo "=== installing launchd agents ==="
# Snapshot once; see the same SIGPIPE-under-pipefail note in --status.
LOADED_NOW="$(launchctl list 2>/dev/null || true)"

# SHORT JOBS GET StartInterval. LONG JOBS GET StartCalendarInterval.
#
# StartInterval counts from when the agent was LOADED, so every reload
# restarts the countdown. For a 15-minute job that is invisible. For a daily
# or weekly one it is fatal in a way that hides itself: during active
# development the scheduler config is touched far more often than every
# seven days, so the timer is reset before it ever expires and the job never
# runs -- while its last (manual) run still looks recent and green.
#
# The "only reload if changed" guard below reduces how often that happens but
# cannot fix it, because a legitimate config change still resets every timer.
#
# StartCalendarInterval fires at an absolute wall-clock time. Reloading an
# agent does not move the next occurrence, so a daily job stays daily no
# matter how often the platform is reinstalled -- and launchd runs a missed
# calendar job when the machine wakes, which is the behaviour a laptop needs.
#
# Stagger. The previous version computed an `offset` for exactly this reason
# and then never referenced it, so the comment described behaviour that did
# not exist. Long jobs are now spread 20 minutes apart for real: a backup, a
# DAST scan and a restore drill firing together on a laptop is bad enough,
# and the restore drill starts a container while the backup is reading the
# volume it is about to archive.
DAILY_BASE_HOUR=3
WEEKLY_BASE_HOUR=4
WEEKLY_WEEKDAY=0        # Sunday
STAGGER_MINUTES=20
long_idx=0

while IFS='|' read -r name interval timeout command; do
  label="${LABEL_PREFIX}.${name}"
  plist="$AGENT_DIR/${label}.plist"

  if [ "$interval" -lt 3600 ]; then
    schedule_xml="  <key>StartInterval</key><integer>${interval}</integer>"
    schedule_desc="every $((interval / 60))m"
  else
    shift_min=$(( long_idx * STAGGER_MINUTES ))
    fire_min=$(( shift_min % 60 ))
    if [ "$interval" -eq 604800 ]; then
      fire_hour=$(( WEEKLY_BASE_HOUR + shift_min / 60 ))
      schedule_xml="  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key><integer>${WEEKLY_WEEKDAY}</integer>
    <key>Hour</key><integer>${fire_hour}</integer>
    <key>Minute</key><integer>${fire_min}</integer>
  </dict>"
      schedule_desc="Sundays $(printf '%02d:%02d' "$fire_hour" "$fire_min")"
    else
      fire_hour=$(( DAILY_BASE_HOUR + shift_min / 60 ))
      schedule_xml="  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>${fire_hour}</integer>
    <key>Minute</key><integer>${fire_min}</integer>
  </dict>"
      schedule_desc="daily $(printf '%02d:%02d' "$fire_hour" "$fire_min")"
    fi
    long_idx=$((long_idx + 1))
  fi

  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SCRIPT_DIR}/run_job.sh</string>
    <string>${name}</string>
  </array>
${schedule_xml}
  <key>WorkingDirectory</key><string>${REPO_ROOT}</string>
  <!-- launchd provides almost no environment. run_job.sh sets PATH itself,
       but HOME is needed before that to resolve ~/.local/bin. -->
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${HOME}</string>
  </dict>
  <!-- RunAtLoad is off deliberately: installing the agents should not
       immediately fire eight jobs at once, including a restore drill. -->
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>${REPO_ROOT}/evidence/scheduler/logs/${name}.launchd.log</string>
  <key>StandardErrorPath</key><string>${REPO_ROOT}/evidence/scheduler/logs/${name}.launchd.log</string>
  <key>ProcessType</key><string>Background</string>
  <!-- Nice value keeps a scan or restore drill from competing with whatever
       the human at this laptop is actually doing. -->
  <key>Nice</key><integer>5</integer>
</dict>
</plist>
PLIST

  # Reload ONLY if the plist actually changed.
  #
  # The previous version booted out and bootstrapped every agent on every
  # run, which reloads a changed plist correctly and also RESETS EVERY
  # StartInterval TIMER back to zero. Invisible for a 15-minute job. Fatal
  # for a weekly one: during active development the scheduler config is
  # touched far more often than every seven days, so the restore drill, the
  # SAST sweep and the rotation check would never fire at all.
  #
  # Confirmed, not theorised: `launchctl print` reported `runs = 0` for the
  # daily jobs while the 15-minute job showed `runs = 58`. The weekly ones
  # had never executed on their own schedule even once.
  #
  # This guard is still worth keeping now that long jobs use
  # StartCalendarInterval -- an unnecessary bootout/bootstrap is churn either
  # way -- but it is no longer load-bearing for them. Measured: an agent
  # rebooted 41 seconds before its calendar time still fired at that time.
  if [ -f "$plist.new" ]; then rm -f "$plist.new"; fi
  mv "$plist" "$plist.new"
  if [ -f "$plist.installed" ] && cmp -s "$plist.new" "$plist.installed" \
     && printf '%s\n' "$LOADED_NOW" | grep -qF "$label"; then
    mv "$plist.new" "$plist"
    echo "  unchanged  $label  ($schedule_desc)"
  else
    mv "$plist.new" "$plist"
    launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
    cp "$plist" "$plist.installed"
    echo "  (re)loaded $label  ($schedule_desc, timeout ${timeout}s)"
  fi
done < <(jobs)

mkdir -p "$REPO_ROOT/evidence/scheduler/logs"

echo ""
echo "Installed. Nothing has run yet (RunAtLoad is off)."
echo ""
echo "  check freshness:  platform/scheduler/status.sh"
echo "  check launchd:    platform/scheduler/install.sh --status"
echo "  remove:           platform/scheduler/install.sh --uninstall"

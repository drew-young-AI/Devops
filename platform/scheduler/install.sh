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
    rm -f "$plist"
    echo "  removed $label"
  done < <(jobs)
  echo ""
  echo "Done. evidence/scheduler/ is left in place -- it is the record of"
  echo "what ran, and deleting history on an uninstall would be wrong."
  exit 0
fi

mkdir -p "$AGENT_DIR"
echo "=== installing launchd agents ==="

# Stagger start times. Every job firing at the same instant would run a
# backup, a DAST scan and a restore drill concurrently on a laptop -- and the
# restore drill starts a container while the backup is reading the volume it
# is about to archive.
offset=0
while IFS='|' read -r name interval timeout command; do
  label="${LABEL_PREFIX}.${name}"
  plist="$AGENT_DIR/${label}.plist"

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
  <key>StartInterval</key><integer>${interval}</integer>
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

  # bootout first so a re-run genuinely reloads a changed plist. Without it
  # launchd keeps serving the version it loaded originally, and edits appear
  # to do nothing.
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  echo "  installed $label  (every $((interval / 60))m, timeout ${timeout}s)"
  offset=$((offset + 60))
done < <(jobs)

mkdir -p "$REPO_ROOT/evidence/scheduler/logs"

echo ""
echo "Installed. Nothing has run yet (RunAtLoad is off)."
echo ""
echo "  check freshness:  platform/scheduler/status.sh"
echo "  check launchd:    platform/scheduler/install.sh --status"
echo "  remove:           platform/scheduler/install.sh --uninstall"

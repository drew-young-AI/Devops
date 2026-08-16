#!/usr/bin/env bash
# Sync verified backups to a cloud remote (Google Drive et al) via rclone.
#
# Sibling of sync_offsite.sh, which handles filesystem destinations and
# refuses to write to the same physical device. This one handles remotes,
# and carries the equivalent refusal for a different failure:
#
#   IT REFUSES TO UPLOAD UNENCRYPTED PLATFORM STATE TO A THIRD PARTY.
#
# Only the Vault archive is encrypted at rest. The rest is not: ~22 MB of
# Grafana data containing users, API keys and sessions; the audit trail with
# every secret path, policy name and token accessor; Alertmanager silences.
# Handing that to Google unencrypted is not a backup decision, it is a
# disclosure. So the destination must be an rclone `crypt` remote -- client
# side encryption, before anything leaves the machine -- and a plain remote
# is declined rather than used.
#
# WHY NOT THE GOOGLE DRIVE DESKTOP APP.
#
# It mounts under ~/Library/CloudStorage, which is a FUSE mount, so it has a
# different device id and sync_offsite.sh's check would happily pass it. But
# a file placed in a sync folder is STILL ON THE LOCAL DISK until the upload
# finishes. A disk failure in between loses it, while everything looks
# synced. That is the same "looks like the fix" trap the device check exists
# to stop, in a subtler form -- and sync state there is not scriptable, so a
# scheduled job could never get a trustworthy verdict from it.
#
# rclone verifies against the REMOTE. `rclone cryptcheck` hashes the local
# file the way the crypt remote would and compares with what is actually
# stored there, so "verified" means the bytes are at Google, not that a
# folder copy succeeded.
#
# CREDENTIALS: this script never handles them. rclone.conf is produced by
# `rclone config`, which does browser OAuth as the user. See README.
#
# Usage:
#   platform/backup/sync_remote.sh                    sync + verify
#   platform/backup/sync_remote.sh --check            report only
#   RCLONE_REMOTE=gdrive-crypt:devops-backups ...
#
# Exit 0 only when every set is verified present at the remote.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCAL_DIR="$SCRIPT_DIR/archives"
RCLONE_CONF="${RCLONE_CONF:-$SCRIPT_DIR/.rclone.conf}"
REMOTE="${RCLONE_REMOTE:-}"
RCLONE_IMAGE="${RCLONE_IMAGE:-rclone/rclone:latest}"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

if [ -z "$REMOTE" ]; then
  cat >&2 <<'EOF'
RCLONE_REMOTE is not set, so nothing was uploaded.

Set it to a CRYPT remote and a path, for example:
  RCLONE_REMOTE=gdrive-crypt:devops-backups

One-time setup (you run this, not the platform -- it opens a browser and
authorises with your own Google account; no credential is ever handed to
anything else):

  platform/backup/setup_rclone.sh

That creates two remotes: `gdrive` (the OAuth connection) and
`gdrive-crypt` (client-side encryption wrapping it). Always point this
script at the crypt one.
EOF
  # 78 = EX_CONFIG. Deliberately not 1: "never set up" and "set up and
  # broken" are different facts, and the scheduler has to tell them apart.
  # Reporting an unconfigured destination as a daily failure trains people
  # to mute the job; reporting it as ok would be a lie about where the
  # backups are.
  exit 78
fi

if [ ! -f "$RCLONE_CONF" ]; then
  echo "No rclone config at $RCLONE_CONF." >&2
  echo "Run: platform/backup/setup_rclone.sh" >&2
  exit 78
fi

rc() {
  # Config mounted read-only; rclone must not rewrite the file we treat as
  # the credential of record.
  docker run --rm \
    -v "$RCLONE_CONF:/config/rclone/rclone.conf:ro" \
    -v "$LOCAL_DIR:/data:ro" \
    "$RCLONE_IMAGE" "$@" </dev/null
}

REMOTE_NAME="${REMOTE%%:*}"

echo "=== [remote] $LOCAL_DIR -> $REMOTE ==="

# The refusal that matters. `rclone config show` reports each remote's type;
# anything other than `crypt` means the bytes would leave this machine
# readable.
REMOTE_TYPE="$(rc config show "$REMOTE_NAME" 2>/dev/null | grep -E '^type *=' | head -1 | sed 's/.*= *//' | tr -d '\r')"
if [ -z "$REMOTE_TYPE" ]; then
  echo "REFUSED: remote '$REMOTE_NAME' is not defined in $RCLONE_CONF." >&2
  exit 1
fi
if [ "$REMOTE_TYPE" != "crypt" ]; then
  echo "REFUSED: remote '$REMOTE_NAME' is type '$REMOTE_TYPE', not 'crypt'." >&2
  echo "" >&2
  echo "Only the Vault archive is encrypted at rest. Grafana data (users, API" >&2
  echo "keys, sessions), the audit trail (every secret path, policy name and" >&2
  echo "token accessor) and Alertmanager state are NOT. Uploading those to a" >&2
  echo "third party in the clear is a disclosure, not a backup." >&2
  echo "" >&2
  echo "Point RCLONE_REMOTE at a crypt remote. setup_rclone.sh creates one." >&2
  exit 1
fi
echo "  remote type: crypt -- encrypted client-side before upload"

if ! rc lsd "$REMOTE" >/dev/null 2>&1; then
  # Distinguish "remote unreachable" from "path not created yet": the second
  # is normal on a first run, the first is a failure worth reporting as one.
  if ! rc lsd "${REMOTE%%:*}:" >/dev/null 2>&1; then
    echo "REMOTE UNREACHABLE: cannot list $REMOTE_NAME. Network down, or the" >&2
    echo "OAuth token has expired -- re-run platform/backup/setup_rclone.sh." >&2
    exit 1
  fi
fi

LOCAL_SETS="$(find "$LOCAL_DIR" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
REMOTE_SETS="$(rc lsd "$REMOTE" 2>/dev/null | wc -l | tr -d ' ')"
echo "  local sets: $LOCAL_SETS   remote sets: $REMOTE_SETS"

if [ "$CHECK_ONLY" -eq 1 ]; then
  MISSING="$(rc check /data "$REMOTE" --one-way --size-only 2>&1 | grep -cE "^ERROR|not in" || true)"
  if [ "$MISSING" -eq 0 ]; then
    echo "All local sets present at the remote."
    exit 0
  fi
  echo "$MISSING local file(s) missing at the remote. Run without --check." >&2
  exit 1
fi

echo ""
echo "=== [remote] uploading ==="
if ! rc copy /data "$REMOTE" --transfers 2 --checkers 4 --stats 0 2>&1 | tail -5; then
  echo "UPLOAD FAILED -- see output above." >&2
  exit 1
fi

echo ""
echo "=== [remote] verifying against what is actually stored ==="
# cryptcheck, not check: on a crypt remote the stored bytes are ciphertext,
# so a plain hash comparison cannot work. cryptcheck encrypts the local file
# the same way and compares, which is the difference between "the upload
# command exited 0" and "the correct bytes are at the far end".
VERIFY="$(rc cryptcheck /data "$REMOTE" --one-way 2>&1)"
VERIFY_RC=$?
echo "$VERIFY" | grep -E "differences|matching files|ERROR" | tail -4 | sed 's/^/  /'

if [ "$VERIFY_RC" -ne 0 ]; then
  echo "VERIFICATION FAILED: the remote does not match local." >&2
  echo "Do NOT prune local archives -- the offsite copy is not trustworthy." >&2
  exit 1
fi

echo ""
echo "REMOTE SYNC PASS -- contents verified at $REMOTE"
echo ""
echo "Reminder: the crypt password and OAuth token in $RCLONE_CONF are the"
echo "ONLY way to read these backups. They are not recoverable from the"
echo "backups themselves. Keep a copy in a password manager, beside the"
echo "Vault unseal keys."

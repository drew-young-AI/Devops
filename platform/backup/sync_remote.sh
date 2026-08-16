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
# TWO LEVELS OF THAT REFUSAL, AND WHY THE SECOND ONE EXISTS.
#
# The cheap check reads `type = crypt` out of rclone.conf. That is reading
# our own homework: it confirms what we asked for, not what happens. The
# probe (--probe, and automatically before every upload) writes a file
# containing a known marker through the crypt remote, then fetches the stored
# object back THROUGH THE UNDERLYING REMOTE and confirms the marker is not in
# it. That is the difference between "configured for encryption" and
# "observed to be encrypted at the far end".
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
# setup_rclone.sh, which does browser OAuth as the user. See README.
#
# Usage:
#   platform/backup/sync_remote.sh                    sync + verify
#   platform/backup/sync_remote.sh --check            report only, no upload
#   platform/backup/sync_remote.sh --probe            encryption probe only
#   RCLONE_REMOTE=gdrive-crypt: ...
#
# Exit 0 only when every set is verified present at the remote.
# Exit 78 (EX_CONFIG) when no destination has been set up at all.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCAL_DIR="$SCRIPT_DIR/archives"

# A DIRECTORY, not a file. rclone saves config by renaming a temp file over
# it, which is impossible across a single-file bind mount -- it fails with
# "device or resource busy", logs the error, and still exits 0. Mounting the
# directory also lets rclone persist refreshed OAuth tokens instead of
# re-deriving one on every run.
RCLONE_DIR="${RCLONE_DIR:-$SCRIPT_DIR/.rclone}"
RCLONE_CONF="$RCLONE_DIR/rclone.conf"
REMOTE="${RCLONE_REMOTE:-}"
RCLONE_IMAGE="${RCLONE_IMAGE:-rclone/rclone:latest}"

MODE="sync"
case "${1:-}" in
  --check) MODE="check" ;;
  --probe) MODE="probe" ;;
  "") ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac

# --probe is about the remote itself, not about any particular backup set, so
# it can run before the first backup exists. It still needs to know which
# remote to probe, hence the default rather than a hard requirement.
if [ -z "$REMOTE" ] && [ "$MODE" = "probe" ]; then
  REMOTE="gdrive-crypt:"
fi

if [ -z "$REMOTE" ]; then
  cat >&2 <<'EOF'
RCLONE_REMOTE is not set, so nothing was uploaded.

Set it to a CRYPT remote and a path, for example:
  RCLONE_REMOTE=gdrive-crypt:

One-time setup (you authorise it, not the platform -- it opens a browser and
signs in with your own Google account; no credential is ever handed to
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
  # Older layout, before the directory-mount fix.
  if [ -f "$SCRIPT_DIR/.rclone.conf" ]; then
    echo "Found the old single-file config at $SCRIPT_DIR/.rclone.conf." >&2
    echo "Run platform/backup/setup_rclone.sh to migrate it." >&2
    exit 78
  fi
  echo "No rclone config at $RCLONE_CONF." >&2
  echo "Run: platform/backup/setup_rclone.sh" >&2
  exit 78
fi

REMOTE_NAME="${REMOTE%%:*}"

rc() {
  docker run --rm \
    -v "$RCLONE_DIR:/config/rclone" \
    -v "$LOCAL_DIR:/data:ro" \
    "$RCLONE_IMAGE" "$@" </dev/null
}

# --- the refusal ---------------------------------------------------------

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

# --- the probe -----------------------------------------------------------

probe_encryption() {
  local probe_dir marker enc backing raw_path stored roundtrip
  probe_dir="$(mktemp -d)"
  # Unique per run: a stale marker from a previous probe still sitting at the
  # remote must not be able to satisfy this one.
  marker="devops-crypt-probe-$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
  printf '%s\n' "$marker" > "$probe_dir/probe.txt"

  echo "=== [probe] proving the far end holds ciphertext ==="

  probe_rc() {
    docker run --rm \
      -v "$RCLONE_DIR:/config/rclone" \
      -v "$probe_dir:/probe:ro" \
      "$RCLONE_IMAGE" "$@" </dev/null
  }

  if ! probe_rc copy /probe "$REMOTE_NAME:_probe" >/dev/null 2>&1; then
    echo "  FAILED: could not upload the probe file." >&2
    rm -rf "$probe_dir"
    return 1
  fi

  # 1. Round trip: what we wrote is what we can read back.
  roundtrip="$(probe_rc cat "$REMOTE_NAME:_probe/probe.txt" 2>/dev/null | tr -d '\r\n')"
  if [ "$roundtrip" != "$marker" ]; then
    echo "  FAILED: round trip did not return what was written." >&2
    probe_rc purge "$REMOTE_NAME:_probe" >/dev/null 2>&1
    rm -rf "$probe_dir"
    return 1
  fi
  echo "  round trip through the crypt remote returns the original bytes"

  # 2. The part that actually matters. Ask the crypt remote what filename it
  #    stored the probe under, then read that object through the UNDERLYING
  #    remote -- bypassing decryption -- and confirm the marker is absent.
  enc="$(probe_rc cryptdecode --reverse "$REMOTE_NAME:" _probe/probe.txt 2>/dev/null | awk '{print $2}' | tr -d '\r')"
  backing="$(probe_rc config show "$REMOTE_NAME" 2>/dev/null | grep -E '^remote *=' | head -1 | sed 's/.*= *//' | tr -d '\r')"

  if [ -z "$enc" ] || [ -z "$backing" ]; then
    echo "  FAILED: could not resolve the stored path on the underlying remote." >&2
    probe_rc purge "$REMOTE_NAME:_probe" >/dev/null 2>&1
    rm -rf "$probe_dir"
    return 1
  fi

  case "$backing" in
    *:) raw_path="${backing}${enc}" ;;
    *)  raw_path="${backing}/${enc}" ;;
  esac

  stored="$(probe_rc cat "$raw_path" 2>/dev/null)"
  if [ -z "$stored" ]; then
    echo "  FAILED: could not read the stored object at $raw_path." >&2
    probe_rc purge "$REMOTE_NAME:_probe" >/dev/null 2>&1
    rm -rf "$probe_dir"
    return 1
  fi

  if printf '%s' "$stored" | grep -q "$marker"; then
    echo "" >&2
    echo "  LEAK: the marker is readable in the stored object." >&2
    echo "  Content is NOT encrypted at the remote. Refusing to upload." >&2
    probe_rc purge "$REMOTE_NAME:_probe" >/dev/null 2>&1
    rm -rf "$probe_dir"
    return 1
  fi
  echo "  stored filename is encrypted: $enc"
  echo "  stored content does not contain the plaintext marker"

  probe_rc purge "$REMOTE_NAME:_probe" >/dev/null 2>&1
  rm -rf "$probe_dir"
  echo "  PROBE PASS -- ciphertext confirmed at $backing"
  return 0
}

if [ "$MODE" = "probe" ]; then
  probe_encryption
  exit $?
fi

echo "=== [remote] $LOCAL_DIR -> $REMOTE ==="
echo "  remote type: crypt -- encrypted client-side before upload"

if ! rc lsd "$REMOTE" >/dev/null 2>&1; then
  # Distinguish "remote unreachable" from "path not created yet": the second
  # is normal on a first run, the first is a failure worth reporting as one.
  if ! rc lsd "$REMOTE_NAME:" >/dev/null 2>&1; then
    echo "REMOTE UNREACHABLE: cannot list $REMOTE_NAME. Network down, or the" >&2
    echo "OAuth token has expired -- re-run platform/backup/setup_rclone.sh." >&2
    exit 1
  fi
fi

if [ ! -d "$LOCAL_DIR" ]; then
  echo "No local archives at $LOCAL_DIR. Run platform/backup/backup.sh first." >&2
  exit 1
fi

LOCAL_SETS="$(find "$LOCAL_DIR" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
REMOTE_SETS="$(rc lsd "$REMOTE" 2>/dev/null | wc -l | tr -d ' ')"
echo "  local sets: $LOCAL_SETS   remote sets: $REMOTE_SETS"

if [ "$MODE" = "check" ]; then
  MISSING="$(rc check /data "$REMOTE" --one-way --size-only 2>&1 | grep -cE "^ERROR|not in" || true)"
  if [ "$MISSING" -eq 0 ]; then
    echo "All local sets present at the remote."
    exit 0
  fi
  echo "$MISSING local file(s) missing at the remote. Run without --check." >&2
  exit 1
fi

# Before uploading, not after. A leak discovered afterwards is a leak.
echo ""
if ! probe_encryption; then
  echo "" >&2
  echo "ABORTED: encryption could not be proven, so nothing was uploaded." >&2
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

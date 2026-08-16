#!/usr/bin/env bash
# One-time setup of the Google Drive backup destination.
#
# YOU AUTHORISE. NOTHING HERE EVER SEES YOUR PASSWORD.
#
# rclone opens a Google sign-in page in your browser, you approve there, and
# Google hands back an OAuth token. No password is typed into this platform,
# none is stored here, and nothing has to be shared with anyone -- including
# with the agent that wrote this script -- for the backups to work.
#
# WHY THIS IS NOT `rclone config`.
#
# The first version of this script drove rclone's interactive wizard. Two
# things were wrong with that, both found by running it rather than reading
# it:
#
#   1. It needed a TTY, so it could only run from a separate Terminal window.
#      `rclone authorize` does not: it starts a local callback listener,
#      prints a URL, and waits. The only human step is clicking Allow in a
#      browser, which never needed a terminal in the first place.
#
#   2. It mounted rclone.conf as a SINGLE FILE. rclone saves config by
#      renaming a temp file over it, and you cannot rename across a
#      single-file bind mount -- "device or resource busy". rclone logs that
#      error, prints the remote it thinks it created, and STILL EXITS 0,
#      leaving a zero-byte config. The whole browser dance would have been
#      spent for nothing. Hence the directory mount below.
#
# SCOPE IS drive.file, NOT drive.
#
# drive.file grants access only to files this application itself created.
# The token cannot read anything already in your Drive. A backup destination
# never needs to read your existing files, and a credential that sits on this
# machine for years should be able to do only the one thing it is for.
#
# Two remotes get created:
#
#   gdrive        the OAuth connection to Google Drive
#   gdrive-crypt  client-side encryption wrapping it
#
# Always back up to the CRYPT one. sync_remote.sh refuses anything else, and
# that refusal is the point: only the Vault archive is encrypted at rest, so
# a plain remote would ship Grafana users, API keys and the entire audit
# trail to Google in readable form.
#
# THE CIRCULARITY YOU MUST NOT WALK INTO.
#
# The crypt password and the OAuth token live in rclone.conf. That file is
# the only way to read these backups -- and it is NOT recoverable from them,
# because it is what decrypts them. Storing it "safely in the backup" is the
# classic way to end up with an archive nobody can open. Put a copy in a
# password manager, beside the Vault unseal keys, before you rely on this.
#
# Usage:
#   platform/backup/setup_rclone.sh              set up (no-op if already done)
#   platform/backup/setup_rclone.sh --force      replace an existing config
#
# Exit 0 only when both remotes exist AND an end-to-end encryption probe has
# confirmed that what lands at Google is ciphertext.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A DIRECTORY, not a file -- see note 2 in the header. rclone must be able to
# rename within it.
RCLONE_DIR="${RCLONE_DIR:-$SCRIPT_DIR/.rclone}"
RCLONE_CONF="$RCLONE_DIR/rclone.conf"
LEGACY_CONF="$SCRIPT_DIR/.rclone.conf"
RCLONE_IMAGE="${RCLONE_IMAGE:-rclone/rclone:latest}"
DRIVE_FOLDER="${DRIVE_FOLDER:-devops-backups}"
AUTH_TIMEOUT="${AUTH_TIMEOUT:-300}"
AUTH_CONTAINER="devops-rclone-authorize"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

die() { echo "$@" >&2; exit 1; }

rc() {
  docker run --rm -v "$RCLONE_DIR:/config/rclone" "$RCLONE_IMAGE" "$@" </dev/null
}

# --- preconditions -------------------------------------------------------

docker info >/dev/null 2>&1 || die "Docker is not running. Start Docker Desktop and re-run."

mkdir -p "$RCLONE_DIR"
chmod 700 "$RCLONE_DIR"

if [ -f "$LEGACY_CONF" ] && [ ! -f "$RCLONE_CONF" ]; then
  echo "Migrating existing config from $LEGACY_CONF"
  mv "$LEGACY_CONF" "$RCLONE_CONF"
fi

if [ -f "$RCLONE_CONF" ] && grep -q '^\[gdrive-crypt\]' "$RCLONE_CONF" 2>/dev/null && [ "$FORCE" -eq 0 ]; then
  echo "Already configured: $RCLONE_CONF has a gdrive-crypt remote."
  echo "Re-run with --force to replace it."
  echo ""
  echo "NOTE: replacing the crypt password makes every archive already at the"
  echo "remote unreadable. Keep the old config if you need those."
  exit 0
fi

if [ "$FORCE" -eq 1 ] && [ -f "$RCLONE_CONF" ]; then
  BACKUP_CONF="$RCLONE_CONF.replaced-$(date -u +%Y%m%dT%H%M%SZ)"
  cp "$RCLONE_CONF" "$BACKUP_CONF"
  chmod 600 "$BACKUP_CONF"
  echo "Existing config preserved at $BACKUP_CONF"
  echo "(archives encrypted with the OLD password can only be read with it)"
fi

if lsof -nP -iTCP:53682 -sTCP:LISTEN >/dev/null 2>&1; then
  die "Port 53682 is already in use. That is rclone's OAuth callback port.
Close whatever is holding it and re-run."
fi

# --- phase 1: OAuth ------------------------------------------------------

AUTH_LOG="$(mktemp -t rclone-auth)"
cleanup() {
  docker rm -f "$AUTH_CONTAINER" >/dev/null 2>&1 || true
  rm -f "$AUTH_LOG"
}
trap cleanup EXIT

docker rm -f "$AUTH_CONTAINER" >/dev/null 2>&1 || true

echo "=== Google Drive authorisation ==="
echo ""

# No -it. This is the whole reason the script no longer needs a terminal:
# authorize starts an HTTP listener on 53682 and blocks until the browser
# redirects back to it.
docker run --rm --name "$AUTH_CONTAINER" \
  -p 127.0.0.1:53682:53682 \
  "$RCLONE_IMAGE" authorize drive >"$AUTH_LOG" 2>&1 &

AUTH_URL=""
for _ in $(seq 1 30); do
  AUTH_URL="$(grep -oE 'http://127\.0\.0\.1:53682/auth\?state=[A-Za-z0-9_-]+' "$AUTH_LOG" 2>/dev/null | head -1)"
  [ -n "$AUTH_URL" ] && break
  sleep 1
done

if [ -z "$AUTH_URL" ]; then
  echo "rclone never printed an authorisation URL. Its output was:" >&2
  cat "$AUTH_LOG" >&2
  exit 1
fi

echo "Opening your browser to authorise access to Google Drive."
echo ""
echo "  $AUTH_URL"
echo ""
echo "Sign in with the Google account that should hold the backups, and"
echo "approve. Scope requested is drive.file -- rclone will be able to touch"
echo "only the files it creates itself, not anything already in your Drive."
echo ""
open "$AUTH_URL" 2>/dev/null || echo "(could not open a browser automatically -- click the link above)"

echo "Waiting up to ${AUTH_TIMEOUT}s for you to approve..."
TOKEN=""
for _ in $(seq 1 "$AUTH_TIMEOUT"); do
  TOKEN="$(grep -oE '\{"access_token".*\}' "$AUTH_LOG" 2>/dev/null | head -1)"
  [ -n "$TOKEN" ] && break
  # If the container died without producing a token, stop waiting for one.
  if ! docker ps --format '{{.Names}}' | grep -qx "$AUTH_CONTAINER"; then
    sleep 1
    TOKEN="$(grep -oE '\{"access_token".*\}' "$AUTH_LOG" 2>/dev/null | head -1)"
    break
  fi
  sleep 1
done

if [ -z "$TOKEN" ]; then
  echo "" >&2
  echo "No token received. Either the approval was not completed, or the" >&2
  echo "browser could not reach the callback listener. rclone said:" >&2
  echo "" >&2
  tail -20 "$AUTH_LOG" >&2
  exit 1
fi
echo "  authorised"

# --- phase 2: the Drive remote -------------------------------------------

# --non-interactive is required, not optional. Without it rclone ignores the
# token we just obtained and starts a SECOND OAuth flow, then blocks forever
# waiting on a callback nobody is going to make.
rc config create gdrive drive \
  scope=drive.file \
  "token=$TOKEN" \
  --non-interactive >/dev/null 2>&1

grep -q '^\[gdrive\]' "$RCLONE_CONF" 2>/dev/null \
  || die "The gdrive remote was not written to $RCLONE_CONF."
echo "  gdrive remote created (scope: drive.file)"

# --- phase 3: the crypt wrapper ------------------------------------------

# Generated, not chosen. Nothing has to memorise these: rclone.conf is the
# artifact you protect, and it is what the password manager gets. A password
# a human picked would be weaker for no benefit.
CRYPT_PASS="${RCLONE_CRYPT_PASSWORD:-$(openssl rand -base64 24)}"
CRYPT_SALT="${RCLONE_CRYPT_SALT:-$(openssl rand -base64 24)}"

# --obscure is explicit rather than relying on rclone's autodetect: a 24-byte
# base64 string is exactly the shape rclone's own docs warn it can mistake
# for an already-obscured value, which would write the password in the clear.
rc config create gdrive-crypt crypt \
  "remote=gdrive:$DRIVE_FOLDER" \
  filename_encryption=standard \
  directory_name_encryption=true \
  "password=$CRYPT_PASS" \
  "password2=$CRYPT_SALT" \
  --obscure \
  --non-interactive >/dev/null 2>&1

unset CRYPT_PASS CRYPT_SALT

grep -q '^\[gdrive-crypt\]' "$RCLONE_CONF" 2>/dev/null \
  || die "The gdrive-crypt remote was not written to $RCLONE_CONF."

chmod 600 "$RCLONE_CONF"
echo "  gdrive-crypt remote created (client-side encryption)"

# --- phase 4: prove it ---------------------------------------------------

echo ""
echo "=== verifying ==="

TYPE="$(rc config show gdrive-crypt 2>/dev/null | grep -E '^type *=' | head -1 | sed 's/.*= *//' | tr -d '\r')"
[ "$TYPE" = "crypt" ] || die "gdrive-crypt is type '$TYPE', not 'crypt'."
echo "  gdrive-crypt is a crypt remote"

if rc lsd gdrive: >/dev/null 2>&1; then
  echo "  Drive reachable and the token works"
else
  die "Could not list Drive. The token may not have been granted."
fi

# The claim this whole mechanism rests on is "the bytes at Google are
# unreadable". That claim is not established by the config file saying
# type=crypt -- that is reading our own homework. sync_remote.sh --probe
# writes a known marker, fetches the stored object back through the
# UNDERLYING remote, and confirms the marker is not in it.
if ! "$SCRIPT_DIR/sync_remote.sh" --probe; then
  die "Encryption probe FAILED. Do not use this remote for backups."
fi

cat <<EOF

Setup complete. Config written to:
  $RCLONE_CONF   (chmod 600, gitignored)

DO THIS NOW, BEFORE YOU RELY ON THE BACKUPS:
  Copy that file's contents into your password manager, beside the Vault
  unseal keys. It holds the OAuth token and the crypt password, it is the
  only way to decrypt these backups, and it cannot be recovered from them.

The scheduled offsite job picks this up automatically -- it has been
reporting not-configured until now. To run the first sync immediately:

  RCLONE_REMOTE=gdrive-crypt: platform/backup/sync_remote.sh
EOF

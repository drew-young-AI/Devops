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
# RUN IT TWICE. THAT IS THE DESIGN, NOT A WORKAROUND.
#
#   platform/backup/setup_rclone.sh     -> prints a link, leaves it live
#   ...you click the link and approve, whenever you like...
#   platform/backup/setup_rclone.sh     -> picks up the token, finishes
#
# The first two versions of this script BLOCKED waiting for approval, on a
# fixed timer. That was wrong in a way worth recording: it coupled setup to
# the operator being at the keyboard inside a five-minute window, and when
# the window expired it printed the authorisation URL and suggested re-running
# -- but the URL was already dead, because the listener serving it died with
# the script. A recovery instruction that cannot work is worse than none.
#
# So the listener now outlives the script. The link stays valid until it is
# used or cancelled, and the second invocation harvests the result.
#
# WHY THIS IS NOT `rclone config`.
#
# The very first version drove rclone's interactive wizard. Two things were
# wrong with that, both found by running it rather than reading it:
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
#   platform/backup/setup_rclone.sh              start, or finish if approved
#   platform/backup/setup_rclone.sh --status     what is this waiting on
#   platform/backup/setup_rclone.sh --cancel     drop a pending authorisation
#   platform/backup/setup_rclone.sh --force      replace an existing config
#
# Exit 0 when setup completes, OR when an authorisation link is left pending
# (that is a normal intermediate state, not a failure). Exit 1 on error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A DIRECTORY, not a file -- see note 2 in the header. rclone must be able to
# rename within it.
RCLONE_DIR="${RCLONE_DIR:-$SCRIPT_DIR/.rclone}"
RCLONE_CONF="$RCLONE_DIR/rclone.conf"
LEGACY_CONF="$SCRIPT_DIR/.rclone.conf"
RCLONE_IMAGE="${RCLONE_IMAGE:-rclone/rclone:latest}"
DRIVE_FOLDER="${DRIVE_FOLDER:-devops-backups}"
AUTH_CONTAINER="devops-rclone-authorize"

FORCE=0
ACTION="auto"
case "${1:-}" in
  --force)  FORCE=1 ;;
  --status) ACTION="status" ;;
  --cancel) ACTION="cancel" ;;
  "") ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac

die() { echo "$@" >&2; exit 1; }

rc() {
  docker run --rm -v "$RCLONE_DIR:/config/rclone" "$RCLONE_IMAGE" "$@" </dev/null
}

# Deliberately NOT `docker ps | grep -q`: under `pipefail` a short-circuiting
# grep can SIGPIPE the producer and turn a live container into a reported-dead
# one. That shape already inverted one liveness check in this platform (the
# launchctl agent count), so it is avoided on sight rather than after it bites.
container_state() {
  local all
  all="$(docker ps -a --format '{{.Names}} {{.State}}' 2>/dev/null)"
  case "$all" in
    *"$AUTH_CONTAINER running"*) echo "running" ;;
    *"$AUTH_CONTAINER"*)         echo "exited" ;;
    *)                           echo "absent" ;;
  esac
}

auth_log()   { docker logs "$AUTH_CONTAINER" 2>&1; }
auth_url()   { auth_log | grep -oE 'http://127\.0\.0\.1:53682/auth\?state=[A-Za-z0-9_-]+' | head -1; }
auth_token() { auth_log | grep -oE '\{"access_token".*\}' | head -1; }

# --- preconditions -------------------------------------------------------

docker info >/dev/null 2>&1 || die "Docker is not running. Start Docker Desktop and re-run."

mkdir -p "$RCLONE_DIR"
chmod 700 "$RCLONE_DIR"

if [ -f "$LEGACY_CONF" ] && [ ! -f "$RCLONE_CONF" ]; then
  echo "Migrating existing config from $LEGACY_CONF"
  mv "$LEGACY_CONF" "$RCLONE_CONF"
fi

# --- --cancel / --status -------------------------------------------------

if [ "$ACTION" = "cancel" ]; then
  if [ "$(container_state)" = "absent" ]; then
    echo "Nothing pending."
  else
    docker rm -f "$AUTH_CONTAINER" >/dev/null 2>&1
    echo "Pending authorisation dropped. The link is now dead."
  fi
  exit 0
fi

if [ "$ACTION" = "status" ]; then
  if [ -f "$RCLONE_CONF" ] && grep -q '^\[gdrive-crypt\]' "$RCLONE_CONF" 2>/dev/null; then
    echo "CONFIGURED -- $RCLONE_CONF has a gdrive-crypt remote."
    exit 0
  fi
  case "$(container_state)" in
    running)
      if [ -n "$(auth_token)" ]; then
        echo "APPROVED -- run setup_rclone.sh to finish."
      else
        echo "WAITING for approval. Open this link:"
        echo ""
        echo "  $(auth_url)"
      fi
      ;;
    exited) echo "STALE -- a previous authorisation ended. Re-run setup_rclone.sh." ;;
    absent) echo "NOT STARTED -- run setup_rclone.sh." ;;
  esac
  exit 0
fi

# --- already done? -------------------------------------------------------

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

# --- phase 1: is there a token waiting to be harvested? ------------------

TOKEN=""
STATE="$(container_state)"

if [ "$STATE" != "absent" ]; then
  TOKEN="$(auth_token)"
  if [ -z "$TOKEN" ] && [ "$STATE" = "running" ]; then
    URL="$(auth_url)"
    echo "An authorisation is already pending and the link is still live."
    echo ""
    echo "  $URL"
    echo ""
    echo "Approve in your browser, then run this script again to finish:"
    echo "  platform/backup/setup_rclone.sh"
    echo ""
    echo "To abandon it instead: platform/backup/setup_rclone.sh --cancel"
    open "$URL" 2>/dev/null || true
    exit 0
  fi
  if [ -z "$TOKEN" ]; then
    echo "A previous authorisation attempt ended without a token. Restarting."
    docker rm -f "$AUTH_CONTAINER" >/dev/null 2>&1
    STATE="absent"
  fi
fi

# --- phase 1b: start a fresh authorisation -------------------------------

if [ -z "$TOKEN" ]; then
  if lsof -nP -iTCP:53682 -sTCP:LISTEN >/dev/null 2>&1; then
    die "Port 53682 is already in use. That is rclone's OAuth callback port.
Close whatever is holding it and re-run."
  fi

  # Detached, and NOT --rm. The container must outlive this script so the
  # link stays clickable, and its logs must survive its exit so the next
  # invocation can read the token out of them. --rm would delete both.
  docker rm -f "$AUTH_CONTAINER" >/dev/null 2>&1
  docker run -d --name "$AUTH_CONTAINER" \
    -p 127.0.0.1:53682:53682 \
    "$RCLONE_IMAGE" authorize drive >/dev/null 2>&1 \
    || die "Could not start the authorisation listener."

  URL=""
  for _ in $(seq 1 30); do
    URL="$(auth_url)"
    [ -n "$URL" ] && break
    sleep 1
  done

  if [ -z "$URL" ]; then
    echo "rclone never printed an authorisation URL. Its output was:" >&2
    auth_log >&2
    docker rm -f "$AUTH_CONTAINER" >/dev/null 2>&1
    exit 1
  fi

  cat <<EOF

=== Authorise Google Drive ===

Open this link and approve:

  $URL

Sign in with the Google account that should hold the backups. The scope
requested is drive.file, so rclone will be able to touch only the files it
creates itself -- it cannot read anything already in your Drive.

The link stays live until you use it. There is no time limit and nothing is
blocking. When you have approved, run:

  platform/backup/setup_rclone.sh

To check what it is waiting on:  setup_rclone.sh --status
To abandon it:                   setup_rclone.sh --cancel
EOF

  if open "$URL" 2>/dev/null; then
    echo ""
    echo "(a browser tab should have opened -- if not, use the link above)"
  fi
  exit 0
fi

# --- phase 2: the Drive remote -------------------------------------------

echo "Authorisation received."
docker rm -f "$AUTH_CONTAINER" >/dev/null 2>&1

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

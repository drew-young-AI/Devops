#!/usr/bin/env bash
# One-time interactive setup of the Google Drive backup destination.
#
# YOU RUN THIS. NOTHING ELSE EVER SEES YOUR CREDENTIALS.
#
# rclone opens a browser, you sign in to Google yourself, and Google hands
# rclone an OAuth token scoped to Drive. No password is typed into this
# platform, none is stored here, and nothing needs to be shared with anyone
# to make the backups work.
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
# The crypt password and the OAuth token live in .rclone.conf. That file is
# the only way to read these backups -- and it is NOT recoverable from them,
# because it is what decrypts them. Storing it "safely in the backup" is the
# classic way to end up with an archive nobody can open. Put a copy in a
# password manager, beside the Vault unseal keys, before you rely on this.
#
# Usage:
#   platform/backup/setup_rclone.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# This flow is irreducibly interactive: a browser OAuth round-trip and
# `docker run -it`. Without a TTY, `read` hits EOF immediately, `set -e`
# kills the script, and the only symptom is the instructions printing and
# then nothing -- which reads as "it finished". Refuse loudly instead.
if [ ! -t 0 ] || [ ! -t 1 ]; then
  cat >&2 <<'NOTTY'
This script needs a real terminal and cannot run here.

It opens a browser for Google sign-in and runs `docker run -it`, both of
which require a TTY. Run it from a normal Terminal window:

  cd /Users/drew/ENV/Devops
  platform/backup/setup_rclone.sh

(Running it without a TTY previously just stopped after printing the
instructions, with no error -- which is why this check exists.)
NOTTY
  exit 1
fi
RCLONE_CONF="$SCRIPT_DIR/.rclone.conf"
RCLONE_IMAGE="${RCLONE_IMAGE:-rclone/rclone:latest}"

cat <<'EOF'
=== Google Drive backup setup ===

You are about to run rclone's interactive configuration. It will:

  1. ask you to create a remote -- choose:  n  (new remote)
     name it:                               gdrive
     storage type:                          drive        (Google Drive)
     client_id / client_secret:             leave blank (press enter)
     scope:                                 1            (full access)
     root_folder_id / service_account:      leave blank
     Edit advanced config:                  n
     Use auto config:                       y  -> a browser opens, you sign in
     Configure as Shared Drive:             n

  2. create a SECOND remote for encryption -- choose:  n
     name it:                               gdrive-crypt
     storage type:                          crypt
     remote:                                gdrive:devops-backups
     filename encryption:                   standard
     directory name encryption:             true
     password:                              generate or choose one
     password2 (salt):                      generate one

     >>> WRITE BOTH PASSWORDS DOWN NOW, in your password manager. <<<
     They are the only way to read these backups, and they are not
     recoverable from the backups themselves.

  3. quit with:  q

EOF

read -r -p "Ready? Press enter to start rclone config, or Ctrl-C to cancel. " _

touch "$RCLONE_CONF"
chmod 600 "$RCLONE_CONF"

# Interactive, so -it. Port 53682 is rclone's OAuth callback listener; the
# browser redirects there after you approve, and without publishing it the
# "use auto config" flow cannot complete from inside a container.
docker run --rm -it \
  -v "$RCLONE_CONF:/config/rclone/rclone.conf" \
  -p 127.0.0.1:53682:53682 \
  "$RCLONE_IMAGE" config

echo ""
echo "=== verifying ==="
chmod 600 "$RCLONE_CONF"

rc() {
  docker run --rm -v "$RCLONE_CONF:/config/rclone/rclone.conf:ro" \
    "$RCLONE_IMAGE" "$@" </dev/null
}

if ! rc config show gdrive-crypt >/dev/null 2>&1; then
  echo "No remote named 'gdrive-crypt' was created." >&2
  echo "Re-run this script; sync_remote.sh needs a crypt remote." >&2
  exit 1
fi

TYPE="$(rc config show gdrive-crypt 2>/dev/null | grep -E '^type *=' | head -1 | sed 's/.*= *//' | tr -d '\r')"
if [ "$TYPE" != "crypt" ]; then
  echo "'gdrive-crypt' is type '$TYPE', not 'crypt'. Backups would be" >&2
  echo "uploaded in the clear -- sync_remote.sh will refuse to use it." >&2
  exit 1
fi
echo "  gdrive-crypt is a crypt remote"

if rc lsd gdrive-crypt: >/dev/null 2>&1; then
  echo "  remote reachable and authorised"
else
  echo "  WARNING: could not list the remote. Authorisation may be incomplete." >&2
fi

cat <<EOF

Setup complete. Config written to:
  $RCLONE_CONF   (chmod 600, gitignored)

NEXT, AND DO IT NOW:
  Copy that file's contents into your password manager, beside the Vault
  unseal keys. It is the only way to decrypt these backups and it cannot be
  recovered from them.

Then a first real sync:
  RCLONE_REMOTE=gdrive-crypt: platform/backup/sync_remote.sh
EOF

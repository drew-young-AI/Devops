#!/usr/bin/env bash
# Copy verified backups to a second location, and prove it is a second one.
#
# THE CHECK THAT MAKES THIS REAL.
#
# Backups and their source currently live on one disk. That disk failing
# loses both, which means the whole backup mechanism -- integrity manifests,
# restore drill, ten passing assertions -- protects against nothing that
# actually threatens it. The gap is not "we should also copy somewhere else",
# it is that copying to another folder on the same disk would LOOK like
# fixing it.
#
# So this refuses to run unless the destination is on a different device.
# `stat -f %d` gives the device id on macOS; if it matches the source's, the
# copy is declined with an explanation rather than performed as theatre.
#
# NO DEFAULT DESTINATION, ON PURPOSE.
#
# The Vault archive is encrypted at rest, but these are still complete copies
# of platform state, and pushing them to iCloud, a NAS or object storage
# sends them somewhere the user has to have chosen deliberately. Same
# reasoning as the notification sink: convenience is not consent. Set
# BACKUP_OFFSITE_DEST, or nothing happens.
#
# Usage:
#   BACKUP_OFFSITE_DEST=/Volumes/Backup/devops platform/backup/sync_offsite.sh
#   ... --prune-local N     keep only the N newest local archive sets,
#                           and ONLY after their copies verify at the far end
#
# Exit 0 on a verified sync, non-zero on anything unproven.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCAL_DIR="$SCRIPT_DIR/archives"

PRUNE_KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prune-local) PRUNE_KEEP="${2:?--prune-local needs a count}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

DEST="${BACKUP_OFFSITE_DEST:-}"
if [ -z "$DEST" ]; then
  cat >&2 <<'EOF'
BACKUP_OFFSITE_DEST is not set, so nothing was copied.

This is deliberate, not a missing default. These archives are complete
copies of platform state; where they are sent is a decision with real
consequences and it belongs to you, not to a convenient default.

Candidates, with the trade-off each carries:

  external drive   /Volumes/<name>/devops-backups
                   Different physical device, nothing leaves the machine.
                   Only protects you while it is actually plugged in.

  NAS / another host
                   Different device and different location. Needs the mount
                   to be reliable, or a sync that tolerates it being absent.

  iCloud Drive     ~/Library/Mobile Documents/com~apple~CloudDocs/...
                   Survives losing the machine entirely -- and sends platform
                   state, including the encrypted Vault archive, to a third
                   party. Note the archive is useless without the unseal keys
                   in .init-output.json, which are NOT in it, so this is less
                   alarming than it first sounds. Still your call.

  object storage   Needs credentials, which means a Vault path and an egress
                   decision of its own.
EOF
  exit 1
fi

if [ ! -d "$LOCAL_DIR" ]; then
  echo "No local archives at $LOCAL_DIR. Run platform/backup/backup.sh first." >&2
  exit 1
fi

mkdir -p "$DEST" 2>/dev/null || true
if [ ! -d "$DEST" ]; then
  echo "Destination $DEST does not exist and could not be created." >&2
  echo "If it is a removable drive or a network mount, it may not be attached." >&2
  exit 1
fi

# GNU form first, BSD as the fallback. `stat -f %d` is macOS; on GNU coreutils
# `-f` means "filesystem status" and SUCCEEDS with unrelated output, so on Linux
# both variables would be non-empty and neither would be a device id -- the
# same-disk guard below would then be comparing two filesystem descriptions.
# This matters now rather than theoretically: the production node is Linux.
SRC_DEV="$(stat -c %d "$LOCAL_DIR" 2>/dev/null || stat -f %d "$LOCAL_DIR" 2>/dev/null)"
DST_DEV="$(stat -c %d "$DEST" 2>/dev/null || stat -f %d "$DEST" 2>/dev/null)"

echo "=== [offsite] $LOCAL_DIR -> $DEST ==="
if [ -z "$SRC_DEV" ] || [ -z "$DST_DEV" ]; then
  echo "REFUSED: could not determine the device for one of the paths." >&2
  exit 1
fi
if [ "$SRC_DEV" = "$DST_DEV" ]; then
  echo "REFUSED: destination is on the SAME device as the source (dev $SRC_DEV)." >&2
  echo "" >&2
  echo "Copying to another folder on the same disk does not survive that disk" >&2
  echo "failing, which is the only scenario this exists for. It would, however," >&2
  echo "look exactly like a working offsite backup -- which is worse than not" >&2
  echo "having one, because nobody would keep looking for the real fix." >&2
  exit 1
fi
echo "  source device $SRC_DEV, destination device $DST_DEV -- genuinely separate"

copied=0
verified=0
failed=0

for set_dir in $(find "$LOCAL_DIR" -maxdepth 1 -mindepth 1 -type d | sort); do
  stamp="$(basename "$set_dir")"
  manifest="$set_dir/manifest.json"
  [ -f "$manifest" ] || continue

  target="$DEST/$stamp"
  if [ -d "$target" ] && [ -f "$target/manifest.json" ]; then
    continue   # already synced; verified below on the pass that copied it
  fi

  mkdir -p "$target"
  cp -p "$set_dir"/* "$target"/ 2>/dev/null
  copied=$((copied + 1))

  # Re-hash AT THE DESTINATION against the manifest recorded at backup time.
  # Trusting cp is the same mistake as trusting a backup you never restored:
  # a copy that silently truncated still leaves a plausible-looking directory.
  bad="$(python3 - "$manifest" "$target" <<'PY'
import hashlib, json, os, sys
manifest, target = sys.argv[1:]
data = json.load(open(manifest))
problems = []
for entry in data.get("volumes", []):
    path = os.path.join(target, entry["archive"])
    if not os.path.isfile(path):
        problems.append(f"{entry['archive']}: missing at destination")
        continue
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    if h.hexdigest() != entry["sha256"]:
        problems.append(f"{entry['archive']}: digest mismatch after copy")
print("; ".join(problems))
PY
)"
  if [ -z "$bad" ]; then
    verified=$((verified + 1))
    echo "  synced+verified $stamp"
  else
    failed=$((failed + 1))
    echo "  FAILED $stamp: $bad" >&2
    # A corrupt copy must not be left looking like a good one.
    rm -rf "$target"
  fi
done

TOTAL_REMOTE="$(find "$DEST" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
echo "  copied $copied, verified $verified, failed $failed, total at destination $TOTAL_REMOTE"

if [ "$PRUNE_KEEP" -gt 0 ]; then
  echo ""
  echo "=== [offsite] pruning local, keeping $PRUNE_KEEP newest ==="
  # Only ever prune a set that has a verified copy at the destination. Local
  # archives grow ~22MB/day, so pruning is necessary -- but deleting the only
  # copy of something because the far end "should" have it is how backups
  # become fiction.
  pruned=0
  # NOT `head -n -N`. That negative form is a GNU extension; BSD head on
  # macOS rejects it, the command substitution came back empty, and the loop
  # silently did nothing while reporting "pruned 0". It failed safe this
  # time -- but a prune that never prunes is a disk that fills anyway, and
  # nothing said so.
  TOTAL_LOCAL="$(find "$LOCAL_DIR" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
  DROP_COUNT=$((TOTAL_LOCAL - PRUNE_KEEP))
  [ "$DROP_COUNT" -lt 1 ] && DROP_COUNT=0
  for set_dir in $(find "$LOCAL_DIR" -maxdepth 1 -mindepth 1 -type d | sort | head -"$DROP_COUNT"); do
    [ "$DROP_COUNT" -eq 0 ] && break
    stamp="$(basename "$set_dir")"
    if [ -f "$DEST/$stamp/manifest.json" ]; then
      rm -rf "$set_dir"
      pruned=$((pruned + 1))
      echo "  pruned $stamp (verified copy exists at destination)"
    else
      echo "  KEPT $stamp -- no verified copy at destination" >&2
    fi
  done
  echo "  pruned $pruned local set(s)"
fi

[ "$failed" -eq 0 ]

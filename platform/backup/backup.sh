#!/usr/bin/env bash
# Backup mechanism for stateful platform volumes.
#
# What gets backed up, and what deliberately does not:
#
#   vault_vault-file            YES  irreplaceable -- every secret
#   vault_vault-logs            YES  the audit trail; unreconstructable
#   observability_grafana-data  YES  users, orgs, API keys, annotations
#   observability_alertmanager-data YES silences (losing them re-floods alerts)
#   observability_prometheus-data NO  24h retention, regenerable by scraping
#   observability_loki-data     NO   24h retention; see note below
#
# Prometheus and Loki are excluded on purpose rather than by omission: both
# hold at most 24h of regenerable telemetry, and backing them up would
# multiply backup size by an order of magnitude for data that is worthless
# 24 hours later. If retention is ever extended for compliance reasons, that
# decision must revisit this list -- noted in README.md.
#
# THE CRITICAL PROPERTY, stated because it is easy to get wrong:
# Vault's file storage is encrypted at rest. This backup is therefore safe
# to hold, but it is ALSO USELESS ON ITS OWN -- restoring it requires the
# unseal keys from platform/vault/.init-output.json, which this script
# deliberately does NOT include. Backing up data and backing up the ability
# to read it are two different things, and putting both in one archive would
# turn a safe backup into a single file that hands over every secret.
#
# Usage:
#   backup.sh [dest_dir]        # default: platform/backup/archives/
#
# Verify a backup is restorable: platform/backup/restore_drill.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEST="${1:-$SCRIPT_DIR/archives}"

VOLUMES=(
  vault_vault-file
  # The audit trail. Added when the audit device was enabled: an access log
  # that cannot survive a disk failure is not an audit capability, and it is
  # the one record here that cannot be reconstructed from anything else --
  # git can be re-cloned, evidence re-generated, but nobody can re-derive
  # who read a secret last Tuesday.
  vault_vault-logs
  observability_grafana-data
  observability_alertmanager-data
  # Alloy's log read positions. Small, and easy to dismiss as regenerable --
  # but losing them does not fail, it makes Alloy either re-read files from
  # the start (duplicate log lines) or resume at the tail (a silent hole in
  # the record). After a restore, a gap in logs looks exactly like a period
  # when nothing happened. Surfaced by the coverage check below, not by
  # anybody remembering it existed.
  observability_alloy-data
)

# Volumes that must NOT be tarred while their service is running.
#
#   container|database|user|volume
#
# Tarring a live PostgreSQL data directory is not a backup. The files are
# mutating while tar walks them, so the archive is a mix of pages from
# different instants -- torn in a way that produces no error at backup time
# and may fail, or silently restore a corrupt database, months later when it
# is finally needed. Postgres has a supported answer (`pg_dump`), so it gets
# used instead of hoping the tar lands between writes.
#
# When the container is NOT running, tar is correct and is what happens:
# nothing is writing, so the on-disk state is consistent by definition.
PG_SERVICES=(
  "station2-twin-db-1|twin|twin|station2-twin-db"
)

# Named volumes that are deliberately not backed up. Listed explicitly so the
# coverage check below can tell "decided against" apart from "never noticed".
declare -a EXCLUDED_VOLUMES=(
  observability_prometheus-data
  observability_loki-data
  # Not this platform's. Belongs to another project on the same host; backing
  # up someone else's database without being asked would be both a surprise
  # and a data-handling decision that is not ours to make. Listed rather than
  # ignored so the next person sees it was considered.
  mongo
  # k3d practice cluster's container image cache. Disposable by construction:
  # the whole cluster is `k3d cluster delete` away from gone and rebuilt from
  # a script, and the cache re-populates from registries on demand. Anything
  # in that cluster worth keeping is a defect in where it was put.
  k3d-devops-lab-images
)

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
OUT_DIR="$DEST/$STAMP"
mkdir -p "$OUT_DIR"

echo "=== [backup] $STAMP -> $OUT_DIR ==="

manifest_entries=()
UNCOVERED=()

for volume in "${VOLUMES[@]}"; do
  if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    echo "  SKIP $volume (does not exist)" >&2
    continue
  fi

  archive="$OUT_DIR/${volume}.tar.gz"

  # Read-only mount of the source volume: a backup process must not be able
  # to modify what it is backing up.
  docker run --rm \
    -v "${volume}:/src:ro" \
    -v "$OUT_DIR:/out" \
    alpine:3.20 \
    tar czf "/out/${volume}.tar.gz" -C /src . 2>/dev/null

  size="$(wc -c < "$archive" | tr -d ' ')"
  digest="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
  echo "  $volume -> $(basename "$archive")  ${size} bytes"
  manifest_entries+=("$volume|$(basename "$archive")|$size|$digest")
done

# --- PostgreSQL: logical dump while running, tar while stopped -----------

for spec in "${PG_SERVICES[@]}"; do
  IFS='|' read -r container db user volume <<< "$spec"
  docker volume inspect "$volume" >/dev/null 2>&1 || { echo "  SKIP $volume (does not exist)" >&2; continue; }

  RUNNING="$(docker ps --format '{{.Names}}' 2>/dev/null)"
  case "$RUNNING" in
    *"$container"*)
      archive="$OUT_DIR/${volume}.dump"
      # -Fc: custom format. Compressed, and restorable selectively with
      # pg_restore rather than being a plain SQL stream that can only be
      # replayed whole.
      if docker exec "$container" pg_dump -U "$user" -d "$db" -Fc > "$archive" 2>/dev/null; then
        size="$(wc -c < "$archive" | tr -d ' ')"
        digest="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
        echo "  $volume -> $(basename "$archive")  ${size} bytes  [pg_dump, consistent snapshot]"
        manifest_entries+=("$volume|$(basename "$archive")|$size|$digest")
      else
        echo "  FAILED $volume: pg_dump did not succeed" >&2
        rm -f "$archive"
        UNCOVERED+=("$volume (pg_dump failed)")
      fi
      ;;
    *)
      # Stopped: the data directory is quiescent, so a tar IS consistent.
      archive="$OUT_DIR/${volume}.tar.gz"
      docker run --rm -v "${volume}:/src:ro" -v "$OUT_DIR:/out" alpine:3.20 \
        tar czf "/out/${volume}.tar.gz" -C /src . 2>/dev/null
      size="$(wc -c < "$archive" | tr -d ' ')"
      digest="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
      echo "  $volume -> $(basename "$archive")  ${size} bytes  [tar, container stopped]"
      manifest_entries+=("$volume|$(basename "$archive")|$size|$digest")
      ;;
  esac
done

# The manifest is what makes a restore verifiable rather than hopeful: the
# digest recorded at backup time is compared at restore time, so silent
# corruption between the two is detected instead of being restored.
python3 - "$OUT_DIR/manifest.json" "$STAMP" "${manifest_entries[@]}" <<'PY'
import json, pathlib, sys
out, stamp, *entries = sys.argv[1:]
volumes = []
for entry in entries:
    name, archive, size, digest = entry.split("|")
    volumes.append({
        "volume": name,
        "archive": archive,
        "size_bytes": int(size),
        "sha256": digest,
    })
pathlib.Path(out).write_text(json.dumps({
    "created_at": stamp,
    "volumes": volumes,
    "excluded": {
        "observability_prometheus-data": "24h retention, regenerable by scraping",
        "observability_loki-data": "24h retention, regenerable telemetry",
    },
    "restore_requires": (
        "platform/vault/.init-output.json (unseal keys). Vault file storage "
        "is encrypted at rest; this archive cannot be opened without them, "
        "and they are deliberately not included here."
    ),
}, indent=2) + "\n")
PY

# --- coverage: is anything stateful NOT accounted for? -------------------
#
# The volume list is hand-maintained, which means a new stateful service is
# protected only if somebody remembered to add it here. Nothing announced the
# omission -- the backup kept passing, and its manifest kept looking complete,
# because a list cannot report what is not in it.
#
# Found exactly that way: station2-twin brought the platform's first real
# database and its volume was covered by nothing. The backup did not fail; it
# succeeded at backing up the wrong set.
#
# So every named volume on this host must be in exactly one of three places:
# backed up, listed as PG (dumped), or explicitly excluded. Anything else is
# an unreviewed gap and makes this run non-zero.
ALL_VOLUMES="$(docker volume ls --format '{{.Name}}' 2>/dev/null)"
for vol in $ALL_VOLUMES; do
  covered=0
  for v in "${VOLUMES[@]}"        ; do [ "$v" = "$vol" ] && covered=1; done
  for v in "${EXCLUDED_VOLUMES[@]}"; do [ "$v" = "$vol" ] && covered=1; done
  for spec in "${PG_SERVICES[@]}" ; do [ "${spec##*|}" = "$vol" ] && covered=1; done
  # Anonymous volumes are docker's own scratch (64-hex names), not state
  # anybody chose to keep.
  case "$vol" in [0-9a-f]*) [ "${#vol}" -ge 64 ] && covered=1 ;; esac
  [ "$covered" -eq 0 ] && UNCOVERED+=("$vol")
done

echo ""
if [ "${#UNCOVERED[@]}" -gt 0 ]; then
  echo "BACKUP INCOMPLETE -- ${#UNCOVERED[@]} volume(s) are covered by nothing:" >&2
  for v in "${UNCOVERED[@]}"; do echo "    $v" >&2; done
  echo "" >&2
  echo "The archives that WERE taken are valid and written to:" >&2
  echo "  $OUT_DIR" >&2
  echo "" >&2
  echo "But this run cannot claim the platform is backed up. Add each volume" >&2
  echo "to VOLUMES, to PG_SERVICES, or to EXCLUDED_VOLUMES with a reason, in" >&2
  echo "platform/backup/backup.sh." >&2
  exit 1
fi

echo "BACKUP PASS -- every named volume on this host is accounted for"
echo "artifact=$OUT_DIR/manifest.json"
echo ""
echo "A backup that has never been restored is not a backup."
echo "Verify it: platform/backup/restore_drill.sh $OUT_DIR"

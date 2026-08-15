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
)

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
OUT_DIR="$DEST/$STAMP"
mkdir -p "$OUT_DIR"

echo "=== [backup] $STAMP -> $OUT_DIR ==="

manifest_entries=()

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

echo ""
echo "BACKUP PASS"
echo "artifact=$OUT_DIR/manifest.json"
echo ""
echo "A backup that has never been restored is not a backup."
echo "Verify it: platform/backup/restore_drill.sh $OUT_DIR"

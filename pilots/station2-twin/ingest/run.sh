#!/usr/bin/env bash
# Run an ingestion script in its pinned runtime.
#
#   ./run.sh load_geography.py
#   ./run.sh load_dimensional.py --sources rods,nhi
#   ./run.sh load_dimensional.py --dry-run
#
# The database credential comes from the environment, never from an argument:
# arguments are visible in `ps` to every user on the machine.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${INGEST_IMAGE:-station2-ingest:local}"

[ $# -ge 1 ] || { echo "Usage: $0 <script.py> [args...]" >&2; exit 2; }

# Build only when the Dockerfile is newer than the image, so a normal run does
# not pay for a build it does not need.
needs_build=1
if img_created="$(docker image inspect "$IMAGE" --format '{{.Created}}' 2>/dev/null)"; then
  img_epoch="$(date -j -f '%Y-%m-%dT%H:%M:%S' "${img_created%.*}" +%s 2>/dev/null || echo 0)"
  dockerfile_epoch="$(stat -f %m "$HERE/Dockerfile")"
  [ "$img_epoch" -gt "$dockerfile_epoch" ] && needs_build=0
fi
if [ "$needs_build" -eq 1 ]; then
  echo "=== building $IMAGE ===" >&2
  docker build -q -t "$IMAGE" "$HERE" >&2
fi

# --network host: the loaders reach postgres on 127.0.0.1:15432 (the port the
# pilot publishes) and the CDC over the internet. Read-only mount of the source
# tree except reference/, which --refresh writes a new snapshot into.
exec docker run --rm -i \
  --network host \
  -e PGHOST="${PGHOST:-127.0.0.1}" \
  -e PGPORT="${PGPORT:-15432}" \
  -e PGDATABASE="${PGDATABASE:-twin}" \
  -e PGUSER="${PGUSER:-twin}" \
  -e PGPASSWORD="${PGPASSWORD:-}" \
  -e DATABASE_URL="${DATABASE_URL:-}" \
  -v "$HERE:/ingest" \
  -w /ingest \
  "$IMAGE" "$@"

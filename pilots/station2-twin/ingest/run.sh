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
#
# -u because docker reports .Created in UTC. Without it `date -j` reads that
# string as LOCAL time, making the image look 8h older than it is here (UTC+8),
# so this test never skipped and EVERY run rebuilt -- which quietly made each
# run depend on Docker Hub being reachable. Found 2026-09-03 when Docker Hub
# was not, and the ingest could not start despite the image being on disk.
needs_build=1
if img_created="$(docker image inspect "$IMAGE" --format '{{.Created}}' 2>/dev/null)"; then
  # GNU form FIRST, BSD as the fallback -- the same shape run_job.sh and
  # sync_offsite.sh use, and the order test_static.sh enforces.
  #
  # WHY THIS MATTERS MORE THAN IT LOOKS (2026-09-09). `stat -f %m` is BSD; on
  # GNU coreutils `-f` means "file SYSTEM status" and `%m` is not a format, so
  # it exits non-zero -- and under `set -euo pipefail` that aborts run.sh
  # before the container ever starts. Every assertion about what the container
  # PRINTS then fails for a reason that has nothing to do with the container.
  # Platform Tests was red on Linux for four consecutive pushes on exactly
  # this, while the same suite was green on the development machine.
  img_epoch="$(date -u -d "${img_created%.*}Z" +%s 2>/dev/null \
               || date -j -u -f '%Y-%m-%dT%H:%M:%S' "${img_created%.*}" +%s 2>/dev/null \
               || echo 0)"
  # Both dialects on ONE line: test_static.sh checks that the GNU form appears
  # earlier on the same line, and a backslash continuation hides it from that.
  dockerfile_epoch="$(stat -c %Y "$HERE/Dockerfile" 2>/dev/null || stat -f %m "$HERE/Dockerfile" 2>/dev/null || echo 0)"
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

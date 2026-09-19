#!/usr/bin/env bash
# Run an MLOps script in its pinned runtime.
#
#   ./run.sh build_features.py
#   ./run.sh backtest.py --horizon 1
#
# NO --network host, unlike ingest/run.sh. This stage must not reach the
# internet: a feature builder that can fetch is a feature builder that can
# quietly depend on something outside the recorded lineage. It gets the
# database and nothing else.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${MLOPS_IMAGE:-station2-mlops:local}"

# The model-registry CONTRACT is platform-level and shared; the model ENTRIES
# are this pilot's. One copy, mounted read-only, rather than a copy per pilot:
# the two live forks this repo has already found (the settle rule, and the
# publisher's own estimator) both started as a second copy that was correct on
# the day it was made.
SHARED_MLOPS="$(cd "$HERE/../../.." && pwd)/platform/mlops"
[ -f "$SHARED_MLOPS/model_registry.py" ] || {
  echo "missing $SHARED_MLOPS/model_registry.py -- the registry contract is" >&2
  echo "not optional; refusing to run with an unvalidated registry." >&2
  exit 2
}

[ $# -ge 1 ] || { echo "Usage: $0 <script.py> [args...]" >&2; exit 2; }

# Build only when the Dockerfile is newer than the image.
#
# -u because docker reports .Created in UTC. Without it `date -j` reads that
# string as LOCAL time, making the image look 8h older than it is here (UTC+8),
# so this test never skipped and EVERY run rebuilt -- which quietly made the
# weekly retrain depend on Docker Hub being reachable. Found 2026-09-03 when
# Docker Hub was not, and no pilot job could start despite the images on disk.
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

# The pilot publishes postgres on loopback; the container reaches it via the
# host gateway rather than being put on the host network.
exec docker run --rm -i \
  --add-host=host.docker.internal:host-gateway \
  -e PGHOST="${PGHOST:-host.docker.internal}" \
  -e PGPORT="${PGPORT:-15432}" \
  -e PGDATABASE="${PGDATABASE:-twin}" \
  -e PGUSER="${PGUSER:-twin}" \
  -e PGPASSWORD="${PGPASSWORD:-}" \
  -v "$HERE:/mlops" \
  -v "$SHARED_MLOPS:/platform/mlops:ro" \
  -e PYTHONPATH=/platform/mlops \
  -w /mlops \
  "$IMAGE" "$@"

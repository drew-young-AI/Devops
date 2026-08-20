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

[ $# -ge 1 ] || { echo "Usage: $0 <script.py> [args...]" >&2; exit 2; }

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
  -w /mlops \
  "$IMAGE" "$@"

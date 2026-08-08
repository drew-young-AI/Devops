#!/usr/bin/env bash
set -euo pipefail

PILOT_DIR="${1:-$(cd "$(dirname "$0")/../../pilots/station1-hello" && pwd)}"
PLATFORM_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ARTIFACT_DIR="${2:-$PLATFORM_ROOT/evidence/station2}"
IMAGE_NAME="${IMAGE_NAME:-station1-hello:ci}"

mkdir -p "$ARTIFACT_DIR"

echo "[1/4] lint / compile"
python3 -m py_compile "$PILOT_DIR/app.py"

echo "[2/4] unit / contract test"
python3 -m unittest discover -s "$PILOT_DIR/tests" -p 'test_*.py' -v

echo "[3/4] container build"
docker build --tag "$IMAGE_NAME" "$PILOT_DIR"

echo "[4/4] artifact metadata"
IMAGE_DIGEST="$(docker image inspect "$IMAGE_NAME" --format '{{index .RepoDigests 0}}' 2>/dev/null || true)"
IMAGE_ID="$(docker image inspect "$IMAGE_NAME" --format '{{.Id}}')"
COMMIT_SHA="$(git -C "$PILOT_DIR" rev-parse HEAD 2>/dev/null || printf 'local-uncommitted')"
BUILD_TIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

python3 - "$ARTIFACT_DIR/metadata.json" "$COMMIT_SHA" "$IMAGE_NAME" "$IMAGE_ID" "$IMAGE_DIGEST" "$BUILD_TIME" "$PILOT_DIR" <<'PY'
import json
import pathlib
import sys

output, commit, image, image_id, digest, build_time, source_path = sys.argv[1:]
pathlib.Path(output).write_text(json.dumps({
    "commit_sha": commit,
    "image": image,
    "image_id": image_id,
    "image_digest": digest or None,
    "build_timestamp": build_time,
    "source_path": source_path,
}, indent=2) + "\n")
PY

echo "CI PASS"
echo "artifact=$ARTIFACT_DIR/metadata.json"

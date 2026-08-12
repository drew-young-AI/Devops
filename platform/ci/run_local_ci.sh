#!/usr/bin/env bash
set -euo pipefail

PILOT_DIR="${1:-$(cd "$(dirname "$0")/../../pilots/station1-hello" && pwd)}"
PLATFORM_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ARTIFACT_DIR="${2:-$PLATFORM_ROOT/evidence/station1-hello}"
IMAGE_NAME="${IMAGE_NAME:-station1-hello:ci}"

mkdir -p "$ARTIFACT_DIR"

echo "[1/5] lint / compile"
python3 -m py_compile "$PILOT_DIR/app.py"

echo "[2/5] unit / contract test"
python3 -m unittest discover -s "$PILOT_DIR/tests" -p 'test_*.py' -v

echo "[3/5] container build"
docker build --tag "$IMAGE_NAME" "$PILOT_DIR"

echo "[4/5] graceful shutdown smoke test"
# NEW_SERVICE_GUIDE.md section 5 explicitly requires a "graceful shutdown
# test" for every service -- this was previously only verified manually,
# once, ad hoc. Making it a permanent CI step closes that gap for real
# instead of relying on nobody re-breaking it unnoticed.
SMOKE_CONTAINER="ci-smoke-$$"
docker run -d --rm --name "$SMOKE_CONTAINER" -p 127.0.0.1::8080 "$IMAGE_NAME" >/dev/null
cleanup_smoke() { docker rm -f "$SMOKE_CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup_smoke EXIT

SMOKE_PORT="$(docker port "$SMOKE_CONTAINER" 8080/tcp | head -1 | cut -d: -f2)"
for _ in $(seq 1 20); do
  curl -sf "http://127.0.0.1:${SMOKE_PORT}/health/ready" >/dev/null 2>&1 && break
  sleep 0.25
done

python3 - "$SMOKE_CONTAINER" "$SMOKE_PORT" <<'PY'
import subprocess, sys, threading, time, urllib.request, urllib.error

container, port = sys.argv[1], sys.argv[2]
url = f"http://127.0.0.1:{port}/health/ready"

def kill_it():
    time.sleep(0.1)
    subprocess.run(["docker", "kill", "-s", "SIGTERM", container], capture_output=True)

threading.Thread(target=kill_it).start()

saw_draining = False
saw_ready_after_drain_started = False
for _ in range(100):
    try:
        with urllib.request.urlopen(url, timeout=0.3) as r:
            if r.status == 200 and saw_draining:
                saw_ready_after_drain_started = True
    except urllib.error.HTTPError as e:
        if e.code == 503:
            saw_draining = True
    except Exception:
        break
    time.sleep(0.05)

if not saw_draining:
    print("FAIL: never observed 503 (draining) during shutdown -- "
          "graceful drain window is not working", file=sys.stderr)
    sys.exit(1)
if saw_ready_after_drain_started:
    print("FAIL: observed 200 (ready) AFTER a 503 was already seen -- "
          "shutdown flag is not sticky", file=sys.stderr)
    sys.exit(1)
print("PASS: observed 503 (draining) before the connection closed")
PY

trap - EXIT
cleanup_smoke

echo "[5/5] artifact metadata"
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

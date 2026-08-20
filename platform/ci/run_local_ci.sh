#!/usr/bin/env bash
set -euo pipefail

# Defaults derive from the pilot directory rather than naming one pilot three
# times. The previous version hardcoded station1-hello into the default path,
# the evidence path and the image tag, so pointing CI at a different pilot
# quietly wrote its artefacts into the wrong pilot's evidence directory.
PILOT_DIR="${1:-$(cd "$(dirname "$0")/../../pilots/station2-twin" && pwd)}"
PLATFORM_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PILOT_NAME="$(basename "$PILOT_DIR")"
ARTIFACT_DIR="${2:-$PLATFORM_ROOT/evidence/$PILOT_NAME}"
IMAGE_NAME="${IMAGE_NAME:-$PILOT_NAME:ci}"

mkdir -p "$ARTIFACT_DIR"

echo "[1/6] lint / compile"
# Pilots differ in layout: a single-file service keeps app.py at the root, a
# larger one puts a package under app/. Compile whatever is there, and fail if
# there is nothing -- "no sources found" must not pass as "nothing broken".
#
# ingest/ USED TO BE EXCLUDED HERE. That exclusion meant roughly two thousand
# lines of loader -- every feed declaration, every crosswalk, the whole DataOps
# layer -- was never compiled, never linted and never tested by CI. The platform
# had a build pipeline and a data pipeline with nothing joining them, so a
# broken feed declaration could only be found by running a forty-minute load and
# reading the output.
#
# The exclusion was not even necessary: py_compile parses, it does not import,
# so `import psycopg` in a loader has never been a reason to skip it. Verified
# on this host's python 3.9, which has no psycopg -- all four loaders compile.
PY_SOURCES=()
while IFS= read -r f; do PY_SOURCES+=("$f"); done < <(
  find "$PILOT_DIR" -name '*.py' -not -path '*/tests/*' -not -path '*/__pycache__/*' \
    | sort)
[ "${#PY_SOURCES[@]}" -gt 0 ] || { echo "No Python sources under $PILOT_DIR" >&2; exit 1; }
python3 -m py_compile "${PY_SOURCES[@]}"
echo "  compiled ${#PY_SOURCES[@]} file(s)"

echo "[2/6] SAST (source security scan)"
# Runs on the PILOT SOURCE, before the image is built. Every other security
# gate in this pipeline inspects an artifact (Trivy on the image, SBOM,
# Cosign) or history (Gitleaks) -- none of them reads the application source,
# so an injection flaw written today passes all of them: the image has no
# CVEs and no secret was committed. This is the gate that would catch it.
if ! "$PLATFORM_ROOT/platform/security/scan_sast.sh" "$PILOT_DIR" "$ARTIFACT_DIR"; then
  echo "CI FAILED: SAST gate" >&2
  exit 1
fi

echo "[3/6] unit / contract test"
python3 -m unittest discover -s "$PILOT_DIR/tests" -p 'test_*.py' -v

echo "[4/6] container build"
docker build --tag "$IMAGE_NAME" "$PILOT_DIR"

echo "[5/6] graceful shutdown smoke test"
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
import json, subprocess, sys, threading, time, urllib.request, urllib.error

# THIS TEST WAS BROKEN IN TWO WAYS, BOTH OF WHICH IT REPORTED AS THE SAME LIE.
#
# It asserted on the bare 503 status code with a 0.3s client timeout.
#
#  1. FALSE FAILURE. The smoke container runs with no database, so
#     /health/ready blocks on the connection pool and answers 503 after 3.005s,
#     measured. Every request exceeded the 0.3s timeout, the loop broke on its
#     first iteration, and the test printed "graceful drain window is not
#     working". The drain window was fine. Same family as Vault reporting a
#     sealed server as an expired secret_id: real failure, fictional cause.
#
#  2. FALSE PASS, which is worse. Without a database, readiness is 503
#     `db_unreachable` from the moment the process starts -- BEFORE any signal
#     is sent. A 503 therefore proved nothing about draining. Given a longer
#     timeout, the old test would have passed on a service whose drain logic was
#     deleted entirely.
#
# The fix is to assert on the REASON, not the code. app.py answers
# {"status": "draining"} when the shutdown flag is set and
# {"status": "db_unreachable"} when it is not, so the two 503s are already
# distinguishable -- the test simply was not looking. And the absence of
# "draining" BEFORE the signal is now asserted too, because a test that cannot
# fail before the event it is timing is not measuring that event.

container, port = sys.argv[1], sys.argv[2]
url = f"http://127.0.0.1:{port}/health/ready"
# Must exceed the app's own readiness timeout (PoolTimeout, ~3s with no
# database) or every probe times out and the failure is attributed to drain.
PROBE_TIMEOUT = 8.0


def probe():
    """Return the reported status string, or None if the socket is gone."""
    try:
        with urllib.request.urlopen(url, timeout=PROBE_TIMEOUT) as r:
            return json.loads(r.read()).get("status", "ready")
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read()).get("status", f"http-{e.code}")
        except Exception:
            return f"http-{e.code}"
    except Exception:
        return None


before = probe()
if before is None:
    print("FAIL: /health/ready did not answer at all before SIGTERM. This image "
          "either exposes no HTTP readiness endpoint or did not finish starting "
          "-- it is NOT a drain problem.", file=sys.stderr)
    sys.exit(1)
if before == "draining":
    print(f"FAIL: already reporting 'draining' BEFORE any signal was sent. The "
          f"shutdown flag is set at startup, so the drain signal means nothing.",
          file=sys.stderr)
    sys.exit(1)
print(f"  pre-signal status: {before}")

subprocess.run(["docker", "kill", "-s", "SIGTERM", container], capture_output=True)

saw_draining = False
regressed = False
deadline = time.monotonic() + 15
while time.monotonic() < deadline:
    status = probe()
    if status is None:
        break                      # socket closed: drain finished
    if status == "draining":
        saw_draining = True
    elif saw_draining:
        regressed = True           # went back to something else after draining
    time.sleep(0.05)

if not saw_draining:
    print(f"FAIL: never reported status 'draining' after SIGTERM (last seen: "
          f"{before}). The shutdown handler did not set the flag, or the "
          f"process exited before serving one request.", file=sys.stderr)
    sys.exit(1)
if regressed:
    print("FAIL: reported 'draining' and then stopped -- the shutdown flag is "
          "not sticky, so a load balancer could route traffic back.",
          file=sys.stderr)
    sys.exit(1)
print("PASS: reported 'draining' only after SIGTERM, and stayed draining")
PY

trap - EXIT
cleanup_smoke

echo "[6/6] artifact metadata"
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

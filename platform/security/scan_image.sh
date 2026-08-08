#!/usr/bin/env bash
# Container image vulnerability scan gate (Trivy).
#
# Policy: hard-fail only on FIXABLE Critical/High findings (--ignore-unfixed
# --severity CRITICAL,HIGH --exit-code 1). Verified reasoning, not a
# guess: station1-hello:dev's current base image (python:3.12-slim) has
# 4 CRITICAL findings today, all in perl-base, all with "no fix available"
# upstream -- hard-failing on those would create a permanent, unfixable
# block for no actionable reason. --ignore-unfixed drops them to 0
# CRITICAL/HIGH, leaving a gate that's both meaningful (verified: a
# deliberately older image, python:3.9-slim, trips it with 28 fixable
# Critical/High findings) and achievable today.
#
# A second, non-blocking full scan (all severities, including unfixed) is
# also recorded for complete visibility -- informational only, exit code
# ignored.
#
# Usage:
#   scan_image.sh <image:tag> <evidence_dir>
#
# Exit code: 0 if no fixable Critical/High findings, 1 otherwise (or if
# trivy itself errors).

set -euo pipefail

IMAGE="${1:?Usage: scan_image.sh <image:tag> <evidence_dir>}"
EVIDENCE_DIR="${2:?Usage: scan_image.sh <image:tag> <evidence_dir>}"

if ! command -v trivy >/dev/null 2>&1; then
  echo "trivy not found. Install with: brew install trivy" >&2
  exit 1
fi

mkdir -p "$EVIDENCE_DIR"
SAFE_IMAGE="$(echo "$IMAGE" | tr '/:' '__')"
# Raw trivy output for both scans: hundreds of KB (full CVE descriptions,
# references, etc. per finding) and fully regenerable from the image at any
# time -- gitignored, same reasoning as *.tfstate and the generated NGINX
# vhost. Only the small summary below (severity counts, pass/fail) is
# meant to be committed as the actual evidence-of-record, matching every
# other evidence/ file in this repo.
GATE_FILE="$EVIDENCE_DIR/_raw.trivy_gate_${SAFE_IMAGE}.json"
FULL_FILE="$EVIDENCE_DIR/_raw.trivy_full_${SAFE_IMAGE}.json"
SUMMARY_FILE="$EVIDENCE_DIR/trivy_summary_${SAFE_IMAGE}.json"

echo "=== [security scan] $IMAGE ==="

echo "[1/2] Full scan (all severities, informational, evidence only)..."
trivy image "$IMAGE" --scanners vuln --format json --output "$FULL_FILE" || true

echo "[2/2] Gate: fixable CRITICAL/HIGH only..."
set +e
trivy image "$IMAGE" --scanners vuln --ignore-unfixed --severity CRITICAL,HIGH \
  --format json --output "$GATE_FILE" --exit-code 1
gate_exit=$?
set -e

python3 - "$IMAGE" "$GATE_FILE" "$FULL_FILE" "$SUMMARY_FILE" "$gate_exit" <<'PY'
import json, sys, datetime

image, gate_file, full_file, summary_file, gate_exit = sys.argv[1:]
gate_exit = int(gate_exit)

def load(path):
    try:
        return json.load(open(path))
    except Exception:
        return {}

gate_vulns = []
for r in load(gate_file).get("Results", []):
    gate_vulns.extend(r.get("Vulnerabilities", []) or [])

full_by_severity = {}
for r in load(full_file).get("Results", []):
    for v in (r.get("Vulnerabilities", []) or []):
        full_by_severity[v["Severity"]] = full_by_severity.get(v["Severity"], 0) + 1

summary = {
    "image": image,
    "scanned_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "gate_policy": "fail on any fixable CRITICAL/HIGH (--ignore-unfixed --severity CRITICAL,HIGH)",
    "gate_result": "PASS" if gate_exit == 0 else "FAIL",
    "fixable_critical_high_count": len(gate_vulns),
    "fixable_critical_high_ids": sorted({v["VulnerabilityID"] for v in gate_vulns}),
    "full_scan_by_severity": full_by_severity,
}
with open(summary_file, "w") as f:
    json.dump(summary, f, indent=2)
    f.write("\n")
PY

if [ "$gate_exit" -eq 0 ]; then
  echo "SCAN PASS: 0 fixable CRITICAL/HIGH findings"
else
  echo "SCAN FAILED: fixable CRITICAL/HIGH findings present -- see $SUMMARY_FILE" >&2
fi
echo "artifact=$SUMMARY_FILE"
echo "raw (gitignored)=$GATE_FILE"
echo "raw (gitignored)=$FULL_FILE"

exit "$gate_exit"

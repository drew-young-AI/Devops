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
# Also generates a CycloneDX SBOM (Software Bill of Materials) -- also
# non-blocking/informational, never affects the gate's exit code.
#
# Usage:
#   scan_image.sh <image:tag> <evidence_dir>
#
# Exit code: 0 if no fixable Critical/High findings, 1 otherwise (or if
# trivy itself errors). SBOM generation failures do not affect this --
# an SBOM you can't generate yet is not a reason to block a deploy that
# has nothing to do with supply-chain attestation.

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
# Same raw/summary split as the vuln scans above: the full CycloneDX SBOM
# is ~190KB for even a minimal Python image (mostly per-package metadata
# that's identical run to run unless dependencies actually changed) and
# fully regenerable from the image at any time.
SBOM_FILE="$EVIDENCE_DIR/_raw.sbom_${SAFE_IMAGE}.cdx.json"
SBOM_SUMMARY_FILE="$EVIDENCE_DIR/sbom_summary_${SAFE_IMAGE}.json"

echo "=== [security scan] $IMAGE ==="

echo "[1/3] Full scan (all severities, informational, evidence only)..."
trivy image "$IMAGE" --scanners vuln --format json --output "$FULL_FILE" || true

echo "[2/3] Gate: fixable CRITICAL/HIGH only..."
set +e
trivy image "$IMAGE" --scanners vuln --ignore-unfixed --severity CRITICAL,HIGH \
  --format json --output "$GATE_FILE" --exit-code 1
gate_exit=$?
set -e

echo "[3/3] SBOM (CycloneDX, informational, does not affect gate)..."
trivy image "$IMAGE" --format cyclonedx --output "$SBOM_FILE" || true

# Signing is opt-in (SIGN_ARTIFACTS=1), not automatic on every build: each
# signature publishes a permanent record to the public Sigstore Rekor
# transparency log (see sign_artifact.sh's header) -- fine for an
# intentional release, not something that should happen silently on every
# routine local `deploy.sh build` during iteration.
if [ "${SIGN_ARTIFACTS:-0}" = "1" ] && [ -f "$SBOM_FILE" ]; then
  "$(dirname "${BASH_SOURCE[0]}")/sign_artifact.sh" "$SBOM_FILE" "$EVIDENCE_DIR" || \
    echo "WARNING: SBOM signing failed; continuing (signing is informational, not a gate)" >&2
fi

python3 - "$IMAGE" "$SBOM_FILE" "$SBOM_SUMMARY_FILE" "$EVIDENCE_DIR" <<'PY'
import json, sys, datetime, hashlib, os

image, sbom_file, summary_file, evidence_dir = sys.argv[1:]
bundle_file = os.path.join(evidence_dir, os.path.basename(sbom_file) + ".cosign-bundle.json")

try:
    raw = open(sbom_file, "rb").read()
    sbom = json.loads(raw)
    checksum = hashlib.sha256(raw).hexdigest()
    components = sbom.get("components", [])
    by_type = {}
    for c in components:
        t = c.get("type", "unknown")
        by_type[t] = by_type.get(t, 0) + 1
    summary = {
        "image": image,
        "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "bom_format": sbom.get("bomFormat"),
        "spec_version": sbom.get("specVersion"),
        "component_count": len(components),
        "components_by_type": by_type,
        "raw_sbom_sha256": checksum,
        "signed": os.path.isfile(bundle_file),
        "signature_bundle": bundle_file if os.path.isfile(bundle_file) else None,
        "note": "Full SBOM is at " + sbom_file + " (gitignored, regenerate with: trivy image " + image + " --format cyclonedx). This checksum lets you verify a regenerated SBOM matches what was recorded at build time.",
    }
except Exception as e:
    summary = {"image": image, "error": f"SBOM generation or parsing failed: {e}"}

with open(summary_file, "w") as f:
    json.dump(summary, f, indent=2)
    f.write("\n")
PY

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
echo "artifact=$SBOM_SUMMARY_FILE"
echo "raw (gitignored)=$GATE_FILE"
echo "raw (gitignored)=$FULL_FILE"
echo "raw (gitignored)=$SBOM_FILE"

exit "$gate_exit"

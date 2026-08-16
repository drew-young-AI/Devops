#!/usr/bin/env bash
# Static application security testing (SAST) gate -- Semgrep OSS.
#
# Fills a real hole in this platform's scanning: everything else looks at
# ARTIFACTS (Trivy on the built image, SBOM, Cosign) or at INFRASTRUCTURE
# (Checkov/OPA on IaC) or at HISTORY (Gitleaks on commits). Nothing looked at
# the application source itself, so a SQL injection or a command injection
# written today would sail through every existing gate: the image it ends up
# in has no CVEs, the IaC is fine, and no secret was committed.
#
# Policy: hard-fail on ERROR severity, report WARNING/INFO without blocking.
# Same reasoning as scan_image.sh's --ignore-unfixed: a gate that blocks on
# advisory findings becomes a gate people route around. Verified to actually
# block -- see README.md "Verified" -- by feeding it a deliberately
# vulnerable file, not by trusting the exit code's documentation.
#
# Rulesets are PINNED, not `--config=auto`. auto resolves rules over the
# network at run time, so the same commit can pass today and fail tomorrow
# with nothing in the repo having changed -- which breaks the deterministic
# feedback this platform's gates are supposed to provide.
#
# Usage:
#   scan_sast.sh [target_dir] [evidence_dir]
#
# Exit code: 0 if no ERROR-severity findings, 1 otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="${1:-$REPO_ROOT}"
EVIDENCE_DIR="${2:-$REPO_ROOT/evidence/security}"

# p/shell and p/bash do NOT exist in the registry (both 404). Listing them
# would be worse than useless: an invalid config makes Semgrep scan nothing
# while still exiting cleanly with "0 findings" -- see the scanned-files
# assertion below, which exists because of exactly that.
RULESETS=(
  p/security-audit
  p/secrets
  p/dockerfile
  p/owasp-top-ten
  p/python
  p/ci
)

if ! command -v semgrep >/dev/null 2>&1; then
  if [ -x "$HOME/.local/bin/semgrep" ]; then
    PATH="$HOME/.local/bin:$PATH"
  else
    echo "semgrep not found. Install with: uv tool install semgrep" >&2
    echo "(uv tool install, not pip install -- keeps it off the host python)" >&2
    exit 1
  fi
fi

mkdir -p "$EVIDENCE_DIR"
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
RAW_FILE="$EVIDENCE_DIR/_raw.semgrep_${STAMP}.json"
SUMMARY_FILE="$EVIDENCE_DIR/sast_summary_${STAMP}.json"

CONFIG_ARGS=()
for ruleset in "${RULESETS[@]}"; do
  CONFIG_ARGS+=(--config="$ruleset")
done

echo "=== [sast] semgrep on $TARGET ==="
echo "    rulesets: ${RULESETS[*]}"

set +e
semgrep "${CONFIG_ARGS[@]}" \
  --json --quiet \
  --exclude=archives --exclude='_raw.*' --exclude='.git' \
  --metrics=off \
  "$TARGET" > "$RAW_FILE" 2>"$RAW_FILE.err"
SEMGREP_RC=$?
set -e

if [ ! -s "$RAW_FILE" ]; then
  echo "SAST FAILED: semgrep produced no output (rc=$SEMGREP_RC)" >&2
  head -5 "$RAW_FILE.err" >&2
  exit 1
fi

# set +e around the gate block: it exits non-zero to signal "blocked", and
# under `set -e` that terminated the script instantly -- skipping the
# cleanup, the failure message and the artifact path, so a blocked scan
# printed its findings and then just vanished with a bare exit code. Found
# by a leftover .err file, not by reading the code.
set +e
python3 - "$RAW_FILE" "$SUMMARY_FILE" "$TARGET" "$STAMP" "${RULESETS[@]}" <<'PY'
import json, pathlib, sys

raw_path, summary_path, target, stamp, *rulesets = sys.argv[1:]
data = json.loads(pathlib.Path(raw_path).read_text())

results = data.get("results", [])
errors = data.get("errors", [])
scanned = data.get("paths", {}).get("scanned", [])

counts = {"ERROR": 0, "WARNING": 0, "INFO": 0}
findings = []
for r in results:
    severity = r["extra"].get("severity", "INFO")
    counts[severity] = counts.get(severity, 0) + 1
    findings.append({
        "severity": severity,
        "rule": r.get("check_id"),
        "path": r.get("path"),
        "line": r.get("start", {}).get("line"),
        "message": (r["extra"].get("message") or "").strip()[:300],
    })

# THE ASSERTION THAT MATTERS. A mistyped ruleset (p/bash, p/shell -- both
# 404) makes semgrep scan ZERO files and still report zero findings, which
# is indistinguishable from a clean codebase. Observed exactly that during
# development. "No findings" is only good news once something was actually
# examined.
config_errors = [e.get("message", "") for e in errors
                 if "download" in e.get("message", "").lower()
                 or "invalid configuration" in e.get("message", "").lower()]

blocked = counts.get("ERROR", 0) > 0
integrity_failed = len(scanned) == 0 or bool(config_errors)

summary = {
    "tool": "semgrep",
    "scanned_at": stamp,
    "target": target,
    "rulesets": rulesets,
    "gate_policy": "fail on ERROR severity; WARNING/INFO reported, not blocking",
    "gate_result": "FAIL" if (blocked or integrity_failed) else "PASS",
    "files_scanned": len(scanned),
    "counts_by_severity": counts,
    "error_findings": [f for f in findings if f["severity"] == "ERROR"],
    "non_blocking_findings": [f for f in findings if f["severity"] != "ERROR"],
    "scan_integrity": {
        "ok": not integrity_failed,
        "config_errors": config_errors,
        "note": ("A mistyped ruleset makes semgrep scan nothing and still "
                 "report zero findings. files_scanned==0 is treated as a "
                 "gate failure, not as a clean result."),
    },
}
pathlib.Path(summary_path).write_text(json.dumps(summary, indent=2) + "\n")

print(f"  files scanned: {len(scanned)}")
print(f"  ERROR={counts.get('ERROR',0)}  WARNING={counts.get('WARNING',0)}  INFO={counts.get('INFO',0)}")
for f in summary["error_findings"]:
    print(f"    [ERROR] {f['path']}:{f['line']}  {f['rule']}")
    print(f"            {f['message'][:120]}")
if integrity_failed:
    print("  SCAN INTEGRITY FAILURE -- results are not trustworthy:")
    if len(scanned) == 0:
        print("    zero files scanned")
    for message in config_errors:
        print(f"    {message[:160]}")

sys.exit(1 if (blocked or integrity_failed) else 0)
PY
GATE_RC=$?
set -e

rm -f "$RAW_FILE.err"

if [ "$GATE_RC" -eq 0 ]; then
  echo "SAST PASS"
else
  echo "SAST FAILED -- see $SUMMARY_FILE" >&2
fi
echo "artifact=$SUMMARY_FILE"
exit "$GATE_RC"

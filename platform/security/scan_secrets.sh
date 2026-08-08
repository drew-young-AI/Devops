#!/usr/bin/env bash
# Git history secret scan (Gitleaks).
#
# Scans the FULL commit history (--log-opts="--all"), not just the working
# tree -- a secret committed once and later removed is still a leak; it's
# recoverable from history for as long as the repo exists.
#
# Usage:
#   scan_secrets.sh [repo_dir] [evidence_dir]
#
# Exit code: 0 if no leaks found, 1 otherwise (gitleaks' own exit code).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${1:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
EVIDENCE_DIR="${2:-$REPO_ROOT/evidence/security}"

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "gitleaks not found. Install with: brew install gitleaks" >&2
  exit 1
fi

mkdir -p "$EVIDENCE_DIR"
REPORT_FILE="$EVIDENCE_DIR/gitleaks_$(date -u '+%Y%m%dT%H%M%SZ').json"

echo "=== [secret scan] $REPO_ROOT (full history) ==="
set +e
gitleaks git "$REPO_ROOT" --log-opts="--all" --report-format json --report-path "$REPORT_FILE" -v
exit_code=$?
set -e

if [ "$exit_code" -eq 0 ]; then
  echo "SCAN PASS: no leaks found"
else
  echo "SCAN FAILED: leaks found -- see $REPORT_FILE" >&2
fi
echo "artifact=$REPORT_FILE"

exit "$exit_code"

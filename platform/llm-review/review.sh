#!/usr/bin/env bash
# Station 5 (docs/Plan-detail.md): MLX automation integration.
#
# Runs the local MLX LLM endpoint (127.0.0.1:9000) over the *deterministic
# evidence already on disk* for one commit -- build metadata, Trivy gate
# result, SBOM summary, develop deployment health, and the pilot's own git
# diff -- and writes a machine-readable review to
# evidence/<pilot>/llm_review_<sha>_<ts>.json.
#
# What this is NOT, stated up front because it is the whole point:
#
#   This produces `LLM-generated evidence`, never Human Acceptance.
#   Plan-detail.md Station 5: "產出 LLM-generated evidence，不產出 Human
#   Acceptance". NEW_SERVICE_GUIDE.md section 8: "LLM 可以執行測試、diff
#   review、scan、報告與低風險診斷，但不能代替人類進行 ... production
#   release approval".
#
# Therefore the review VERDICT NEVER AFFECTS THIS SCRIPT'S EXIT CODE.
# A "FAIL" verdict exits 0 exactly like a "PASS" verdict does. If the
# verdict changed the exit code, someone would eventually wire this into a
# gate with `set -e`, and the LLM would silently acquire blocking authority
# over releases -- the exact thing section 8 forbids. The exit code answers
# only "did the review mechanism work", not "should this ship":
#
#   0  review produced (verdict may be PASS, CONCERN, or FAIL -- read it)
#   2  DEGRADED: endpoint unavailable, timed out, or returned unparseable
#      output. Evidence file is still written recording the degradation, so
#      "no LLM review happened" is itself traceable rather than silent.
#      The fallback is unchanged: human review, which was always required.
#   1  usage / caller error (bad pilot dir, no such sha)
#
# Usage:
#   review.sh <pilot_dir> [sha]
#
# Env overrides:
#   MLX_ENDPOINT   default http://127.0.0.1:9000
#   MLX_MODEL      default mlx-community/Qwen3.6-35B-A3B-4bit
#   MLX_TIMEOUT    default 180 (seconds)
#   LLM_REVIEW_THINKING  0 (default) | 1 -- see README.md "Determinism"
#
# Example:
#   platform/llm-review/review.sh pilots/station1-hello 6a54ff3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
  echo "Usage: $0 <pilot_dir> [sha]" >&2
  exit 1
}

[ $# -ge 1 ] || usage

PILOT_DIR="$(cd "$1" 2>/dev/null && pwd)" || { echo "No such pilot dir: $1" >&2; exit 1; }
PILOT_NAME="$(basename "$PILOT_DIR")"
SHA="${2:-$(git -C "$REPO_ROOT" rev-parse --short HEAD)}"

if ! git -C "$REPO_ROOT" rev-parse --verify --quiet "$SHA" >/dev/null; then
  echo "Not a valid git ref in this repo: $SHA" >&2
  exit 1
fi

EVIDENCE_DIR="$REPO_ROOT/evidence/$PILOT_NAME"
mkdir -p "$EVIDENCE_DIR"

export MLX_ENDPOINT="${MLX_ENDPOINT:-http://127.0.0.1:9000}"
export MLX_MODEL="${MLX_MODEL:-mlx-community/Qwen3.6-35B-A3B-4bit}"
export MLX_TIMEOUT="${MLX_TIMEOUT:-180}"
export LLM_REVIEW_THINKING="${LLM_REVIEW_THINKING:-0}"

echo "=== [llm-review] pilot=$PILOT_NAME sha=$SHA endpoint=$MLX_ENDPOINT ==="

python3 "$SCRIPT_DIR/review.py" \
  --repo-root "$REPO_ROOT" \
  --pilot-dir "$PILOT_DIR" \
  --pilot-name "$PILOT_NAME" \
  --sha "$SHA" \
  --evidence-dir "$EVIDENCE_DIR"

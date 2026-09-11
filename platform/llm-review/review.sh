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
#   MLX_MODEL      asked of the endpoint (/v1/models) when unset; an
#                  explicit value wins. Falls back to
#                  mlx-community/Qwen3.6-35B-A3B-4bit if the endpoint
#                  cannot be reached -- discovery is not a gate, the
#                  DEGRADED record still has to get written.
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
# ASK THE ENDPOINT WHAT IT IS SERVING, do not hardcode it (2026-09-11).
#
# The default here was `mlx-community/Qwen3.6-35B-A3B-4bit`. The endpoint was
# serving `/Users/drew/models/Qwen3.8-27B-4bit`. A review run would have failed
# on an unknown model -- and `probe_llm_review` reports a failed run as
# DEGRADED, which reads like "the review found problems" rather than "the
# review never happened". A model name written down in two places drifts; the
# server already knows the answer.
#
# An explicit MLX_MODEL still wins, so a caller can pin one deliberately.
if [ -z "${MLX_MODEL:-}" ]; then
  MLX_MODEL="$({ curl -s --max-time 10 "${MLX_ENDPOINT:-http://127.0.0.1:9000}/v1/models" 2>/dev/null \
    | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print((d.get("data") or [{}])[0].get("id", ""))
except Exception:
    print("")' 2>/dev/null; } || true)"
fi
# DISCOVERY FAILING IS NOT A GATE. The first version of this exited 1 when the
# endpoint named no model, and the existing suite caught what that destroyed:
# an unreachable endpoint is supposed to produce a DEGRADED artefact and exit
# 2, so that "the review could not run" is itself recorded as evidence. An
# early exit leaves no trace at all -- silence, which is the one outcome this
# whole directory exists to prevent. So discovery falls back and review.py
# still gets to write the DEGRADED record.
MLX_MODEL="${MLX_MODEL:-mlx-community/Qwen3.6-35B-A3B-4bit}"
export MLX_MODEL
export MLX_TIMEOUT="${MLX_TIMEOUT:-180}"
export LLM_REVIEW_THINKING="${LLM_REVIEW_THINKING:-0}"

echo "=== [llm-review] pilot=$PILOT_NAME sha=$SHA endpoint=$MLX_ENDPOINT ==="

python3 "$SCRIPT_DIR/review.py" \
  --repo-root "$REPO_ROOT" \
  --pilot-dir "$PILOT_DIR" \
  --pilot-name "$PILOT_NAME" \
  --sha "$SHA" \
  --evidence-dir "$EVIDENCE_DIR"

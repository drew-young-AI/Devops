#!/usr/bin/env bash
# llm-review contract tests.
#
# Runs entirely against a stub endpoint, never the real MLX server: CI has
# no MLX, and more importantly the degraded modes (prose instead of JSON, an
# invalid verdict value, an empty content field) cannot be produced on
# demand from a real model.
#
# The single most important assertion in this file is that a FAIL verdict
# exits 0. That is the mechanical guarantee behind "LLM-generated evidence,
# not Human Acceptance" -- if the verdict ever drove the exit code, the LLM
# would silently gain blocking authority over releases the first time
# someone put this in a `set -e` pipeline.

set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="llm-review"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== llm-review contract =="

SANDBOX="$(make_git_sandbox)"
REVIEW="$SANDBOX/platform/llm-review/review.sh"
PILOT="$SANDBOX/pilots/fake-pilot"
EVIDENCE="$SANDBOX/evidence/fake-pilot"
FIXTURES="$(mktemp -d)"
on_exit 'rm -rf "$FIXTURES"'

SANDBOXES+=("$FIXTURES")

chat_fixture() {
  # `/v1/models` is served too, because review.sh now ASKS the endpoint which
  # model it has instead of carrying a hardcoded name. The old default
  # (`mlx-community/Qwen3.6-35B-A3B-4bit`) had drifted from what the endpoint
  # actually served (`/Users/drew/models/Qwen3.8-27B-4bit`), and a review that
  # fails on an unknown model is reported by probe_llm_review as DEGRADED --
  # which reads like "the review found problems", not "the review never ran".
  local path="$1" message="$2"
  cat > "$path" <<EOF
{"/v1/models": {"status": 200, "body": {"object": "list", "data": [{"id": "stub-model", "object": "model"}]}},
 "/v1/chat/completions": {"status": 200, "body": {"choices": [{"index": 0, "finish_reason": "stop", "message": $message}]}}}
EOF
}

run_review() { run_cmd env MLX_ENDPOINT="http://127.0.0.1:$PORT" "$REVIEW" "$PILOT"; }

review_field() {
  python3 -c "
import glob, json, sys
files = sorted(glob.glob('$EVIDENCE/llm_review_*.json'))
print(json.load(open(files[-1])).get('$1'))
" 2>/dev/null
}

# --- caller errors ------------------------------------------------------

run_cmd "$REVIEW"
assert_rc 1 "no arguments exits 1"

run_cmd "$REVIEW" "$SANDBOX/pilots/does-not-exist"
assert_rc 1 "nonexistent pilot dir exits 1"

run_cmd "$REVIEW" "$PILOT" cafebabe-not-a-ref
assert_rc 1 "invalid git ref exits 1"

# --- the core invariant -------------------------------------------------

PORT=19321
chat_fixture "$FIXTURES/fail.json" '{"role":"assistant","content":"{\"verdict\":\"FAIL\",\"findings\":[],\"summary\":\"broken\"}"}'
start_stub "$PORT" "$FIXTURES/fail.json"
run_review
assert_rc 0 "FAIL verdict still exits 0 -- the verdict is never a gate"
assert_equals "FAIL" "$(review_field verdict)" "FAIL verdict is recorded in evidence"
assert_output_contains "verdict=FAIL" "FAIL verdict is reported to the caller"
stop_stubs
rm -f "$EVIDENCE"/llm_review_*.json

PORT=19322
chat_fixture "$FIXTURES/pass.json" '{"role":"assistant","content":"{\"verdict\":\"PASS\",\"findings\":[],\"summary\":\"ok\"}"}'
start_stub "$PORT" "$FIXTURES/pass.json"
run_review
assert_rc 0 "PASS verdict exits 0"
assert_equals "OK" "$(review_field status)" "PASS run records status OK"
assert_equals "None" "$(review_field human_acceptance)" "human_acceptance is always null"
stop_stubs
rm -f "$EVIDENCE"/llm_review_*.json

# A fenced JSON block is the most common way a model deviates; tolerated on
# purpose, unlike anything that changes the meaning of the verdict.
PORT=19323
chat_fixture "$FIXTURES/fenced.json" '{"role":"assistant","content":"```json\n{\"verdict\":\"CONCERN\",\"findings\":[],\"summary\":\"s\"}\n```"}'
start_stub "$PORT" "$FIXTURES/fenced.json"
run_review
assert_rc 0 "markdown-fenced JSON is accepted"
assert_equals "CONCERN" "$(review_field verdict)" "fenced verdict parsed correctly"
stop_stubs
rm -f "$EVIDENCE"/llm_review_*.json

# --- degraded modes -----------------------------------------------------

PORT=19324  # nothing listening
run_review
assert_rc 2 "endpoint unavailable -> exit 2"
assert_equals "DEGRADED_UNAVAILABLE" "$(review_field status)" "unavailable is recorded as such"
assert_output_contains "Human review path is unchanged" "degraded run points at the human fallback"
rm -f "$EVIDENCE"/llm_review_*.json

PORT=19325
chat_fixture "$FIXTURES/prose.json" '{"role":"assistant","content":"Sure! Looks fine to me."}'
start_stub "$PORT" "$FIXTURES/prose.json"
run_review
assert_rc 2 "prose instead of JSON -> exit 2"
assert_equals "DEGRADED_UNPARSEABLE_VERDICT" "$(review_field status)" "prose recorded as unparseable"
stop_stubs
rm -f "$EVIDENCE"/llm_review_*.json

# Valid JSON, invalid verdict value: must NOT be silently accepted, because
# an unrecognised verdict would otherwise flow into evidence as if real.
PORT=19326
chat_fixture "$FIXTURES/lgtm.json" '{"role":"assistant","content":"{\"verdict\":\"LGTM\",\"findings\":[]}"}'
start_stub "$PORT" "$FIXTURES/lgtm.json"
run_review
assert_rc 2 "verdict outside PASS/CONCERN/FAIL -> exit 2"
stop_stubs
rm -f "$EVIDENCE"/llm_review_*.json

# Reasoning model burned the whole budget and returned no content.
PORT=19327
chat_fixture "$FIXTURES/nocontent.json" '{"role":"assistant","reasoning":"thinking..."}'
start_stub "$PORT" "$FIXTURES/nocontent.json"
run_review
assert_rc 2 "empty content -> exit 2"
assert_equals "DEGRADED_NO_CONTENT" "$(review_field status)" "empty content has its own status"
stop_stubs

# A degraded run must still leave a trace: silence is indistinguishable from
# "reviewed and fine".
DEGRADED_COUNT="$(find "$EVIDENCE" -name 'llm_review_*.json' | wc -l | tr -d ' ')"
assert_equals "1" "$DEGRADED_COUNT" "degraded run still writes an evidence file"
rm -f "$EVIDENCE"/llm_review_*.json

# --- same-second collision ----------------------------------------------

PORT=19328
chat_fixture "$FIXTURES/three.json" '{"role":"assistant","content":"{\"verdict\":\"PASS\",\"findings\":[],\"summary\":\"s\"}"}'
start_stub "$PORT" "$FIXTURES/three.json"
run_review; run_review; run_review
COLLIDE_COUNT="$(find "$EVIDENCE" -name 'llm_review_*.json' | wc -l | tr -d ' ')"
assert_equals "3" "$COLLIDE_COUNT" "three runs in one second write three distinct files"
stop_stubs

# --- the endpoint names the model, and the failure is legible ---------------
#
# Two branches, both added 2026-09-11 and both previously untestable because
# the model name was a constant.

# An explicit MLX_MODEL must WIN over discovery: a caller pinning a model is
# making a deliberate choice, and silently replacing it with whatever the
# server happens to be serving would make a pinned run unreproducible.
PINNED="$(mktemp -d)"; SANDBOXES+=("$PINNED")
chat_fixture "$PINNED/fx.json" '{"role":"assistant","content":"{\"verdict\":\"PASS\",\"summary\":\"ok\",\"findings\":[]}"}'
PORT=19331
start_stub "$PORT" "$PINNED/fx.json"
run_cmd env MLX_ENDPOINT="http://127.0.0.1:$PORT" MLX_MODEL="pinned-model" "$REVIEW" "$PILOT"
assert_rc 0 "an explicitly pinned MLX_MODEL still runs"
PINNED_MODEL="$(python3 -c "
import glob, json, os
files = glob.glob('$EVIDENCE/llm_review_*.json')
newest = max(files, key=os.path.getmtime)
print((json.load(open(newest)).get('reproducibility') or {}).get('model'))
" 2>/dev/null)"
assert_equals "pinned-model" "$PINNED_MODEL" "and is used verbatim, not replaced by discovery"
stop_stubs

# An unreachable endpoint must NOT be short-circuited by model discovery. The
# first version of the discovery code exited 1 here with curl's failure, and
# the suite above caught it: the contract is a DEGRADED artefact and exit 2, so
# that a review which could not run still leaves a trace. Discovery therefore
# falls back to the default rather than refusing, and this asserts it.
run_cmd env MLX_ENDPOINT="http://127.0.0.1:1" "$REVIEW" "$PILOT"
assert_rc 2 "a dead endpoint still reaches the DEGRADED path, not an early exit"
assert_output_contains "DEGRADED" "and the run is recorded as degraded rather than vanishing"

suite_summary

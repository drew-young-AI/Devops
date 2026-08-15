#!/usr/bin/env bash
# deploy.sh contract tests -- the safety gates, in isolation, in seconds.
#
# Scope on purpose: every case here fails BEFORE deploy.sh reaches a docker
# command. That is what makes the suite fast, hermetic, and safe to run on
# any machine (including CI with no Docker daemon and no images). The gates
# are also the part where a silent regression is most expensive: a broken
# develop-validation gate does not throw an error, it just lets an
# unvalidated image reach production-like.
#
# What this suite deliberately does NOT cover: the actual deploy/promote
# happy path. That needs a real daemon, a real image and a real NGINX, and
# is covered by the manual end-to-end runs recorded in
# platform/compose/README.md. Pretending otherwise with heavy mocks would
# test the mocks.

set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="deploy-contract"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== deploy.sh contract =="

SANDBOX="$(make_sandbox)"
DEPLOY="$SANDBOX/platform/compose/deploy.sh"
PILOT="$SANDBOX/pilots/fake-pilot"
SHA="$(sandbox_sha "$PILOT")"

# --- argument handling --------------------------------------------------

run_cmd "$DEPLOY"
assert_rc 1 "no arguments exits 1"
assert_output_contains "Usage:" "no arguments prints usage"

run_cmd "$DEPLOY" not-a-command
assert_rc 1 "unknown subcommand exits 1"

run_cmd "$DEPLOY" build
assert_rc 1 "build with no pilot_dir exits 1"

run_cmd "$DEPLOY" deploy develop
assert_rc 1 "deploy with missing pilot_dir exits 1"

# usage() is the only discoverability surface for someone who runs the
# script blind. If a subcommand exists but is unlisted, it may as well not
# exist -- and promote/rollback are the two most consequential ones.
run_cmd "$DEPLOY"
assert_output_contains "promote" "usage lists 'promote'"
assert_output_contains "rollback" "usage lists 'rollback'"

# --- deploy: develop-only restriction -----------------------------------

run_cmd "$DEPLOY" deploy production-like "$PILOT"
assert_rc 1 "deploy refuses production-like as a target"
assert_output_contains "only supports 'develop'" "deploy explains the develop-only rule"
# The rejection message must not claim promotion is unbuilt -- it is built,
# in this same file. A stale message sends the reader to look for something
# that already exists.
assert_output_not_contains "not-yet-built" "deploy's rejection message is not stale about promote"

# --- promote: gate 1, develop-validation --------------------------------

run_cmd "$DEPLOY" promote "$PILOT"
assert_rc 1 "promote refuses with no develop evidence"
assert_output_contains "No develop deployment evidence" "promote names the missing evidence"

write_json "$SANDBOX/evidence/fake-pilot/deploy_develop_${SHA}.json" \
  '{"environment":"develop","commit_sha":"'"$SHA"'","health_status":"unhealthy"}'
run_cmd "$DEPLOY" promote "$PILOT"
assert_rc 1 "promote refuses when develop evidence says unhealthy"
assert_output_contains "not healthy" "promote explains the unhealthy refusal"

# Evidence present but health_status absent entirely: must be treated as
# not-healthy (fail closed), never as a pass. read_state_field's default is
# 'unknown', and 'unknown' != 'healthy' -- this asserts that stays true.
write_json "$SANDBOX/evidence/fake-pilot/deploy_develop_${SHA}.json" \
  '{"environment":"develop","commit_sha":"'"$SHA"'"}'
run_cmd "$DEPLOY" promote "$PILOT"
assert_rc 1 "promote fails closed when health_status field is missing"

# Malformed JSON must also fail closed rather than crash into a pass.
write_json "$SANDBOX/evidence/fake-pilot/deploy_develop_${SHA}.json" '{not valid json'
run_cmd "$DEPLOY" promote "$PILOT"
assert_rc 1 "promote fails closed on malformed develop evidence"

# --- rollback: no prior color -------------------------------------------

run_cmd "$DEPLOY" rollback "$PILOT"
assert_rc 1 "rollback refuses with no production-like state"
assert_output_contains "No prior production-like color" "rollback explains why"

write_json "$SANDBOX/evidence/fake-pilot/production_like_state.json" \
  '{"active_color":"blue","previous_color":"none"}'
run_cmd "$DEPLOY" rollback "$PILOT"
assert_rc 1 "rollback refuses when there is no previous color (first promotion)"

# --- teardown: refuses to remove the live color -------------------------

write_json "$SANDBOX/evidence/fake-pilot/production_like_state.json" \
  '{"active_color":"blue","previous_color":"green"}'
run_cmd "$DEPLOY" teardown production-like "$PILOT" blue
assert_rc 1 "teardown refuses to destroy the ACTIVE color"
assert_output_contains "currently ACTIVE" "teardown explains the refusal"

run_cmd "$DEPLOY" teardown production-like "$PILOT" purple
assert_rc 1 "teardown rejects an invalid color"

# --- llm review display is advisory, never a gate -----------------------

# A FAIL verdict must not, on its own, change deploy.sh's behaviour. This is
# the automated counterpart to platform/llm-review/README.md's stated
# guarantee; without it, someone could later "helpfully" make the verdict
# blocking and no test would object.
write_json "$SANDBOX/evidence/fake-pilot/llm_review_${SHA}_20260101T000000Z.json" \
  '{"status":"OK","verdict":"FAIL","summary":"catastrophic","findings":[],"generated_at":"2026-01-01T00:00:00Z","reproducibility":{"model":"test"}}'
write_json "$SANDBOX/evidence/fake-pilot/deploy_develop_${SHA}.json" \
  '{"environment":"develop","commit_sha":"'"$SHA"'","health_status":"unhealthy"}'
run_cmd "$DEPLOY" promote "$PILOT"
assert_rc 1 "promote still blocked by the real gate, not by the LLM verdict"
assert_output_contains "not healthy" "the blocking reason is the develop gate, not the LLM"

suite_summary

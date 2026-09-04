#!/usr/bin/env bash
# check_health.sh verdict tests.
#
# All four verdicts, driven by stubs rather than the real stack. Two of the
# integrity conditions this asserts CANNOT be produced against a real
# Prometheus on demand -- "up but zero rules loaded" and "up but no
# Alertmanager wired" -- and those are precisely the states where a naive
# checker reports healthy while nothing is watching. Stubbing is not a
# shortcut here; it is the only way to test them at all.

set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="check-health"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== check_health.sh verdicts =="

CHECK="$REPO_ROOT/platform/observability/check_health.sh"
FIXTURES="$(mktemp -d)"
# Registered on the NEXT line, not later. Anything between the mktemp and the
# registration is a window in which an early exit leaks the directory -- which
# is how three suites were still leaking one each after the sandbox registry
# was fixed.
on_exit 'rm -rf "$FIXTURES"'

SANDBOXES+=("$FIXTURES")

# Builds a fixture: healthy Prometheus + Alertmanager, with the alert list
# and rule list supplied by the caller.
make_fixture() {
  local path="$1" rules="$2" alertmanagers="$3" alerts="$4"
  cat > "$path" <<EOF
{
  "/api/v1/rules": {"status": 200, "body": {"data": {"groups": [{"name": "g", "rules": $rules}]}}},
  "/api/v1/alertmanagers": {"status": 200, "body": {"data": {"activeAlertmanagers": $alertmanagers}}},
  "/api/v1/targets": {"status": 200, "body": {"data": {"activeTargets": [{"labels": {"job": "j", "environment": "develop"}, "health": "up"}]}}},
  "/api/v2/alerts": {"status": 200, "body": $alerts}
}
EOF
}

OK_RULES='[{"name":"R","state":"inactive","health":"ok"}]'
OK_AMS='[{"url":"http://alertmanager:9093/api/v2/alerts"}]'

alert() {
  printf '{"labels":{"alertname":"%s","severity":"%s","environment":"e","service":"s"},"annotations":{"summary":"sum"},"startsAt":"2026-01-01T00:00:00Z"}' "$1" "$2"
}

PORT=19311
run_check() { run_cmd env PROMETHEUS_URL="http://127.0.0.1:$PORT" ALERTMANAGER_URL="http://127.0.0.1:$PORT" "$CHECK" --no-evidence; }

# --- HEALTHY ------------------------------------------------------------
make_fixture "$FIXTURES/healthy.json" "$OK_RULES" "$OK_AMS" '[]'
start_stub "$PORT" "$FIXTURES/healthy.json"
run_check
assert_rc 0 "HEALTHY: monitoring verified, no alerts -> exit 0"
assert_output_contains "verdict: HEALTHY" "HEALTHY: verdict text"
stop_stubs

# --- DEGRADED -----------------------------------------------------------
PORT=19312
make_fixture "$FIXTURES/warn.json" "$OK_RULES" "$OK_AMS" "[$(alert W warning)]"
start_stub "$PORT" "$FIXTURES/warn.json"
run_check
assert_rc 1 "DEGRADED: warning alert -> exit 1"
assert_output_contains "verdict: DEGRADED" "DEGRADED: verdict text"
stop_stubs

# --- CRITICAL -----------------------------------------------------------
PORT=19313
make_fixture "$FIXTURES/crit.json" "$OK_RULES" "$OK_AMS" "[$(alert W warning),$(alert C critical)]"
start_stub "$PORT" "$FIXTURES/crit.json"
run_check
assert_rc 2 "CRITICAL: critical outranks warning -> exit 2"
assert_output_contains "verdict: CRITICAL" "CRITICAL: verdict text"
stop_stubs

# --- UNKNOWN: the failure modes that matter -----------------------------

# Nothing listening at all.
PORT=19314
run_check
assert_rc 3 "UNKNOWN: Prometheus unreachable -> exit 3"
assert_output_contains "monitoring itself is broken" "UNKNOWN: says monitoring is broken"

# Prometheus is up and cheerfully reports zero alerts -- because it has zero
# rules. Identical output to a healthy system, opposite meaning.
PORT=19315
make_fixture "$FIXTURES/norules.json" '[]' "$OK_AMS" '[]'
start_stub "$PORT" "$FIXTURES/norules.json"
run_check
assert_rc 3 "UNKNOWN: zero alert rules loaded -> exit 3, never HEALTHY"
assert_output_contains "0 alert rules" "UNKNOWN: names the zero-rules cause"
stop_stubs

# Rules exist but are erroring -- they cannot fire, so an empty alert list
# is meaningless.
PORT=19316
make_fixture "$FIXTURES/badrule.json" \
  '[{"name":"R","state":"inactive","health":"err","lastError":"parse error"}]' "$OK_AMS" '[]'
start_stub "$PORT" "$FIXTURES/badrule.json"
run_check
assert_rc 3 "UNKNOWN: a rule failing to evaluate -> exit 3"
stop_stubs

# Prometheus healthy, rules fine, but no Alertmanager wired: alerts fire
# into the void and the queried list stays empty forever.
PORT=19317
make_fixture "$FIXTURES/noam.json" "$OK_RULES" '[]' '[]'
start_stub "$PORT" "$FIXTURES/noam.json"
run_check
assert_rc 3 "UNKNOWN: no Alertmanager wired -> exit 3, never HEALTHY"
assert_output_contains "alerts go nowhere" "UNKNOWN: names the unwired-Alertmanager cause"
stop_stubs

# --- evidence -----------------------------------------------------------
PORT=19318
EV_SANDBOX="$(make_sandbox)"
make_fixture "$FIXTURES/ev.json" "$OK_RULES" "$OK_AMS" '[]'
start_stub "$PORT" "$FIXTURES/ev.json"
run_cmd env PROMETHEUS_URL="http://127.0.0.1:$PORT" ALERTMANAGER_URL="http://127.0.0.1:$PORT" \
  "$EV_SANDBOX/platform/observability/check_health.sh"
assert_rc 0 "evidence run still exits 0"
EV_COUNT="$(find "$EV_SANDBOX/evidence/observability" -name 'health_*.json' 2>/dev/null | wc -l | tr -d ' ')"
assert_equals "1" "$EV_COUNT" "evidence file written to evidence/observability/"
stop_stubs

suite_summary

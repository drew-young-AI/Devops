#!/usr/bin/env bash
# The log pipeline must be carrying logs, and every declared data class must be
# one the routing rules can actually tell apart.
#
# WHY THIS SUITE EXISTS (2026-09-02).
#
# The decision "we do not need ELK" rests entirely on Loki already occupying
# that slot. That is only true if Loki is receiving logs, and nothing in the
# repository checked. It was -- 71,000 lines across 111 streams -- but the same
# look found two things configuration alone could never show:
#
#   1. the `restricted` tenant has never carried a single stream in production.
#      It was proven once with a throwaway container and has been idle since.
#      That is the correct state, not a fault, so it is REPORTED and never
#      failed -- a check that is red by design is a check people stop reading.
#
#   2. station2-twin declared `platform.data_class: platform`. There is no such
#      class. The routing keeps a container in `restricted` only on an exact
#      match and puts everything else in `internal`, so an unrecognised value
#      does not error -- it lands in the tenant with the WIDER audience and the
#      LONGER retention, silently. The compose comment above that label said it
#      was set explicitly "because an unlabelled service silently lands in the
#      wrong tenant", which is exactly what the value it used caused.
#
# That second one is the shape worth keeping in mind: the partition is provably
# exhaustive, which is what makes it safe, and is also what makes a typo
# invisible. Validation cannot live in the routing rules without destroying the
# property that makes them correct, so it lives here.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="loki-coverage"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== the log pipeline must be moving logs, and every data class must be routable =="

COV="$REPO_ROOT/platform/observability/loki_coverage.py"
assert_file_exists "$COV" "loki_coverage.py exists"

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- the real pipeline ------------------------------------------------------
if curl -fsS --max-time 5 http://127.0.0.1:13100/metrics >"$WORK/live.txt" 2>/dev/null; then
  LOKI_COVERAGE_PROM="$WORK/live.prom" run_cmd python3 "$COV" --check
  assert_rc 0 "live: every declared data class is one the routing can distinguish"
  assert_output_contains "platform" "live: names the tenant carrying logs"

  LOKI_COVERAGE_PROM="$WORK/live.prom" python3 "$COV" --json > "$WORK/live.json" 2>/dev/null
  LINES="$(python3 -c "
import json,sys
print(json.load(open(sys.argv[1]))['lines'].get('platform',0))" "$WORK/live.json" 2>/dev/null || echo 0)"
  if [ "$LINES" -ge 100 ] 2>/dev/null; then
    _pass "live: Loki has actually accepted log lines ($LINES on tenant platform)"
  else
    _fail "live: Loki has actually accepted log lines" "only $LINES -- the pipeline is configured but idle"
  fi
  assert_file_exists "$WORK/live.prom" "live: writes a textfile for the board"
  grep -q "devops_loki_unrecognised_class_total" "$WORK/live.prom" \
    && _pass "live: the textfile carries the unrecognised-class gauge" \
    || _fail "live: the textfile carries the unrecognised-class gauge" "gauge missing"
else
  echo "  SKIP live checks -- Loki not reachable on 127.0.0.1:13100"
fi

# --- control: an unrecognised class must be caught --------------------------
#
# Injected through the environment rather than by editing a compose file: the
# fault being simulated is a value, and manufacturing it in a real file would
# leave the repository one interrupted run away from a broken pilot.
cp "$WORK/live.txt" "$WORK/metrics.txt" 2>/dev/null || cat > "$WORK/metrics.txt" <<'EOF'
loki_distributor_lines_received_total{tenant="platform"} 5000
loki_ingester_streams_created_total{tenant="platform"} 40
loki_distributor_bytes_received_total{tenant="platform"} 900000
EOF

LOKI_COVERAGE_METRICS_FILE="$WORK/metrics.txt" \
LOKI_COVERAGE_PROM="$WORK/c.prom" \
LOKI_COVERAGE_CLASS_VALUES="internal,restrictd" \
  run_cmd python3 "$COV" --check
assert_rc 1 "catches: a data class the routing rules cannot distinguish"
assert_output_contains "restrictd" "names the offending value rather than just failing"
assert_output_contains "wider tenant" "says what the consequence is, not just that it is wrong"

# --- control: the valid set must pass --------------------------------------
LOKI_COVERAGE_METRICS_FILE="$WORK/metrics.txt" \
LOKI_COVERAGE_PROM="$WORK/c.prom" \
LOKI_COVERAGE_CLASS_VALUES="internal,restricted" \
  run_cmd python3 "$COV" --check
assert_rc 0 "accepts: both recognised classes"

# --- control: an idle pipeline must be refused, not reported clean ----------
cat > "$WORK/idle.txt" <<'EOF'
loki_distributor_lines_received_total{tenant="platform"} 3
loki_ingester_streams_created_total{tenant="platform"} 1
EOF
LOKI_COVERAGE_METRICS_FILE="$WORK/idle.txt" \
LOKI_COVERAGE_PROM="$WORK/c.prom" \
LOKI_COVERAGE_CLASS_VALUES="internal" \
  run_cmd python3 "$COV" --check
assert_rc 2 "refuses to report on a pipeline that is configured but idle"
assert_output_contains "below the floor" "says why an idle pipeline is refused rather than passed"

# --- control: unreachable Loki must refuse, not pass ------------------------
LOKI_METRICS_URL="http://127.0.0.1:1/metrics" \
LOKI_COVERAGE_PROM="$WORK/c.prom" \
  run_cmd python3 "$COV" --check
assert_rc 2 "refuses when Loki cannot be reached, rather than reporting no findings"

# --- control: a never-used tenant is reported, never failed -----------------
LOKI_COVERAGE_METRICS_FILE="$WORK/metrics.txt" \
LOKI_COVERAGE_PROM="$WORK/c.prom" \
LOKI_COVERAGE_CLASS_VALUES="internal" \
  run_cmd python3 "$COV" --check
assert_rc 0 "an idle declared tenant does not fail the check"
assert_output_contains "never used" "an idle declared tenant is still reported"

suite_summary

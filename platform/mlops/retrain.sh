#!/usr/bin/env bash
# Weekly retrain: rebuild features, re-backtest, publish only if it qualifies.
#
# WHY WEEKLY, AND WHY NOT MORE OFTEN.
#
# The cadence comes from how fast the thing it watches can change -- the same
# rule every other job in jobs.conf follows. The source is WEEKLY surveillance
# data published with roughly a two-week lag. Retraining daily would rebuild an
# identical feature set six days out of seven and write six model_run rows that
# differ only by timestamp: noise that makes the one real weekly change harder
# to see, not easier.
#
# WHY PUBLISHING IS NOT A SEPARATE DECISION HERE.
#
# All steps run unconditionally. publish_forecast.py refuses on its own when no
# model beats its baselines, and the forecast_gate TRIGGER refuses again at the
# INSERT. Making this script decide too would put a third copy of the rule in a
# place nobody would think to check -- and the copies would drift.
#
# EXIT 0 WHEN NOTHING IS PUBLISHED, ON PURPOSE.
#
# "The model did not qualify this week" is a correct outcome, not a failure.
# Exiting non-zero would page someone every week for a system behaving exactly
# as designed, and a job that cries wolf weekly is a job whose alerts get muted
# -- which is precisely how the 3h55m outage on 2026-08-19 stayed invisible.
#
# A REAL failure (database down, image build broken, feature build crashing)
# still exits non-zero, because those stop the pipeline rather than concluding it.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MLOPS="$ROOT/pilots/station2-twin/mlops"
export PGPASSWORD="${PGPASSWORD:-twin-bootstrap}"

echo "=== [mlops] weekly retrain $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="

step() {
  local label="$1"; shift
  echo ""
  echo "--- $label"
  "$@" || { echo "FAILED: $label" >&2; return 1; }
}

step "1/4 build features" "$MLOPS/run.sh" build_features.py || exit 1
step "2/4 backtest t+1"   "$MLOPS/run.sh" backtest.py --horizon 1 --predict-delta || exit 1
step "3/4 backtest t+2"   "$MLOPS/run.sh" backtest.py --horizon 2 --predict-delta || exit 1
# The gate refusing is NOT a job failure -- retrain did everything right and the
# model simply lost to its baseline. So the job exits 0, the scheduler stays
# green, and nobody is told. That silence is the problem: a release that quietly
# did not happen is indistinguishable from one nobody attempted. `blocked` is a
# third outcome for exactly this, reported without pretending it is a fault.
if step "4/4 publish"     "$MLOPS/run.sh" publish_forecast.py; then
  :
else
  rc=$?
  "$ROOT/platform/notify/emit_event.sh" model-gate blocked \
    "publish_forecast 拒絕發布（rc=$rc）：模型未勝過天真基準，閘門依設計擋下" \
    >/dev/null 2>&1 || true
  exit $rc
fi

echo ""
echo "=== published forecasts ==="
docker run --rm -i -e PGPASSWORD --network host postgres:16-alpine \
  psql -h 127.0.0.1 -p 15432 -U twin -d twin -qtAX -c \
  "SELECT '  t+' || horizon_weeks || '  ' || target_epi_year || 'W' || target_epi_week || '  ' || round(predicted_value::numeric*100, 4) || ' pp  (model_run ' || model_run_id || ')' FROM forecast ORDER BY horizon_weeks" 2>&1

echo ""
echo "retrain complete"

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

# TWO TARGETS since 2026-09-09. `influenza` is a different disease from
# `influenza_like_illness` in this warehouse -- 188,920 facts of its own -- and
# it is the easier problem by a wide margin. Each target gets its own feature
# set, and every downstream step is given the id EXPLICITLY: "the newest
# feature set" stopped being unambiguous the moment there were two, and a run
# that asked for ILI would otherwise have scored flu and filed the number under
# ILI's horizon.
TARGETS=(influenza_like_illness influenza)
declare -a FSIDS=()
for D in "${TARGETS[@]}"; do
  step "1/5 build features [$D]" "$MLOPS/run.sh" build_features.py --disease "$D" \
    || exit 1
  FS="$(docker exec station2-twin-db-1 psql -U twin -d twin -qtAX -c \
    "SELECT fs.feature_set_id FROM feature_set fs
       JOIN disease d ON d.disease_id = fs.disease_id
      WHERE d.code = '$D' ORDER BY fs.built_at DESC LIMIT 1" 2>/dev/null | tr -d ' ')"
  [ -n "$FS" ] || { echo "FAILED: no feature_set for $D" >&2; exit 1; }
  FSIDS+=("$FS")
  for H in 1 2; do
    step "$((H+1))/5 backtest t+$H [$D fs=$FS]" "$MLOPS/run.sh" backtest.py \
      --feature-set "$FS" --horizon "$H" --predict-delta || exit 1
  done
done
# The gate refusing is NOT a job failure -- retrain did everything right and the
# model simply lost to its baseline. So the job exits 0, the scheduler stays
# green, and nobody is told. That silence is the problem: a release that quietly
# did not happen is indistinguishable from one nobody attempted. `blocked` is a
# third outcome for exactly this, reported without pretending it is a fault.
if step "4/5 publish"     "$MLOPS/run.sh" publish_forecast.py; then
  :
else
  rc=$?
  "$ROOT/platform/notify/emit_event.sh" model-gate blocked \
    "publish_forecast 拒絕發布（rc=${rc}）：模型未勝過天真基準，閘門依設計擋下" \
    >/dev/null 2>&1 || true
  exit $rc
fi

# ---- 5/5: replay the DECISION over history ---------------------------------
#
# The live track record is n=1 and grows by one a week. This replays the gate
# and the replacement rule over every origin in history under today's code,
# which answers "would this system's published numbers have beaten persistence"
# at n in the hundreds, today. It is a SIMULATION and is recorded under its own
# metric prefix so it can never be added to the live count.
#
# Deliberately after publishing and deliberately NOT fatal: a replay that fails
# must not stop a retrain that succeeded. ~21s per horizon.
REPLAY_DIR="$ROOT/evidence/mlops"
mkdir -p "$REPLAY_DIR"
REPLAY_TS="$(date -u '+%Y%m%dT%H%M%SZ')"
for FS in ${FSIDS+"${FSIDS[@]}"}; do
 for H in 1 2; do
  OUT="$REPLAY_DIR/policy_backtest_fs${FS}_t${H}_${REPLAY_TS}.json"
  echo ""
  echo "--- 5/5 policy replay fs=$FS t+$H"
  if "$MLOPS/run.sh" policy_backtest.py --feature-set "$FS" --horizon "$H" \
       --all-origins --json - > "$OUT" 2>/dev/null; then
    python3 -c "
import json,sys
d=json.load(open('$OUT'))['summary']
if d['n']:
    print('  n=%d/%d  win %.1f%%  vs persistence %+.2f%%' % (
        d['n'], d['n_origins'], d['win_rate']*100, d['margin_ratio']*100))
else:
    print('  published nothing over %d origins' % d['n_origins'])"
  else
    echo "  replay failed (non-fatal); removing partial artifact" >&2
    rm -f "$OUT"
  fi
 done
done

# The interval, computed from the replay artifacts that were just written. A
# point estimate published without one is how "-3.60%" gets read as "worse"
# when the interval says "indistinguishable".
echo ""
echo "--- 5b/5 replay significance"
python3 "$ROOT/platform/mlops/replay_significance.py" \
  --json "$REPLAY_DIR/replay_significance_${REPLAY_TS}.json" \
  || echo "  significance failed (non-fatal)" >&2

echo ""
echo "=== published forecasts ==="
docker run --rm -i -e PGPASSWORD --network host postgres:16-alpine \
  psql -h 127.0.0.1 -p 15432 -U twin -d twin -qtAX -c \
  "SELECT '  t+' || horizon_weeks || '  ' || target_epi_year || 'W' || target_epi_week || '  ' || round(predicted_value::numeric*100, 4) || ' pp  (model_run ' || model_run_id || ')' FROM forecast ORDER BY horizon_weeks" 2>&1

echo ""
echo "retrain complete"

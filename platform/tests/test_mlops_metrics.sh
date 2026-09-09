#!/usr/bin/env bash
# The model layer must produce NUMBERS, not just a lamp.
#
# WHY THIS SUITE EXISTS.
#
# Measured 2026-09-08: Prometheus held 99 metric names -- `devops_*` 20,
# `dataops_*` 15, anything about a model ZERO. The mlops row on the board was
# five green lamps over nothing measured. That is this platform's catalogued
# shape 「登記為存在，但不執行」 one layer up, and it is invisible precisely
# because the lamps were green.
#
# The central assertion is the same JOIN dataops uses: every `mlops_*` metric
# named in an alert rule must appear in the file the exporter actually writes.
# A rule against a metric nobody emits parses, passes promtool, sits in the
# rules directory looking like coverage, and can never fire -- so the thing it
# claims to watch reads as permanently healthy.
#
# The second assertion is the one that is specific to a model layer: the
# scoring SQL must exist exactly ONCE in the repo. Its first version omitted
# geo_code and visit_type from the join and fanned 2 forecasts out to 44 rows.
# A copy is a second chance to reintroduce that, and copies are how every fork
# on this platform started.

set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="mlops-metrics"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

RULES="$REPO_ROOT/platform/observability/prometheus/alerts/mlops.yml"
RULETEST="$REPO_ROOT/platform/observability/prometheus/rule_tests/mlops_test.yml"
EXPORTER="$REPO_ROOT/platform/mlops/pipeline_metrics.py"

echo "== mlops metrics: the layer that had no numbers =="
assert_file_exists "$EXPORTER" "the exporter exists"
assert_file_exists "$RULES" "mlops.yml exists"
assert_file_exists "$RULETEST" "and it has a synthetic control (ADR-0007: verify by evaluation)"

# Same temp-directory idiom as test_dataops_metrics.sh: `mktemp -t x.XXXXXX.ext`
# behaves differently on macOS and GNU, a temp dir with a fixed name inside
# behaves identically on both.
OUT_DIR="$(mktemp -d)"
OUT="$OUT_DIR/mlops.prom"
on_exit 'rm -rf "$OUT_DIR"'

MLOPS_PROM="$OUT" run_cmd python3 "$EXPORTER"
EXPORTER_RC=$LAST_RC
if [ "$EXPORTER_RC" -eq 78 ]; then
  echo "  SKIP  pilot database unreachable -- start it with platform/recover.sh"
  echo "        (LOUD skip: the rule/metric join below is UNVERIFIED)"
  suite_summary
  exit 0
fi
assert_rc 0 "the exporter runs"
assert_file_exists "$OUT" "and writes a .prom file"

# ---- the join: no rule may name a metric the exporter never emits ---------
MISSING=""
for M in $(grep -oE 'mlops_[a-z_]+' "$RULES" | sort -u); do
  grep -q "^$M[ {]" "$OUT" || MISSING="$MISSING $M"
done
assert_equals "" "$MISSING" \
  "every mlops_* metric named in an alert rule is actually emitted"

# ---- and the reverse direction, as a WARNING not a failure ---------------
# An emitted metric that no rule reads is not automatically waste: three of
# them exist to be graphed and to answer "how long has this been true",
# which is a dashboard question. But the count is printed so that a file
# quietly growing a dozen unread series is visible.
UNREAD=0
for M in $(grep -oE '^mlops_[a-z_]+' "$OUT" | sort -u); do
  grep -q "$M" "$RULES" || UNREAD=$((UNREAD + 1))
done
echo "  note: $UNREAD emitted metric name(s) are read by no alert rule (dashboard/board only)"

# ---- the standing facts must be MEASURED, because they cannot be alerts --
# t+1 has never beaten persistence and the deployed model beats it by 0.55%.
# Both would fire from the first evaluation and never clear, so mlops.yml
# deliberately does not alert on either. That decision is only safe if the
# numbers exist somewhere a human can see them.
run_cmd cat "$OUT"
assert_output_contains "mlops_horizon_gate_passed" \
  "whether a horizon has EVER passed the gate is a series, not a sentence"
assert_output_contains "mlops_deployed_margin_ratio" \
  "the deployed model's advantage over persistence is a series"
assert_output_contains "mlops_replacement_margin_ratio" \
  "and so is the policy threshold it should be compared against"

# The threshold is READ from the publisher, never retyped. A dashboard or an
# alert holding its own copy of 0.02 would eventually state a threshold the
# system does not enforce, and it would still render.
EMITTED_MARGIN="$(grep '^mlops_replacement_margin_ratio' "$OUT" | awk '{print $NF}')"
SOURCE_MARGIN="$(grep -oE '^REPLACEMENT_MARGIN = [0-9.]+' \
  "$REPO_ROOT/pilots/station2-twin/mlops/publish_forecast.py" | awk '{print $3}')"
assert_equals "$SOURCE_MARGIN" "$EMITTED_MARGIN" \
  "the emitted margin equals publish_forecast.py's REPLACEMENT_MARGIN, not a copy"

# ---- project and target are LABELS, on every series (ADR-0017) -----------
#
# A second project must not double the exporters, the dashboards or the alert
# rules; a second forecasting target must not take turns with the first in one
# slot. Both are labels. The assertion is that EVERY mlops_* series carries
# project -- a single unlabelled series is enough to make a $project dropdown
# silently show one project's number under another project's name.
# The generation timestamp is exempt and it is the ONLY exemption: it
# describes the FILE, not a project, and when this exporter loops over several
# projects into one .prom there will still be exactly one of it. Everything
# else is about a project's models and must say which project.
UNLABELLED="$(grep -E '^mlops_[a-z_]+' "$OUT" \
  | grep -v '^mlops_metrics_generated_timestamp_seconds' \
  | grep -vc 'project=' | tr -d ' ')"
assert_equals "0" "$UNLABELLED" \
  "every emitted mlops_* series carries a project label (except the file's own timestamp)"
run_cmd cat "$OUT"
assert_output_contains 'target="pct_ili"' \
  "the target is a label: influenza-like illness"
assert_output_contains 'target="pct_flu"' \
  "and influenza, which is a DIFFERENT disease in this warehouse"

# The two targets must not share a series. If they did, the newest rebuild
# would silently overwrite the other one's numbers -- which is exactly what
# happened to the replay artifacts before they were keyed on the target.
ILI_MAE="$(grep -c '^mlops_run_mae{.*target="pct_ili"' "$OUT" | tr -d ' ')"
FLU_MAE="$(grep -c '^mlops_run_mae{.*target="pct_flu"' "$OUT" | tr -d ' ')"
assert_equals "2" "$ILI_MAE" "both horizons are emitted for pct_ili"
assert_equals "2" "$FLU_MAE" "and both for pct_flu, in their own series"

# THE POST-HOC SCORE MUST BE ATTRIBUTABLE, NOT MERELY CORRECT.
#
# These three counted published forecasts by horizon only until 2026-09-09.
# The join underneath was already correct (T28), so the numbers were right --
# they just could not answer WHICH target the scored one belonged to. With one
# published disease that was invisible; with two, `scored=1, pending=3` is a
# sentence about no particular model. Nothing errors when a label is missing,
# which is why it is asserted rather than noticed.
for M in mlops_forecast_scored_total mlops_forecast_pending_total \
         mlops_forecast_beat_baseline_total; do
  BAD="$(grep -E "^${M}\{" "$OUT" | grep -vc 'target=' | tr -d ' ')"
  assert_equals "0" "$BAD" "$M carries the target it is scoring"
done

# ---- cardinality: no unbounded label -------------------------------------
# model_run_id grows without limit. As a LABEL it would make this the most
# expensive series in the database within a year; it is emitted as a value.
run_cmd grep -cE '\{[^}]*run_id=' "$OUT"
assert_rc 1 "no metric carries model_run_id as a LABEL (it is emitted as a value)"

# ---- the replay must never be confused with the live record --------------
#
# THIS IS THE ASSERTION THAT MATTERS MOST IN THIS SUITE.
#
# `mlops_forecast_scored_total` counts forecasts this platform really
# published: n=1. `mlops_policy_backtest_n` counts a simulation over history:
# n=383 at t+2. Both are honest. Added together they would be a track record
# that is part measurement and part replay -- and once both are numbers in a
# table, an estimate and a measurement are indistinguishable. The separation
# is enforced here rather than trusted to whoever writes the next panel.
run_cmd cat "$OUT"
if grep -q '^mlops_policy_backtest_n' "$OUT"; then
  assert_output_contains "mlops_policy_backtest_margin_ratio" \
    "the replay reports whether the SYSTEM would have beaten persistence"
  assert_output_contains 'mode="policy"' \
    "and says which question it asked (policy = the gate could switch family)"
  # Distinct prefixes, so no PromQL expression can sum one into the other by
  # matching a shared name.
  SHARED="$(grep -oE '^mlops_[a-z_]+' "$OUT" | sort -u \
    | grep -E '^mlops_forecast_' | grep -c 'backtest' | tr -d ' ')"
  assert_equals "0" "$SHARED" \
    "no metric name belongs to both the live record and the replay"
  # The replay artifact must carry its own timestamp. A replay produced from
  # last month's code and read as current is the same failure as a frozen
  # exporter, one level up.
  assert_output_contains "mlops_policy_backtest_generated_timestamp_seconds" \
    "the replay says when it ran, so a stale one is visible as stale"

  # THE POINT ESTIMATE MAY NOT TRAVEL ALONE.
  #
  # -3.60% reads as "the system is worse than persistence". The paired
  # bootstrap interval is [-11.92%, +3.43%] and INCLUDES ZERO, so the
  # defensible claim is "indistinguishable at n=383" -- a different sentence.
  # A panel or an alert given only the point estimate would silently overwrite
  # the second claim with the first, which is why the interval is asserted to
  # be emitted alongside it rather than left to whoever writes the next reader.
  if grep -q '^mlops_policy_backtest_margin_ratio' "$OUT"; then
    assert_output_contains "mlops_policy_backtest_margin_ci_low" \
      "the replay margin is emitted WITH its interval, never alone"
    assert_output_contains "mlops_policy_backtest_margin_ci_high" \
      "both bounds, so a reader can see whether the interval covers zero"
    assert_output_contains "mlops_policy_backtest_sign_test_p" \
      "and the win rate carries its p-value"
    assert_output_contains "mlops_policy_backtest_lag1_autocorrelation" \
      "and the independence assumption is stated as a number, not omitted"
  fi
else
  echo "  SKIP  no replay artifact in evidence/mlops -- run"
  echo "        pilots/station2-twin/mlops/run.sh policy_backtest.py --all-origins"
  echo "        (LOUD skip: the replay/live separation is UNVERIFIED)"
fi

# The window flag must reject a zero count rather than reading it as "no
# window". A flag whose zero silently means everything is how a bounded run
# becomes a full-corpus one by accident; unlimited gets its own name.
run_cmd grep -c 'def positive_int' \
  "$REPO_ROOT/pilots/station2-twin/mlops/policy_backtest.py"
assert_rc 0 "the window flag rejects a zero count rather than widening"
run_cmd grep -c 'all_origins' \
  "$REPO_ROOT/pilots/station2-twin/mlops/policy_backtest.py"
assert_rc 0 "and unlimited has its own explicit flag"

# The significance script must be deterministic: same artifact in, same numbers
# out. A resampling procedure with a moving seed would produce a confidence
# interval that changes on every run -- an interval nobody could cite, and one
# that would look like new information every time someone reloaded a panel.
run_cmd python3 "$REPO_ROOT/platform/mlops/replay_significance.py"
if [ "$LAST_RC" -eq 0 ]; then
  FIRST="$(cat "$LAST_STDOUT")"
  run_cmd python3 "$REPO_ROOT/platform/mlops/replay_significance.py"
  assert_equals "$FIRST" "$(cat "$LAST_STDOUT")" \
    "the bootstrap is deterministic: two runs give byte-identical intervals"
  assert_output_contains "95% CI (paired bs)" \
    "and it reports an interval, not just a point estimate"
fi

# ---- the scoring SQL exists exactly once ---------------------------------
# Anchored at the start of a line: this suite NAMES the constant a few
# characters below, and an unanchored search would count itself -- the same
# self-match that test_static.sh hit when its rule matched its own prose.
DEFS="$(repo_grep -l '^FORECAST_SCORE_SQL = ' "$REPO_ROOT/platform" \
  "$REPO_ROOT/pilots" 2>/dev/null | wc -l | tr -d ' ')"
assert_equals "1" "$DEFS" "the post-hoc scoring query is defined in exactly one file"
# Plain grep, not repo_grep: -r prefixes every count with the filename, so
# repo_grep -c over a single file returns "path:1" and not "1".
FANOUT="$(grep -c 'a.geo_code = fc.geo_code' "$REPO_ROOT/platform/statusdag/dag.py" \
  2>/dev/null | tr -d ' ')"
assert_equals "1" "$FANOUT" \
  "and it still joins on geo_code -- dropping it fanned 2 forecasts out to 44"

# ---- the board and the exporter must agree -------------------------------
# Two readers of one query. If they ever disagree, one of them is describing a
# platform that does not exist.
run_cmd python3 - "$OUT" <<'PY'
import sys, os, re
sys.path.insert(0, os.path.join(os.getcwd(), "platform", "statusdag"))
import dag
raw = dag.psql(dag.FORECAST_SCORE_SQL)
scored, pending, won = dag.score_totals(raw)
text = open(sys.argv[1], encoding="utf-8").read()
def total(metric):
    return sum(int(v) for v in re.findall(r"^%s\{[^}]*\} (\d+)$" % metric,
                                          text, re.M))
print("BOARD scored=%d pending=%d won=%d" % (scored, pending, won))
print("PROM  scored=%d pending=%d won=%d" % (
    total("mlops_forecast_scored_total"),
    total("mlops_forecast_pending_total"),
    total("mlops_forecast_beat_baseline_total")))
PY
assert_rc 0 "the board's scoring and the exporter's can both be computed"
BOARD_LINE="$(grep '^BOARD ' "$LAST_STDOUT" | sed 's/^BOARD //')"
PROM_LINE="$(grep '^PROM ' "$LAST_STDOUT" | sed 's/^PROM  *//')"
assert_equals "$BOARD_LINE" "$PROM_LINE" \
  "the board's sentence and the exporter's series are the same measurement"

# ---- the rules must EVALUATE, not merely parse (ADR-0007) ----------------
PROMDIR="$REPO_ROOT/platform/observability/prometheus"
promtool() {
  docker run --rm -v "$PROMDIR:/p:ro" --entrypoint promtool "$(prom_image)" "$@"
}
run_cmd promtool check rules /p/alerts/mlops.yml
assert_rc 0 "promtool parses the rules"
run_cmd promtool test rules /p/rule_tests/mlops_test.yml
assert_rc 0 "and every synthetic case evaluates as written"
assert_output_contains "SUCCESS" "including the two that must stay SILENT"

# ---- the synthetic control must be able to fail -------------------------
# A control that has never been seen to fail and one that cannot fail produce
# the same output. Mutate the comparison so a tie no longer counts as losing;
# the boundary case must go red. Restored in a trap and the restore VERIFIED.
BACKUP="$(mktemp -t mlops_rules.XXXXXX)"
cp "$RULES" "$BACKUP"
restore_rules() { [ -f "$BACKUP" ] && cp "$BACKUP" "$RULES"; }
on_exit restore_rules
sed_i 's#expr: mlops_deployed_margin_ratio <= 0#expr: mlops_deployed_margin_ratio < 0#' "$RULES"
promtool test rules /p/rule_tests/mlops_test.yml >/dev/null 2>&1
assert_equals "1" "$?" \
  "changing <= to < makes the tie case go red -- the control can fail"
restore_rules
run_cmd cmp "$BACKUP" "$RULES"
assert_rc 0 "the mutation was restored byte-for-byte"
rm -f "$BACKUP"

suite_summary

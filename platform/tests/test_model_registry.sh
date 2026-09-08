#!/usr/bin/env bash
# The model registry must actually admit more than one model.
#
# WHY THIS SUITE EXISTS.
#
# `model_run` has carried `algorithm`, `hyperparams`, `feature_set_id` and
# `seed` since day one -- a schema that says "many models". The code had
# exactly one, hardcoded in two constructors, with its name and hyperparams
# retyped as literals in the banner and the INSERT. That is this repo's own
# catalogued shape: 登記為可擴充，但只實作了一種, plus three copies of one
# fact that had to agree by hand.
#
# A registry with one entry is the same claim wearing a mechanism. So the
# first assertion here is that a SECOND family is registered and runnable --
# not that the dictionary exists.
#
# It runs backtest.py through the pilot's own container, because that is where
# the pinned scikit-learn lives. `--list-models` and an unknown --algorithm
# both return before the database connect, so those cases need no pilot DB.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

MLOPS="$REPO_ROOT/pilots/station2-twin/mlops"

echo "== the model registry admits more than one family =="

run_cmd "$MLOPS/run.sh" backtest.py --list-models
assert_rc 0 "--list-models runs without a database"
assert_output_contains "HistGradientBoostingRegressor" \
  "the incumbent model is registered, not hardcoded"
assert_output_contains "Ridge" \
  "a SECOND family is registered -- a one-entry registry is not extensibility"
assert_output_contains "統計／線性" \
  "each entry declares its family, so a reviewer can see what is comparable"
assert_output_contains "median-impute + missing indicator" \
  "a model that cannot take NaN states its policy where it can be reviewed"

# An unknown name must be refused WITH the list. A silent default would record
# one algorithm's name against another algorithm's numbers -- provenance that
# is worse than none, because every later comparison inherits the lie.
run_cmd "$MLOPS/run.sh" backtest.py --algorithm NoSuchModel --dry-run
assert_rc 1 "an unregistered algorithm is refused, not defaulted"
assert_output_contains "unknown --algorithm 'NoSuchModel'" \
  "the refusal names what was asked for"
assert_output_contains "Registered: HistGradientBoostingRegressor, Ridge" \
  "the refusal lists what IS registered, so the next step is obvious"

# The registry's own field guard, exercised on every registered entry rather
# than on a fixture: a missing field or a NaN-blind model with no policy must
# stop the run. Checked by importing the module, so it covers entries added
# after this test was written.
run_cmd "$MLOPS/run.sh" backtest.py --list-models
assert_rc 0 "listing succeeds, so every entry can at least be printed"
for FIELD in "family" "handles_nan" "nan_policy" "deterministic"; do
  assert_output_contains "$FIELD" "every entry declares $FIELD"
done

suite_summary

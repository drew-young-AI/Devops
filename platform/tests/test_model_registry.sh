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

# EVERY ASSERTION BELOW NEEDS A CONTAINER RUNTIME, so the absence of one is
# stated rather than reported as a defect (2026-09-09).
#
# This suite is listed in tier 1 -- "no dependencies" -- and that was wrong the
# day it was written: `run.sh` builds and runs the pilot image, so the registry
# it interrogates lives inside a container. On the development machine and on
# GitHub's runners Docker is always there, so the mis-declaration was invisible
# for as long as those were the only two places it ran.
#
# The second machine has no Docker at all: ubu runs k3s over containerd. The
# suite reported four red assertions whose real cause was
# `docker: command not found`, which is not a statement about the registry.
#
# The repository's own convention for this is SKIP plus UNVERIFIED (see
# test_dataops_metrics.sh and test_exporter_freshness.sh): a dependency that is
# absent is a different claim from a contract that is broken, and collapsing
# the two teaches people to ignore the colour.
if ! command -v docker >/dev/null 2>&1 || ! timeout 20 docker info >/dev/null 2>&1; then
  echo "  SKIP  no container runtime -- the model registry is UNVERIFIED here."
  echo "        Every check in this suite runs inside the pilot image; without"
  echo "        one, 'the registry admits two families' cannot be asked at all."
  suite_summary
  exit 0
fi

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

# The registry's own field guard, exercised on every registered entry rather
# than on a fixture: a missing field or a NaN-blind model with no policy must
# stop the run. It covers entries added after this test was written, because
# --list-models validates and BUILDS every entry before printing any of it.
#
# These assert against the --list-models ABOVE rather than running it a second
# time. Each `run.sh` call is a `docker run` against the pilot image, measured
# at ~12s, and the suite was 62s -- two identical container starts of which
# bought nothing. assert_output_contains reads the LAST run_cmd, so this block
# must stay immediately under one; see the same warning in
# test_dataops_metrics.sh.
for FIELD in "family" "handles_nan" "nan_policy" "deterministic"; do
  assert_output_contains "$FIELD" "every entry declares $FIELD"
done


# An unknown name must be refused WITH the list. A silent default would record
# one algorithm's name against another algorithm's numbers -- provenance that
# is worse than none, because every later comparison inherits the lie.
run_cmd "$MLOPS/run.sh" backtest.py --algorithm NoSuchModel --dry-run
assert_rc 1 "an unregistered algorithm is refused, not defaulted"
assert_output_contains "unknown --algorithm 'NoSuchModel'" \
  "the refusal names what was asked for"
assert_output_contains "Registered: HistGradientBoostingRegressor, Ridge" \
  "the refusal lists what IS registered, so the next step is obvious"


echo ""
echo "== the contract is shared, not copied =="

# One implementation, one place. Every fork this repo has found started as a
# second copy that was correct on the day it was made: the settle rule (two
# copies, with the test suite certifying the one nobody ran) and the
# publisher's estimator (a HistGradientBoostingRegressor constructed by name
# whatever algorithm had actually won). So the COUNT is asserted, not just the
# behaviour -- behaviour is what agrees right up until it does not.
DEFS="$(repo_grep -l '^REQUIRED_FIELDS = {' "$REPO_ROOT/platform" "$REPO_ROOT/pilots" 2>/dev/null | wc -l | tr -d ' ')"
assert_equals "1" "$DEFS" \
  "the registry contract is defined in exactly one file"
assert_file_exists "$REPO_ROOT/platform/mlops/model_registry.py" \
  "and that file is at the platform level, where a second pilot can reach it"

# The publisher must not be able to construct an estimator at all. It used to
# import HistGradientBoostingRegressor directly and build one regardless of
# which algorithm the winning run had used -- a Ridge run that won its horizon
# would have been published as an HGB fit carrying the Ridge run's id and MAE.
run_cmd grep -nE '^(import|from) sklearn' "$MLOPS/publish_forecast.py"
assert_rc 1 "the publisher imports no estimator: it can only refit through the registry"

# One fitting path. A second `.fit(` in the training script would mean the
# folds and the final refit had drifted apart again.
FITS="$(grep -c '\.fit(' "$MLOPS/backtest.py" | tr -d ' ')"
assert_equals "1" "$FITS" \
  "backtest.py fits in exactly one place (fit_one), used by folds and by the refit"

echo ""
echo "== the replacement rule is exercised, not described =="

# --explain-gate runs the real decision function over fixture cases and needs
# no database. A rule that is only documented is a rule nobody has ever run.
run_cmd "$MLOPS/run.sh" publish_forecast.py --explain-gate
assert_rc 0 "--explain-gate runs without a database"
for DECISION in BOOTSTRAP REPLACE KEEP REFRESH INCOMPARABLE REFUSED; do
  assert_output_contains "$DECISION" \
    "the rule has a worked case for $DECISION"
done
assert_output_contains "inside the 2% margin" \
  "a challenger better by less than the margin does NOT replace the incumbent"
assert_output_contains "CURRENT feature set" \
  "the comparison universe is stated: an MAE from another feature set is not the same quantity"

# The margin is one number in one file. The board prints it by READING that
# file (statusdag/dag.py replacement_margin), so a second literal anywhere
# would be a threshold that can drift from the one actually enforced.
MARGINS="$(repo_grep -l '^REPLACEMENT_MARGIN = ' "$REPO_ROOT/platform" "$REPO_ROOT/pilots" 2>/dev/null | wc -l | tr -d ' ')"
assert_equals "1" "$MARGINS" \
  "REPLACEMENT_MARGIN is defined exactly once in the repo"

echo ""
echo "== mutation: an entry that returns a FITTED estimator must be refused =="

# WHY A MUTATION AND NOT A FIXTURE.
#
# check_buildable exists to catch a build() that hands back an already-fitted
# object -- which then scores perfectly normally, with the test rows inside
# the fit. No registered entry does that, so nothing exercises the check, and
# a guard that is never exercised is indistinguishable from one that does not
# work.
#
# The file is restored in a trap and the restore is VERIFIED with cmp against
# an untouched copy: an unrestored mutation would leave a broken registry in
# the repo, which is the one outcome worse than not testing this at all.
# `name.XXXXXX`: GNU mktemp refuses fewer than three X and prints nothing,
# so BACKUP was empty on Linux -- `cp` wrote to "", and the restore check
# failed with `cmp: : No such file or directory`. The mutation itself was
# fine; the SAFETY NET was the part that did not exist on that platform.
BACKUP="$(mktemp -t backtest_orig.XXXXXX)"
cp "$MLOPS/backtest.py" "$BACKUP"
# on_exit, not `trap ... EXIT`: a bare trap REPLACES lib.sh's own exit handler
# and silently discards its sandbox cleanup. Guarded on the backup still
# existing, so that after the explicit restore below (which deletes it) the
# handler is a no-op rather than a failed cp.
restore_backtest() { [ -f "$BACKUP" ] && cp "$BACKUP" "$MLOPS/backtest.py"; }
on_exit restore_backtest

python3 "$SUITE_DIR/mutate_registry.py" "$MLOPS/backtest.py"
run_cmd "$MLOPS/run.sh" backtest.py --list-models
assert_rc 1 "listing REFUSES a registry containing a pre-fitted estimator"
assert_output_contains "ALREADY FITTED" \
  "the refusal names the defect rather than failing generically"
assert_output_contains "MutantPreFitted" \
  "and names which entry"

restore_backtest
run_cmd cmp "$BACKUP" "$MLOPS/backtest.py"
assert_rc 0 "the mutation was restored byte-for-byte (cmp against the pre-mutation copy)"
rm -f "$BACKUP"

suite_summary

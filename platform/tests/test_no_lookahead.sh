#!/usr/bin/env bash
# The feature set must not be able to see the future.
#
# WHY A COMMENT IS NOT ENOUGH HERE.
#
# build_features.py claims every feature is strictly backward-looking. That
# claim is exactly the kind this platform has been wrong about repeatedly: the
# Vault pool "fetched a fresh credential" and did not; the duplicate check
# "caught conflicts" and did not. A leak is worse than either, because it does
# not fail -- it makes the backtest look good and the production model look
# broken, months later, with no error anywhere.
#
# THE TEST
#
# Rebuild the feature set over a TRUNCATED series and require every retained row
# to be byte-identical to the full build. If any feature peeked forward, removing
# the future would change the past and the comparison fails.
#
# This is a property test, not an example test: it does not need to know WHICH
# feature leaks, only that adding future data cannot alter a past row. It
# therefore also catches a leak added tomorrow by someone who never read this.
#
# It runs against a scratch feature_set and deletes it afterwards in a trap, so
# a failure mid-run cannot leave a truncated set behind for backtest.py to pick
# up as "the latest" -- which would silently train the next model on half the
# data.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MLOPS="$ROOT/pilots/station2-twin/mlops"
PGPASSWORD="${PGPASSWORD:-twin-bootstrap}"
export PGPASSWORD
# The cutoff is DERIVED from the data, not written as a literal. The first
# version hardcoded 500, on the assumption that time_period.seq is an ordinal.
# It is not -- it is encoded year*100 + week (201601..202632), so `seq <= 500`
# matched zero rows and the truncated build produced nothing. A literal here
# would silently rot again the moment the series grows.
KEEP_ROWS=500

q() {
  docker run --rm -i -e PGPASSWORD="$PGPASSWORD" --network host postgres:16-alpine \
    psql -h 127.0.0.1 -p 15432 -U twin -d twin -v ON_ERROR_STOP=1 -qtAX -c "$1" 2>&1
}

echo "=== no-lookahead property ==="

if ! q 'SELECT 1' >/dev/null 2>&1; then
  echo "  FAIL  database unreachable -- this is a failure, not a skip" >&2
  exit 1
fi

FULL_ID="$(q "SELECT feature_set_id FROM feature_set
              WHERE params->>'max_seq' IS NULL
              ORDER BY built_at DESC LIMIT 1" | tr -d '[:space:]')"
if [ -z "$FULL_ID" ]; then
  echo "  FAIL  no full feature_set found -- run mlops/build_features.py first" >&2
  exit 1
fi
echo "  full feature_set_id=$FULL_ID"

TRUNCATE_AT="$(q "SELECT seq FROM feature_row WHERE feature_set_id = $FULL_ID
                  ORDER BY seq OFFSET $((KEEP_ROWS - 1)) LIMIT 1" | tr -d '[:space:]')"
if [ -z "$TRUNCATE_AT" ]; then
  echo "  FAIL  the full feature set has fewer than $KEEP_ROWS rows; the" >&2
  echo "        truncation would remove nothing and the test would be vacuous" >&2
  exit 1
fi
echo "  truncating after row $KEEP_ROWS (seq $TRUNCATE_AT)"

cleanup() {
  [ -n "${TRUNC_ID:-}" ] && q "DELETE FROM feature_set WHERE feature_set_id = $TRUNC_ID" >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

# The truncated build. --max-seq is recorded in params, so the natural key
# differs and this cannot collide with the full set.
if ! "$MLOPS/run.sh" build_features.py --max-seq "$TRUNCATE_AT" >/dev/null 2>&1; then
  echo "  FAIL  truncated build_features.py did not succeed" >&2
  exit 1
fi
TRUNC_ID="$(q "SELECT feature_set_id FROM feature_set
                WHERE (params->>'max_seq')::int = $TRUNCATE_AT
                ORDER BY built_at DESC LIMIT 1" | tr -d '[:space:]')"
if [ -z "$TRUNC_ID" ] || [ "$TRUNC_ID" = "$FULL_ID" ]; then
  echo "  FAIL  truncated build did not produce a distinct feature_set" >&2
  exit 1
fi
echo "  truncated feature_set_id=$TRUNC_ID (seq <= $TRUNCATE_AT)"

# Compare every feature column on the overlapping rows.
#
# y_next_1 and y_next_2 are EXCLUDED and that is not a loophole: they are the
# LABELS, and a label is by definition the future. Their absence at the end of a
# truncated series is correct behaviour, not a leak. Every FEATURE is compared.
DIFFS="$(q "
  SELECT count(*) FROM feature_row a
  JOIN feature_row b ON b.seq = a.seq
  WHERE a.feature_set_id = $FULL_ID
    AND b.feature_set_id = $TRUNC_ID
    AND (a.y IS DISTINCT FROM b.y
      OR a.lag_1 IS DISTINCT FROM b.lag_1
      OR a.lag_2 IS DISTINCT FROM b.lag_2
      OR a.lag_3 IS DISTINCT FROM b.lag_3
      OR a.lag_4 IS DISTINCT FROM b.lag_4
      OR a.delta_1 IS DISTINCT FROM b.delta_1
      OR a.same_week_last_year IS DISTINCT FROM b.same_week_last_year
      OR a.week_of_year IS DISTINCT FROM b.week_of_year
      OR a.denominator_lag_1 IS DISTINCT FROM b.denominator_lag_1
      OR a.covid_lag_1 IS DISTINCT FROM b.covid_lag_1
      OR a.entero_lag_1 IS DISTINCT FROM b.entero_lag_1
      OR a.age_share_0_6_lag_1 IS DISTINCT FROM b.age_share_0_6_lag_1)
" | tr -d '[:space:]')"

OVERLAP="$(q "SELECT count(*) FROM feature_row a JOIN feature_row b ON b.seq = a.seq
              WHERE a.feature_set_id = $FULL_ID AND b.feature_set_id = $TRUNC_ID" \
           | tr -d '[:space:]')"

echo "  compared $OVERLAP overlapping rows"

# An empty overlap would make the test vacuously pass -- the classic way a
# property test stops testing anything while still reporting success.
if [ "${OVERLAP:-0}" -lt 100 ]; then
  echo "  FAIL  only $OVERLAP overlapping rows; the comparison is vacuous" >&2
  exit 1
fi

if [ "$DIFFS" != "0" ]; then
  echo "  FAIL  $DIFFS row(s) CHANGED when future data was removed." >&2
  echo "        A feature is reading forward in time. The backtest score is" >&2
  echo "        invalid until this is found." >&2
  q "SELECT a.seq, a.epi_year, a.epi_week FROM feature_row a
     JOIN feature_row b ON b.seq = a.seq
     WHERE a.feature_set_id = $FULL_ID AND b.feature_set_id = $TRUNC_ID
       AND (a.lag_1 IS DISTINCT FROM b.lag_1
         OR a.same_week_last_year IS DISTINCT FROM b.same_week_last_year
         OR a.covid_lag_1 IS DISTINCT FROM b.covid_lag_1)
     LIMIT 5" >&2
  exit 1
fi

echo "  PASS  no feature changed when the trailing weeks were removed"
echo ""
echo "  1 passed, 0 failed"

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

# ONE PASS PER TARGET.
#
# This suite took "the newest full feature set" and rebuilt a truncated one
# with build_features.py's DEFAULT disease. That was the same thing while one
# target existed. On 2026-09-09 a second target (influenza) was added, the
# newest full set became the flu one, and the truncated rebuild was still ILI
# -- so the comparison was flu against ILI and reported 500 changed rows: a
# LOOKAHEAD FAILURE that was not a lookahead at all.
#
# A false positive is the more corrosive kind of guard failure. A guard that
# fails on correct input is one people learn to argue with, and the argument
# wins eventually.
#
# So: each target is checked against a truncated build OF THAT TARGET, and the
# suite fails if it finds no targets at all.
TARGETS="$(q "SELECT DISTINCT d.code FROM feature_set fs
              JOIN disease d ON d.disease_id = fs.disease_id
              WHERE fs.params->>'max_seq' IS NULL ORDER BY 1")"
if [ -z "$TARGETS" ]; then
  echo "  FAIL  no full feature_set found -- run mlops/build_features.py first" >&2
  exit 1
fi

# THE COLUMN LIST IS DERIVED, NOT TYPED.
#
# It used to be eleven column names written out by hand, and migrations 017 and
# 018 added five more that nobody added here -- so the newest features, the
# ones most likely to have a defect, were the only ones NOT checked. Reading
# the columns from the catalogue means a column added tomorrow is covered
# tonight.
#
# y_next_1 and y_next_2 are excluded and that is not a loophole: they are the
# LABELS, and a label is by definition the future. Their absence at the end of
# a truncated series is correct behaviour. feature_set_id and seq are the join
# key. Everything else is a FEATURE and is compared.
COLS="$(q "SELECT string_agg(format('a.%I IS DISTINCT FROM b.%I', column_name,
                                    column_name), ' OR ' ORDER BY column_name)
           FROM information_schema.columns
           WHERE table_name = 'feature_row'
             AND column_name NOT IN ('feature_set_id','seq','y_next_1','y_next_2')")"
NCOLS="$(q "SELECT count(*) FROM information_schema.columns
            WHERE table_name = 'feature_row'
              AND column_name NOT IN ('feature_set_id','seq','y_next_1','y_next_2')" \
          | tr -d '[:space:]')"
if [ "${NCOLS:-0}" -lt 10 ]; then
  echo "  FAIL  only $NCOLS feature column(s) found; the comparison would be" >&2
  echo "        nearly vacuous. A derived list that derives nothing is worse" >&2
  echo "        than a typed one, because it looks complete." >&2
  exit 1
fi
echo "  comparing $NCOLS feature column(s), derived from the catalogue"

TRUNC_IDS=""
cleanup() {
  for t in $TRUNC_IDS; do
    q "DELETE FROM feature_set WHERE feature_set_id = $t" >/dev/null 2>&1
  done
  return 0
}
# A RAW trap: this suite does not source lib.sh (own counters), so on_exit
# would be an undefined command that registers nothing. See the note in
# test_backup_coverage.sh.
trap cleanup EXIT

FAILED=0
for DISEASE in $TARGETS; do
  echo ""
  echo "  --- target: $DISEASE"
  FULL_ID="$(q "SELECT fs.feature_set_id FROM feature_set fs
                JOIN disease d ON d.disease_id = fs.disease_id
                WHERE fs.params->>'max_seq' IS NULL AND d.code = '$DISEASE'
                ORDER BY fs.built_at DESC LIMIT 1" | tr -d '[:space:]')"
  [ -n "$FULL_ID" ] || { echo "  FAIL  no full set for $DISEASE" >&2; FAILED=1; continue; }

  TRUNCATE_AT="$(q "SELECT seq FROM feature_row WHERE feature_set_id = $FULL_ID
                    ORDER BY seq OFFSET $((KEEP_ROWS - 1)) LIMIT 1" | tr -d '[:space:]')"
  if [ -z "$TRUNCATE_AT" ]; then
    echo "  FAIL  $DISEASE has fewer than $KEEP_ROWS rows; the truncation" >&2
    echo "        would remove nothing and the check would be vacuous" >&2
    FAILED=1; continue
  fi
  echo "      full=$FULL_ID  truncating after row $KEEP_ROWS (seq $TRUNCATE_AT)"

  # --disease is passed EXPLICITLY. That single omission is what made this
  # suite compare two different diseases and call it a lookahead.
  if ! "$MLOPS/run.sh" build_features.py --disease "$DISEASE" \
        --max-seq "$TRUNCATE_AT" >/dev/null 2>&1; then
    echo "  FAIL  truncated build_features.py did not succeed for $DISEASE" >&2
    FAILED=1; continue
  fi
  TRUNC_ID="$(q "SELECT fs.feature_set_id FROM feature_set fs
                 JOIN disease d ON d.disease_id = fs.disease_id
                 WHERE (fs.params->>'max_seq')::int = $TRUNCATE_AT
                   AND d.code = '$DISEASE'
                 ORDER BY fs.built_at DESC LIMIT 1" | tr -d '[:space:]')"
  if [ -z "$TRUNC_ID" ] || [ "$TRUNC_ID" = "$FULL_ID" ]; then
    echo "  FAIL  truncated build did not produce a distinct feature_set" >&2
    FAILED=1; continue
  fi
  TRUNC_IDS="$TRUNC_IDS $TRUNC_ID"
  echo "      truncated=$TRUNC_ID (seq <= $TRUNCATE_AT)"

  OVERLAP="$(q "SELECT count(*) FROM feature_row a JOIN feature_row b ON b.seq = a.seq
                WHERE a.feature_set_id = $FULL_ID AND b.feature_set_id = $TRUNC_ID" \
             | tr -d '[:space:]')"
  # An empty overlap would make the check vacuously pass -- the classic way a
  # property test stops testing anything while still reporting success.
  if [ "${OVERLAP:-0}" -lt 100 ]; then
    echo "  FAIL  only $OVERLAP overlapping rows for $DISEASE; vacuous" >&2
    FAILED=1; continue
  fi

  DIFFS="$(q "SELECT count(*) FROM feature_row a
              JOIN feature_row b ON b.seq = a.seq
              WHERE a.feature_set_id = $FULL_ID
                AND b.feature_set_id = $TRUNC_ID
                AND ($COLS)" | tr -d '[:space:]')"
  if [ "$DIFFS" != "0" ]; then
    echo "  FAIL  $DIFFS row(s) CHANGED for $DISEASE when future data was" >&2
    echo "        removed. A feature is reading forward in time. The backtest" >&2
    echo "        score is invalid until this is found." >&2
    q "SELECT a.seq, a.epi_year, a.epi_week FROM feature_row a
       JOIN feature_row b ON b.seq = a.seq
       WHERE a.feature_set_id = $FULL_ID AND b.feature_set_id = $TRUNC_ID
         AND ($COLS) LIMIT 5" >&2
    FAILED=1; continue
  fi
  echo "      PASS  $OVERLAP rows, $NCOLS columns, nothing changed"
done

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
echo ""
echo "  PASS  no feature changed when the trailing weeks were removed"
echo ""
# The counter is the number of TARGETS checked, not a constant 1. run_all.sh
# reads this line, and a suite that always says "1 passed" cannot show that it
# started covering a second target.
N="$(printf '%s\n' $TARGETS | wc -l | tr -d ' ')"
echo "  $N passed, 0 failed"

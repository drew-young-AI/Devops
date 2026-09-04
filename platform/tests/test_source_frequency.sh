#!/usr/bin/env bash
# Every ingested source has a recorded publication cadence, with provenance.
#
# WHY THIS SUITE EXISTS.
#
# docs/Backlog.md §20 proposed per-source freshness thresholds and supplied a
# table of "actual update frequency" for five sources. When the publishers'
# catalogues were finally queried on 2026-09-03, one of the five was wrong by
# two orders of magnitude -- cdc-tb-caremag was recorded as annual and is
# declared `day`, on a dataset literally titled 結核病每日縣市鄉鎮管理中個案.
#
# The estimate had sat in the backlog for weeks looking exactly like a
# measurement, because once both are numbers in a markdown table nothing
# distinguishes them. So the table this suite guards records not just the
# interval but WHERE IT CAME FROM, and a row without provenance fails.
#
# The completeness half matters more than the values: a source with ingest
# history and no row is how a source ends up with no cadence, no threshold, and
# nobody noticing when it stops.

set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="source-frequency"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== source cadence: a number without provenance is an estimate =="

TABLE="$REPO_ROOT/pilots/station2-twin/ingest/source_frequency.json"
BUILDER="$REPO_ROOT/platform/dataops/refresh_source_frequency.py"
CHECK="$SUITE_DIR/source_frequency_check.py"

assert_file_exists "$TABLE" "the cadence table exists"
assert_file_exists "$BUILDER" "and is regenerable, not hand-maintained"
assert_file_exists "$CHECK" "source_frequency_check.py exists"

run_cmd python3 "$CHECK" --table "$TABLE"
assert_rc 0 "every row carries provenance, and every ingested source has a row"
sed 's/^/  /' "$LAST_STDOUT"
[ -s "$LAST_STDERR" ] && sed 's/^/  /' "$LAST_STDERR"

# ---- the checker must be able to object ------------------------------------
# Four synthetic defects, each a real way this table has degraded or could:
# a typed-in number, a missing justification, a source that appeared and was
# never recorded, and a claim of evidence with nothing behind it.
FIX="$(mktemp -d)"
on_exit 'rm -rf "$FIX"'

fixture() {  # <python expression mutating `t`> -> writes $FIX/table.json
  python3 -c "
import json, sys
t = json.load(open(sys.argv[1]))
$1
json.dump(t, open(sys.argv[2], 'w'), ensure_ascii=False, indent=2)
" "$TABLE" "$FIX/table.json"
}

expect_reject() {  # <description>
  python3 "$CHECK" --table "$FIX/table.json" >/dev/null 2>&1
  if [ $? -ne 0 ]; then _pass "catches: $1"; else _fail "catches: $1" "rc=0"; fi
}

# The unmodified copy must pass, or the four rejections below prove nothing.
fixture "pass"
run_cmd python3 "$CHECK" --table "$FIX/table.json"
assert_rc 0 "does not cry wolf: an unmodified copy passes"

fixture "k = sorted(t)[0]; t[k]['seconds'] = 1234567"
expect_reject "an interval no evidence kind produces (someone typed a number in)"

fixture "k = sorted(t)[0]; t[k]['evidence'] = ''"
expect_reject "a row whose evidence line is empty"

fixture "k = sorted(t)[0]; t[k]['source'] = 'because it feels right'"
expect_reject "a provenance kind outside the closed set"

fixture "k = [x for x in t if t[x]['seconds'] is None]; k = k[0] if k else sorted(t)[0]; t[k]['source'] = 'declared'"
expect_reject "a row claiming declared evidence with no interval behind it"

# ---- completeness against the live database --------------------------------
# The half that needs the database. A loud skip, not a silent one: without it
# all that has been shown is that the rows present are well-formed, not that
# the rows that should be present are.
if timeout 20 docker exec station2-twin-db-1 true >/dev/null 2>&1; then
  run_cmd python3 "$CHECK" --table "$TABLE" --require-db
  assert_rc 0 "no source has ingest history without a row in the table"

  # And the reverse control: a source removed from the table must be noticed.
  fixture "k = sorted(t)[0]; del t[k]"
  python3 "$CHECK" --table "$FIX/table.json" --require-db >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    _pass "catches: an ingested source missing from the table"
  else
    _fail "catches: an ingested source missing from the table" "rc=0"
  fi
else
  echo "  SKIP  database unreachable -- completeness against ingest_runs is"
  echo "        UNVERIFIED; only the shape of the rows present was checked"
fi

suite_summary

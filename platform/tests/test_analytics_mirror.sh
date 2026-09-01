#!/usr/bin/env bash
# The analytical mirror is 400x faster than the database it copies. That speed
# is the reason it exists AND the reason it is dangerous: a fast answer is
# trusted, so a mirror that is quietly out of date is worse than the slow query
# it replaced.
#
# Everything below tests the same one property from different angles: THE
# MIRROR MUST REFUSE TO ANSWER WHEN IT IS NOT CURRENT. Refuse, not warn -- a
# warning printed above a number gets read as a number.
#
# The staleness checks are verified by deliberately breaking the manifest and
# confirming the refusal, then restoring. Nothing is left modified: the restore
# runs in a trap so it happens even if an assertion aborts (CLAUDE.md 5c).

set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="analytics-mirror"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== analytics mirror: freshness is the whole contract =="

RUN="$REPO_ROOT/platform/analytics/run.sh"
MANIFEST="$REPO_ROOT/evidence/analytics/mirror_manifest.json"
MIRROR_DIR="$REPO_ROOT/platform/analytics/mirror"

assert_file_exists "$RUN" "analytics/run.sh exists"

if [ ! -x "$REPO_ROOT/platform/analytics/venv/bin/python" ]; then
  echo "  SKIP  analytics venv not built -- run platform/analytics/setup.sh"
  echo "        (LOUD skip: the freshness contract below is UNVERIFIED)"
  suite_summary
  exit 0
fi

# ---- not-built is a distinct state, not a failure -------------------------
if [ ! -f "$MANIFEST" ]; then
  run_cmd "$RUN" check
  assert_rc 78 "an unbuilt mirror reports not-configured (78), not success"
  echo "  SKIP  no mirror to test further; run: platform/analytics/run.sh build"
  suite_summary
  exit 0
fi

# Portable temp file. `mktemp -t name.XXXXXX.ext` works on macOS and is
# rejected by GNU coreutils ("Invalid argument"), which requires the X's to end
# the template -- and macOS does not even substitute them, leaving a literal
# "XXXXXX" in the name. A temp DIRECTORY with a fixed filename inside is the one
# form that behaves identically on both, keeps the extension the tool needs, and
# has no create-then-rename race.
BACKUP_DIR="$(mktemp -d)"
BACKUP="$BACKUP_DIR/mirror_manifest.json"
cp "$MANIFEST" "$BACKUP"
HELD=""
restore() {
  cp "$BACKUP" "$MANIFEST"
  [ -n "$HELD" ] && [ -f "$HELD" ] && mv "$HELD" "$MIRROR_DIR/fact.parquet"
  rm -rf "$BACKUP_DIR"
}
trap restore EXIT

# ---- POSITIVE FIRST. A refusal proves nothing if nothing ever succeeds. ----
run_cmd "$RUN" check
assert_rc 0 "a current mirror reports current"

run_cmd "$RUN" query "SELECT count(*) AS n FROM fact"
assert_rc 0 "a current mirror answers queries"

# The mirror must agree with the source it claims to mirror. Comparing the
# manifest to itself would pass on a mirror built from nothing.
MIRROR_ROWS="$(python3 -c "
import json; print(json.load(open('$MANIFEST'))['tables']['fact']['rows'])")"
DB_ROWS="$(docker exec station2-twin-db-1 psql -U twin -d twin -At \
  -c 'SELECT count(*) FROM surveillance_fact' 2>/dev/null | tr -d '[:space:]')"
assert_equals "$DB_ROWS" "$MIRROR_ROWS" "mirror row count equals the database's"

# ---- NEGATIVE. Each one breaks the manifest, then restores it. -------------
mutate() {   # mutate <python-expression-on-d>
  python3 -c "
import json
p = '$MANIFEST'
d = json.load(open(p))
$1
json.dump(d, open(p, 'w'))"
}

mutate "d['watermark']['max_ingest_id'] -= 1"
run_cmd "$RUN" query "SELECT 1"
assert_rc 1 "a mirror behind the ingest watermark refuses to answer"
assert_output_contains "STALE" "and says why"
cp "$BACKUP" "$MANIFEST"

mutate "d['watermark']['fact_rows'] += 1"
run_cmd "$RUN" query "SELECT 1"
assert_rc 1 "a mirror whose row count disagrees refuses to answer"
cp "$BACKUP" "$MANIFEST"

mutate "d['watermark']['max_fetched_at'] = '1999-01-01T00:00:00+00:00'"
run_cmd "$RUN" query "SELECT 1"
assert_rc 1 "a mirror with a stale fetch timestamp refuses to answer"
cp "$BACKUP" "$MANIFEST"

# A missing Parquet file is not-built, not stale: the distinction matters
# because one is fixed by rebuilding and the other by setting up.
HELD="$(mktemp -t fact_parquet.XXXXXX)"
mv "$MIRROR_DIR/fact.parquet" "$HELD"
run_cmd "$RUN" query "SELECT 1"
assert_rc 78 "a mirror missing its Parquet reports not-built (78)"
mv "$HELD" "$MIRROR_DIR/fact.parquet"; HELD=""

# ---- the restore actually restored ---------------------------------------
run_cmd "$RUN" check
assert_rc 0 "the mirror is current again after every mutation"

suite_summary

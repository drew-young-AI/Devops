#!/usr/bin/env bash
# Reproduce the numbers in decisions/0001. One command, no arguments, because a
# rerun instruction with three environment variables to set is a rerun
# instruction nobody follows -- and then the number gets re-estimated instead.
#
# Writes Parquet into a scratch directory, never the live mirror: benchmark.py
# refuses that outright, after it happened once.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The container is RESOLVED, not typed: `<project>-db-1` is derived from the
# directory name and broke everywhere the day the pilot was renamed.
# platform/db/pilot_db.sh asks compose for the service instead.
DB_CONTAINER="${DB_CONTAINER:-$("$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"/platform/db/pilot_db.sh container)}"

[ -x "$HERE/venv/bin/python" ] || {
  echo "environment not set up. run: platform/analytics/setup.sh" >&2; exit 78; }

SCRATCH="$(mktemp -d -t analytics_bench.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

PGPASSWORD="$(docker exec "$DB_CONTAINER" sh -c 'printf %s "$POSTGRES_PASSWORD"' 2>/dev/null)" || {
  echo "cannot reach $DB_CONTAINER -- is the pilot database running?" >&2; exit 78; }
export PGPASSWORD PQ_PATH="$SCRATCH"
export BENCH_N="${BENCH_N:-5}"

exec "$HERE/venv/bin/python" "$HERE/benchmark.py"

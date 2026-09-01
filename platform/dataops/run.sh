#!/usr/bin/env bash
# Entry point. Reuses the analytics venv rather than creating a second one:
# duckdb and psycopg2 are exactly the dependencies this needs, and two venvs
# holding the same pins is two things to keep in step.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$HERE/../analytics/venv"
DB_CONTAINER="${DB_CONTAINER:-station2-twin-db-1}"

[ -x "$VENV/bin/python" ] || {
  echo "environment not set up. run: platform/analytics/setup.sh" >&2; exit 78; }

if [ -z "${PGPASSWORD:-}" ]; then
  PGPASSWORD="$(docker exec "$DB_CONTAINER" sh -c 'printf %s "$POSTGRES_PASSWORD"' 2>/dev/null)" || {
    echo "cannot reach $DB_CONTAINER -- is the pilot database running?" >&2; exit 78; }
fi
export PGPASSWORD
exec "$VENV/bin/python" "$HERE/pipeline_metrics.py" "$@"

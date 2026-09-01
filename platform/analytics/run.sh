#!/usr/bin/env bash
# Entry point. Sources the database password from the running container into the
# environment -- never onto a command line, where `ps` would show it to every
# process on the machine.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$HERE/venv"
DB_CONTAINER="${DB_CONTAINER:-station2-twin-db-1}"

[ -x "$VENV/bin/python" ] || {
  echo "environment not set up. run: platform/analytics/setup.sh" >&2; exit 78; }

if [ -z "${PGPASSWORD:-}" ]; then
  PGPASSWORD="$(docker exec "$DB_CONTAINER" sh -c 'printf %s "$POSTGRES_PASSWORD"' 2>/dev/null)" || {
    echo "cannot reach $DB_CONTAINER -- is the pilot database running?" >&2; exit 78; }
fi
export PGPASSWORD

exec "$VENV/bin/python" "$HERE/mirror.py" "$@"

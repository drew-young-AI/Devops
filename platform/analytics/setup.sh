#!/usr/bin/env bash
# Create the isolated environment for the analytics mirror.
#
# A venv under platform/analytics/, not the host Python and not a shared one:
# this layer pins its engine version (requirements.txt) because an analytics
# engine that floats is an analytics engine whose numbers can change without
# anyone editing a query. Gitignored and disposable -- delete it and re-run.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$HERE/venv"

if [ ! -x "$VENV/bin/python" ]; then
  echo "  creating venv at $VENV"
  python3 -m venv "$VENV"
fi
"$VENV/bin/pip" install -q --upgrade pip
echo "  installing pinned dependencies (this can take a few minutes on first run)"
"$VENV/bin/pip" install -q -r "$HERE/requirements.txt"
"$VENV/bin/python" - <<'PY'
import duckdb, psycopg2
print(f"  duckdb {duckdb.__version__}, psycopg2 ok")
PY
echo "  ready:  platform/analytics/run.sh build"

#!/usr/bin/env bash
# Finds an interpreter that already has `tokenizers` and runs the measurement.
# Deliberately installs NOTHING: this script exists to answer whether a
# dependency is worth adding, so adding one to run it would settle the question
# by assumption.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for py in "$HOME/ENV/dev/bin/python" "$HERE/../analytics/venv/bin/python" python3; do
  if command -v "$py" >/dev/null 2>&1 || [ -x "$py" ]; then
    if "$py" -c "import tokenizers" 2>/dev/null; then
      exec "$py" "$HERE/context_cost.py" "$@"
    fi
  fi
done
echo "no interpreter with \`tokenizers\` found; the measurement is UNVERIFIED." >&2
echo "nothing was installed. see docs/decisions/0006-context-compaction.md" >&2
exit 78

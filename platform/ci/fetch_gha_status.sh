#!/usr/bin/env bash
# Fetch remote CI state into evidence, so the board can read it without asking
# the network.
#
# WHY THIS IS A SCHEDULED FETCH AND NOT A PROBE.
#
# The first version of the GitHub Actions node called `gh run list` directly
# from dag.py. Two problems showed up immediately, both fatal for a board:
#
#   1. It is a network round-trip. It took 30s and then failed with
#      "error connecting to api.github.com" -- while 1.1.1.1 and 8.8.8.8 were
#      both fine, so this was GitHub being unreachable, not the machine being
#      offline. A board that renders in 30s does not get looked at.
#   2. It makes the board's own health depend on a third party's availability.
#
# Every other probe on this board reads evidence written earlier by a scheduled
# job. This follows that shape: the fetch can be slow and can fail, and the
# board stays fast and states plainly how old its information is.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/evidence/ci/gha_status.json"
BRANCH="${GHA_BRANCH:-main}"
mkdir -p "$(dirname "$OUT")"

write() {  # <state> <detail> [runs-json]
  python3 - "$OUT" "$1" "$2" "${3:-[]}" <<'PY'
import json, sys, datetime
out, state, detail, runs = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    runs = json.loads(runs)
except Exception:
    runs = []
# The fetch timestamp is written even on failure. A file that is only updated
# on success cannot be distinguished from a fetch that stopped running, and
# "no news" would read as "still green".
doc = {
    "schema": "gha-status/1",
    "fetched_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "fetch_state": state,
    "detail": detail,
    "runs": runs,
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
print(f"{state}: {detail}")
PY
}

command -v gh >/dev/null 2>&1 || { write "unavailable" "gh not on PATH"; exit 0; }

RUNS="$(gh run list --branch "$BRANCH" --limit 10 \
        --json conclusion,status,displayTitle,createdAt,workflowName,url 2>&1)"
RC=$?
if [ "$RC" -ne 0 ] || ! printf '%s' "$RUNS" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  # Exit 0 on purpose: an unreachable GitHub is not a failure of THIS job, and
  # a non-zero exit would make the scheduler's own health red for someone
  # else's outage. The state is recorded in the evidence instead.
  write "unreachable" "$(printf '%s' "$RUNS" | head -1 | cut -c1-80)"
  exit 0
fi

write "ok" "fetched $BRANCH" "$RUNS"

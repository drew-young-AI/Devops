#!/usr/bin/env bash
# Remote CI state must be judged per WORKFLOW, not "whichever run finished last".
#
# WHY THIS SUITE EXISTS (2026-09-09).
#
# `probe_github_actions` was created in 2026-08-31 for a documented reason:
# GitHub Actions had been red for six days with nobody told, and "a red CI
# nobody is told about is indistinguishable from no failure at all". The node
# worked, was watched, and had NO TEST.
#
# On 2026-09-09 it printed 「main 綠燈」 while `Platform Tests` had been red for
# three consecutive pushes. The cause: `gh run list` returns every workflow
# interleaved -- this repo pushes three per commit -- and the probe read
# `runs[0]`, so it answered "was the most recently finished run of ANY workflow
# green". IaC Validation is fast and green; Platform Tests is slow and was red.
#
# That is the node's own founding failure, recurring inside the node. The list
# held the answer and the verdict looked at one element of it.
#
# The fixtures below are JSON documents, not a live GitHub, so the states that
# matter -- red, mixed, running, stale, unreachable -- can each be produced on
# demand instead of waited for.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="gha-status"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== remote CI state is judged per workflow =="

FIX="$(mktemp -d)"
cleanup() { rm -rf "$FIX"; }
on_exit cleanup

# probe() <fixture-json> -- runs the real probe against a fake evidence root.
probe() {
  python3 - "$FIX" "$1" <<'PY'
import json, os, sys, datetime
root, doc = sys.argv[1], json.loads(sys.argv[2])
doc.setdefault("schema", "gha-status/1")
doc.setdefault("fetched_at", datetime.datetime.now().astimezone()
               .isoformat(timespec="seconds"))
os.makedirs(os.path.join(root, "ci"), exist_ok=True)
with open(os.path.join(root, "ci", "gha_status.json"), "w",
          encoding="utf-8") as fh:
    json.dump(doc, fh, ensure_ascii=False)

sys.path.insert(0, os.path.join(os.getcwd(), "platform", "statusdag"))
os.environ["STATUSDAG_EVIDENCE"] = root
import dag
dag.EVIDENCE = root
print("%s|%s" % dag.probe_github_actions())
PY
}

run3() {  # <conclusion-for-Platform-Tests> -- three workflows, newest first
  cat <<JSON
{"fetch_state":"ok","runs":[
 {"workflowName":"IaC Validation","status":"completed","conclusion":"success","displayTitle":"c"},
 {"workflowName":"pilot-image","status":"completed","conclusion":"success","displayTitle":"c"},
 {"workflowName":"Platform Tests","status":"completed","conclusion":"$1","displayTitle":"c"}]}
JSON
}

# ---- the regression this suite is named after ------------------------------
#
# IaC Validation is FIRST in the list and green; Platform Tests is red. The old
# code read runs[0] and returned OK. This is the assertion that would have
# caught three pushes' worth of red.
run_cmd probe "$(run3 failure)"
assert_output_contains "fail|" \
  "a red workflow is FAIL even when a greener one finished more recently"
assert_output_contains "Platform Tests" \
  "and the failing workflow is NAMED -- 'CI is red' sends someone to look at three"

# ---- the positive control: all green must actually be green ----------------
#
# Without this, the fix could be "always return FAIL", which passes the
# assertion above and is useless.
run_cmd probe "$(run3 success)"
assert_output_contains "ok|" "all three green is OK, so the check is not always red"

# ---- a workflow still running is not a verdict -----------------------------
run_cmd probe '{"fetch_state":"ok","runs":[
 {"workflowName":"IaC Validation","status":"completed","conclusion":"success","displayTitle":"c"},
 {"workflowName":"Platform Tests","status":"in_progress","conclusion":null,"displayTitle":"c"}]}'
assert_output_contains "warn|" "a workflow still running is amber, not a pass and not a failure"

# ---- red beats running, because red is already known -----------------------
run_cmd probe '{"fetch_state":"ok","runs":[
 {"workflowName":"IaC Validation","status":"in_progress","conclusion":null,"displayTitle":"c"},
 {"workflowName":"Platform Tests","status":"completed","conclusion":"failure","displayTitle":"c"}]}'
assert_output_contains "fail|" \
  "a known red workflow is not softened to amber by another one still running"

# ---- the three unhappy states stay distinct --------------------------------
#
# Collapsing 'could not fetch' into FAIL makes the board red for someone else's
# outage; collapsing it into OK is how six days went unread.
run_cmd probe '{"fetch_state":"unreachable","detail":"github unreachable","runs":[]}'
assert_output_contains "unknown|" "a failed fetch is UNKNOWN, not red and not green"

run_cmd probe '{"fetch_state":"ok","runs":[]}'
assert_output_contains "unknown|" "no runs on the branch is UNKNOWN, not green"

# ---- stale green is not green ----------------------------------------------
run_cmd probe '{"fetch_state":"ok","fetched_at":"2020-01-01T00:00:00+08:00","runs":[
 {"workflowName":"Platform Tests","status":"completed","conclusion":"success","displayTitle":"c"}]}'
assert_output_contains "warn|" \
  "green information from years ago is not evidence that CI is green now"

# ---- only the NEWEST run of each workflow counts ---------------------------
#
# A workflow that was red yesterday and green today is green. Reading the whole
# list without keying on workflow would keep it red forever.
run_cmd probe '{"fetch_state":"ok","runs":[
 {"workflowName":"Platform Tests","status":"completed","conclusion":"success","displayTitle":"new"},
 {"workflowName":"Platform Tests","status":"completed","conclusion":"failure","displayTitle":"old"}]}'
assert_output_contains "ok|" \
  "an older failure of the same workflow does not outvote its newest run"

suite_summary

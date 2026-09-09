#!/usr/bin/env bash
# The dashboards are the surface a reviewer actually looks at, and until
# 2026-08-29 no test read them at all.
#
# On that date every panel of platform-stages.json -- the board built FOR a
# reviewer -- was querying datasource uid "prometheus", which is not the uid
# datasources.yml provisions. Grafana replies {"message":"Data source not
# found"} and draws an empty panel. The JSON was valid, the PromQL was valid,
# the metrics existed, promtool was irrelevant, and every other suite passed.
#
# Each rule below is broken on purpose in a fixture before it is trusted.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="dashboards"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== dashboards: a panel that draws nothing looks exactly like good news =="

AUDIT="$SUITE_DIR/dashboard_audit.py"
REAL_DIR="$REPO_ROOT/platform/observability/grafana/dashboards"
assert_file_exists "$AUDIT" "dashboard_audit.py exists"

# ---- the real dashboards must pass ----------------------------------------
run_cmd python3 "$AUDIT"
assert_rc 0 "the committed dashboards pass the audit"

# ---- every panel must be reachable through Grafana, not just parseable ----
#
# The audit is static. It cannot tell whether Grafana would actually answer.
# This asks Grafana to run every query on every dashboard and fails on any
# error or empty result -- which is the only thing that would have caught the
# datasource defect at the time it was introduced.
GRAFANA_ENV="$REPO_ROOT/platform/observability/.grafana.env"
RENDER="$REPO_ROOT/platform/observability/scripts/verify_dashboard_render.py"
assert_file_exists "$RENDER" "verify_dashboard_render.py exists"

# ONE IMPLEMENTATION, NOT TWO (2026-09-09).
#
# This block used to carry its own copy of the live-panel check: build the
# queries, POST them to /api/ds/query, count empty frames. It found the
# dashboards with `glob("<dir>/*.json")`. When the dashboards moved into
# per-discipline subdirectories (ADR-0017) that glob matched NOTHING, and the
# check went on printing `PANELS_FAILING=0` while querying zero panels --
# the third time this repository has hit "a scan that examined nothing reports
# the same as one that examined everything", and the second time in this one
# file.
#
# The lesson is not "fix the glob again". Two copies of one check diverge, and
# the copy nobody looks at is the one that starts lying. The walk, the empty
# refusal and the Prometheus/Loki endpoint split now live in ONE script, which
# is also runnable by a human, and this suite calls it.
if [ -f "$GRAFANA_ENV" ] && curl -s -m 5 -o /dev/null http://127.0.0.1:13000/api/health; then
  # Credentials stay inside the script, which reads the gitignored env file
  # itself: never echoed, never passed as argv (ps(1) is world-readable here).
  run_cmd python3 "$RENDER"
  assert_rc 0 "every panel query runs through Grafana's own auth and proxy"
  assert_output_contains "0 failed" \
    "and none of them errors -- a wrong datasource uid or an unreachable "\
"backend shows as empty panels and no error anywhere"
  # The denominator is asserted, not just printed. A future reorganisation that
  # hides the dashboards again must turn this red instead of quietly passing.
  PANELS="$(grep -oE '[0-9]+ panel quer' "$LAST_STDOUT" | grep -oE '^[0-9]+')"
  assert_rc 0 "the render check reports how many panels it actually ran"
  if [ "${PANELS:-0}" -ge 20 ]; then
    assert_equals "yes" "yes" "it ran $PANELS panel queries, not zero"
  else
    assert_equals "at least 20 panels" "$PANELS panels" \
      "a render check that examined almost nothing is refused, not reported clean"
  fi
else
  echo "  SKIP  Grafana not reachable -- live panel rendering is UNVERIFIED"
fi

# ---- now break each rule on purpose ---------------------------------------
FIX="$(mktemp -d)"
cleanup() { rm -rf "$FIX"; }
on_exit cleanup

# `cp -R "$REAL_DIR"/. ` and not `cp "$REAL_DIR"/*.json`: on 2026-09-09 the
# dashboards moved into per-discipline subdirectories (ADR-0017) and the flat
# glob matched nothing, so every fixture case ran against an EMPTY directory.
# The audit's own empty-scan refusal is what surfaced it; before that guard
# existed the cases would have gone quietly green against no input.
reset_fixture() { rm -rf "${FIX:?}"/*; cp -R "$REAL_DIR"/. "$FIX/"; }

# A mutation that the audit does NOT catch is worse than no audit: it is a
# green light with nothing behind it.
mutate() {   # <name> <python-snippet-on-`d`> <expected-substring> <file>
  local label="$1" code="$2" want="$3" file="${4:-0-overview/platform-stages.json}"
  reset_fixture
  python3 - "$FIX/$file" <<PY
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text())
$code
p.write_text(json.dumps(d, ensure_ascii=False))
PY
  local out
  out="$(DASHBOARDS_DIR="$FIX" python3 "$AUDIT" 2>&1)"
  if printf '%s' "$out" | grep -q "$want"; then
    _pass "catches: $label"
  else
    _fail "catches: $label" "audit did not report it. output: ${out:-<empty>}"
  fi
}

# ---- the audit must refuse an empty scan ----------------------------------
#
# This is not hypothetical. On 2026-09-09 the dashboards moved into
# per-discipline subdirectories and the audit -- which listed one level -- went
# from checking five dashboards to checking zero, and printed
# "0 problem(s), 0 unverified". A clean run and a run that examined nothing are
# the same sentence. Three separate guards on this platform have now hit that
# shape (an empty grep, a collapsed capability walk, this), so it is asserted
# rather than remembered.
EMPTY_DIR="$(mktemp -d)"
run_cmd env DASHBOARDS_DIR="$EMPTY_DIR" python3 "$AUDIT"
assert_rc 1 "an audit that finds NO dashboards fails instead of reporting clean"
assert_output_contains "no dashboards found" "and says that is why"
rmdir "$EMPTY_DIR"

# ---- folders are disciplines, projects are labels (ADR-0017) --------------
#
# The provider maps subdirectories to Grafana folders, so the directory layout
# IS the folder layout and there is no second list to keep in agreement. What
# a test can still catch is a dashboard dropped at the top level, which would
# land in Grafana's General folder and be invisible to anyone browsing by
# discipline.
TOP_LEVEL="$(find "$REAL_DIR" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')"
assert_equals "0" "$TOP_LEVEL" \
  "no dashboard sits outside a discipline folder (it would land in General)"
run_cmd grep -c 'foldersFromFilesStructure: true' \
  "$REPO_ROOT/platform/observability/grafana/provisioning/dashboards/dashboards.yml"
assert_rc 0 "the provider derives folders from the directory structure"

mutate "a datasource uid that is not provisioned" \
  'd["panels"][0]["targets"][0]["datasource"]["uid"] = "prometheus"' \
  "not in datasources.yml"

# This one control -- and only this one -- needs Prometheus, because the audit
# can only say "nothing produces this metric" after asking the one component
# that would know. With Prometheus down the audit correctly answers UNVERIFIED
# instead, so running the control anyway would fail it for a reason that has
# nothing to do with the rule under test.
#
# It is SKIPPED LOUDLY rather than quietly relaxed to accept UNVERIFIED. A
# control that passes on the audit's "I don't know" is not a control: it would
# go on passing after the audit lost the ability to detect anything at all.
if curl -s -m 5 -o /dev/null "${PROM_URL:-http://127.0.0.1:19090}/-/ready" 2>/dev/null; then
  mutate "a metric nothing produces" \
    'd["panels"][0]["targets"][0]["expr"] = "count(devops_node_stat_code)"' \
    "nothing produces"
else
  echo "  SKIP  Prometheus unreachable -- 'a metric nothing produces' is UNVERIFIED"
fi

mutate "a hardcoded node list duplicating LINES" \
  'd["panels"][0]["targets"][0]["expr"] = (
       "count(devops_node_state{node=~\"vault|audit|scheduler\",state=\"ok\"})")' \
  "hardcodes a node list"

mutate "value mappings drifting from dag.py RANK" \
  'd["panels"][5]["fieldConfig"]["defaults"]["mappings"][0]["options"].pop("4")' \
  "RANK"

mutate "two dashboards claiming the same uid" \
  'd["uid"] = "dataops-pipeline"' \
  "also used by"

# ---- and the positive control: an unmutated fixture must PASS --------------
#
# Without this, every assertion above would still "pass" if the audit simply
# reported everything as broken.
reset_fixture
run_cmd env DASHBOARDS_DIR="$FIX" python3 "$AUDIT"
assert_rc 0 "an unmutated fixture copy passes (the audit is not just always red)"

suite_summary

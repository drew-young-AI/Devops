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
if [ -f "$GRAFANA_ENV" ] && curl -s -m 5 -o /dev/null http://127.0.0.1:13000/api/health; then
  # Credentials come from the gitignored env file and are never echoed, never
  # passed as argv (ps(1) is readable by every process on this machine).
  set -a; . "$GRAFANA_ENV"; set +a
  run_cmd python3 - "$REAL_DIR" <<'PY'
import base64, glob, json, os, sys, urllib.error, urllib.request

auth = base64.b64encode(
    f"{os.environ['GF_SECURITY_ADMIN_USER']}:"
    f"{os.environ['GF_SECURITY_ADMIN_PASSWORD']}".encode()).decode()
bad = 0
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.json"))):
    dash = json.load(open(path, encoding="utf-8"))
    queries, titles = [], []
    for panel in dash.get("panels", []):
        for t in panel.get("targets", []):
            if not t.get("expr"):
                continue
            queries.append({"refId": chr(65 + len(queries)),
                            "datasource": t["datasource"],
                            "expr": t["expr"], "instant": True})
            titles.append(panel.get("title", "?"))
    if not queries:
        continue
    req = urllib.request.Request(
        "http://127.0.0.1:13000/api/ds/query",
        data=json.dumps({"queries": queries, "from": "now-5m",
                         "to": "now"}).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": "Basic " + auth})
    try:
        res = json.load(urllib.request.urlopen(req, timeout=25))["results"]
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code} querying {os.path.basename(path)}")
        bad += 1
        continue
    for (ref, out), title in zip(sorted(res.items()), titles):
        if out.get("error"):
            print(f"ERROR {os.path.basename(path)} :: {title} :: "
                  f"{out['error'][:90]}")
            bad += 1
        elif not out.get("frames"):
            # Empty is not automatically wrong -- a panel can legitimately have
            # no series right now -- but on THIS platform every dashboard panel
            # is meant to describe something that always exists, so empty is
            # reported and judged rather than ignored.
            print(f"EMPTY {os.path.basename(path)} :: {title}")
            bad += 1
print(f"PANELS_FAILING={bad}")
PY
  assert_rc 0 "every dashboard query runs through Grafana"
  assert_output_contains "PANELS_FAILING=0" \
    "and every panel returns data rather than an empty frame"
else
  echo "  SKIP  Grafana not reachable -- live panel rendering is UNVERIFIED"
fi

# ---- now break each rule on purpose ---------------------------------------
FIX="$(mktemp -d)"
cleanup() { rm -rf "$FIX"; }
on_exit cleanup

reset_fixture() { rm -rf "${FIX:?}"/*; cp "$REAL_DIR"/*.json "$FIX/"; }

# A mutation that the audit does NOT catch is worse than no audit: it is a
# green light with nothing behind it.
mutate() {   # <name> <python-snippet-on-`d`> <expected-substring> <file>
  local label="$1" code="$2" want="$3" file="${4:-platform-stages.json}"
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

#!/usr/bin/env bash
# Pipeline metrics, and the one failure mode that makes monitoring worse than
# nothing: AN ALERT RULE WRITTEN AGAINST A METRIC THAT IS NEVER PRODUCED.
#
# It parses. promtool passes it. It sits in the rules file looking like
# coverage, and it can never fire -- so the thing it claims to watch reads as
# permanently healthy. service-health.yml's own header records this happening
# on this platform: rules watching a service that had been deleted stayed green
# for weeks, and the monitoring looked healthiest at the moment it had stopped
# monitoring anything.
#
# So the central assertion here is a JOIN: every dataops_* metric named in
# dataops.yml must appear in the file the exporter actually writes. Checked
# against the emitted text rather than a live Prometheus, so it holds even when
# nothing is scraping.

set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="dataops-metrics"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== dataops metrics: rules and metrics must refer to the same things =="

RULES="$REPO_ROOT/platform/observability/prometheus/alerts/dataops.yml"
EXPORTER="$REPO_ROOT/platform/dataops/run.sh"
assert_file_exists "$RULES" "dataops.yml exists"
assert_file_exists "$EXPORTER" "dataops/run.sh exists"

if [ ! -x "$REPO_ROOT/platform/analytics/venv/bin/python" ]; then
  echo "  SKIP  analytics venv not built -- run platform/analytics/setup.sh"
  echo "        (LOUD skip: the rule/metric join below is UNVERIFIED)"
  suite_summary
  exit 0
fi

# Portable temp file. `mktemp -t name.XXXXXX.ext` works on macOS and is
# rejected by GNU coreutils ("Invalid argument"), which requires the X's to end
# the template -- and macOS does not even substitute them, leaving a literal
# "XXXXXX" in the name. A temp DIRECTORY with a fixed filename inside is the one
# form that behaves identically on both, keeps the extension the tool needs, and
# has no create-then-rename race.
OUT_DIR="$(mktemp -d)"
OUT="$OUT_DIR/dataops.prom"
on_exit 'rm -rf "$OUT_DIR"'

run_cmd env DATAOPS_PROM="$OUT" "$EXPORTER"
assert_rc 0 "the exporter runs"
assert_file_exists "$OUT" "and writes a .prom file"

# A half-written .prom makes node-exporter drop the entire scrape, so the write
# is atomic. If a .tmp survives, the rename did not happen.
if [ -f "$OUT.tmp" ]; then
  _fail "the write is atomic" "$OUT.tmp was left behind"
else
  _pass "the write is atomic (no .tmp left behind)"
fi

# ---- THE CENTRAL ASSERTION ------------------------------------------------
MISSING=""
while read -r metric; do
  [ -z "$metric" ] && continue
  if grep -qE "^${metric}[{ ]" "$OUT"; then :; else MISSING="$MISSING $metric"; fi
done < <(python3 -c "
import re, sys, yaml
# Names are taken from the expr FIELDS, not from a grep over the file. The
# grep version read comments as PromQL: this suite's own filename appears in a
# comment there, and 'test_dataops_metrics.sh' contains the substring
# 'dataops_metrics', which was duly reported as a metric nobody produces.
# A guard that cries wolf gets its assertion loosened, which is how a guard
# stops guarding.
d = yaml.safe_load(open(sys.argv[1]))
names = set()
recorded = set()
for g in d.get('groups') or []:
    for r in g.get('rules') or []:
        if r.get('record'):
            recorded.add(r['record'])
        names |= set(re.findall(r'dataops_[a-z_]+', r.get('expr') or ''))
# A recording rule's own output is produced by Prometheus, not the exporter.
for n in sorted(names - recorded):
    print(n)
" "$RULES")

if [ -n "$MISSING" ]; then
  _fail "every metric named in the alert rules is actually emitted" \
        "never produced:$MISSING -- these rules can never fire, and a rule that cannot fire reads as all-clear"
else
  _pass "every metric named in the alert rules is actually emitted"
fi

# And the reverse direction is deliberately NOT asserted: an emitted metric with
# no rule is fine (it is data for a dashboard or an ad-hoc query). Only the
# unbacked RULE is a lie.

# ---- the exporter's own contract -----------------------------------------
for m in dataops_source_age_seconds dataops_ingest_reject_ratio \
         dataops_mirror_stale dataops_metrics_generated_timestamp_seconds; do
  if grep -qE "^${m}[{ ]" "$OUT"; then
    _pass "emits $m"
  else
    _fail "emits $m" "not present in the exporter output"
  fi
done

# Every metric carries HELP and TYPE: a bare number in a textfile collector is
# a number nobody else can interpret.
UNDOC=""
while read -r name; do
  grep -q "^# HELP ${name} " "$OUT" || UNDOC="$UNDOC $name"
done < <(grep -oE "^dataops_[a-z_]+" "$OUT" | sort -u)
if [ -n "$UNDOC" ]; then
  _fail "every emitted metric has a HELP line" "undocumented:$UNDOC"
else
  _pass "every emitted metric has a HELP line"
fi

# ---- ingest_runs.status must be classified, not defaulted ------------------
#
# The exporter counted `status <> 'ok'` as failures. The only non-ok status any
# loader writes is `ok-with-conflicts`, which means the run SUCCEEDED and the
# source contradicted itself -- so IngestRunsFailing announced 「有失敗的載入
# 批次」 about runs that had not failed, weekly, forever.
#
# pipeline_metrics.py now classifies every status explicitly and exits on one
# it does not recognise. This asserts the classification is complete against
# what the database actually holds, which is the half an exit-on-unknown cannot
# prove by itself: it only fires if such a row is reached, and a source that
# stops loading stops being reached.
if timeout 20 docker exec station2-twin-db-1 true >/dev/null 2>&1; then
  UNCLASSIFIED="$(python3 - <<'PY'
import re, subprocess
src = open("platform/dataops/pipeline_metrics.py", encoding="utf-8").read()
def lst(name):
    m = re.search(name + r"\s*=\s*\[([^\]]*)\]", src)
    return set(re.findall(r'"([^"]+)"', m.group(1))) if m else set()
known = lst("OK_STATUSES") | lst("CONFLICT_STATUSES") | lst("FAILURE_STATUSES")
out = subprocess.run(
    ["docker", "exec", "station2-twin-db-1", "psql", "-U", "twin", "-d", "twin",
     "-At", "-c", "SELECT DISTINCT status FROM ingest_runs"],
    capture_output=True, text=True, timeout=60)
actual = {s for s in out.stdout.strip().split("\n") if s}
print(",".join(sorted(actual - known)))
PY
)"
  assert_equals "" "$UNCLASSIFIED" "every ingest_runs.status in the database is classified"

  # And the reverse: the three lists must not overlap, or a status would be
  # counted twice and the totals would exceed the run count.
  OVERLAP="$(python3 - <<'PY'
import re
src = open("platform/dataops/pipeline_metrics.py", encoding="utf-8").read()
def lst(name):
    m = re.search(name + r"\s*=\s*\[([^\]]*)\]", src)
    return set(re.findall(r'"([^"]+)"', m.group(1))) if m else set()
ok, conf, fail = lst("OK_STATUSES"), lst("CONFLICT_STATUSES"), lst("FAILURE_STATUSES")
print(",".join(sorted((ok & conf) | (ok & fail) | (conf & fail))))
PY
)"
  assert_equals "" "$OVERLAP" "the three status classes are disjoint"
else
  echo "  SKIP  no database -- status classification completeness UNVERIFIED"
fi

# ---- promtool: Prometheus' own parser, not ours ---------------------------
if command -v docker >/dev/null 2>&1; then
  run_cmd docker run --rm -v "$REPO_ROOT/platform/observability/prometheus/alerts:/a:ro" \
      --entrypoint promtool "$(prom_image)" check rules /a/dataops.yml
  assert_rc 0 "promtool accepts the rules"
  # Six, not seven. IngestRunsFailing was removed 2026-09-03: its counter was
# `status <> 'ok'`, the only non-ok status means the run SUCCEEDED with a
# self-contradicting source, and no loader writes a failure status at all --
# so it could not fire for its stated reason and did fire for another. Batch
# failure is covered by the scheduler path (probe_scheduler ->
# PlatformNodeFailed), which is where a run that never wrote a row shows up.
# Seven since 2026-09-04: SourcePublishedNothingNew closed the empty-fetch
# gap (§19) -- a fetch that succeeds and brings nothing new, which the
# freshness metric cannot see because a successful fetch resets its clock.
assert_output_contains "7 rules found" "and finds all seven (6 alerts + 1 recording rule)"
else
  echo "  SKIP  no docker -- promtool validation UNVERIFIED"
fi

# ---- the drift window must be the CURRENT year ----------------------------
#
# The drift query stepped back a fixed `- 100` from the latest epi-week -- one
# whole YEAR -- so with data running to 2026w32 it compared 2025w32 against
# 2024w32, and was structurally incapable of seeing the only year a fault
# could have been introduced in. It produced plausible numbers throughout.
#
# Nothing static could catch it: the SQL was valid, every metric name matched,
# and the values looked reasonable. So the assertion is on the DATA.
VENVPY="$REPO_ROOT/platform/analytics/venv/bin/python"
if [ -x "$VENVPY" ] && [ -f "$REPO_ROOT/platform/analytics/mirror/fact.parquet" ]; then
  run_cmd "$VENVPY" "$REPO_ROOT/platform/dataops/settled_week.py"
  assert_rc 0 "the settled-week rule runs against the mirror"
  assert_output_contains "LAG_OK=True" \
    "drift compares a week close to the newest data, not a year behind"
else
  echo "  SKIP  no mirror -- the drift window is UNVERIFIED"
fi

# ---- ...and it must survive the year boundary ------------------------------
#
# LAG_OK above can only go red for about one week a year. The settle rule
# picked "the most recent week whose coverage is at least the median of the 12
# weeks before it", and expressed those 12 weeks as `yw >= c.yw - 12` where yw
# is epi_year*100 + epi_week. That is week arithmetic INSIDE one year: at
# 2026w01 it asked for weeks in [202589, 202600], a range no week can occupy,
# so week 1 produced no row and could never be selected. Measured on the real
# mirror 2026-09-08: 191 of 191 week-1 rows dropped, versus 1 of 7,445 for
# weeks 13-52.
#
# Running the suite in September proves nothing about January, so the control
# MOVES THE DATA rather than waiting for the calendar: the same mirror is
# truncated at 2026w01 and the rule must still name 202601. The broken form
# named 202553 -- a year behind, wearing this week's label.
#
# It evaluates pipeline_metrics.SETTLE_CTE itself, not a copy. A copy is what
# this check is guarding against; see the comment on that constant.
if [ -x "$VENVPY" ] && [ -f "$REPO_ROOT/platform/analytics/mirror/fact.parquet" ]; then
  run_cmd "$VENVPY" -c "
import sys, duckdb
sys.path.insert(0, '$REPO_ROOT/platform/dataops')
from pipeline_metrics import SETTLE_CTE
M = '$REPO_ROOT/platform/analytics/mirror'
def settled(cut=None):
    d = duckdb.connect()
    d.execute(\"CREATE VIEW fact AS SELECT * FROM '%s/fact.parquet'\" % M)
    w = ('WHERE CAST(epi_year AS INTEGER)*100+CAST(epi_week AS INTEGER) <= %d' % cut) if cut else ''
    d.execute(\"CREATE VIEW period AS SELECT * FROM '%s/period.parquet' %s\" % (M, w))
    return d.execute('WITH ' + SETTLE_CTE + ' SELECT MAX(ymax) FROM latest').fetchone()[0]
print('TRUNCATED_TO_W01', settled(202601))
print('TRUNCATED_TO_W02', settled(202602))
print('UNTRUNCATED_UNCHANGED', settled() == $(cd "$REPO_ROOT" && "$VENVPY" "$REPO_ROOT/platform/dataops/settled_week.py" | sed -n 's/.*SETTLED=\([0-9]*\).*/\1/p'))
"
  assert_rc 0 "the settle rule evaluates across a year boundary"
  assert_output_contains "TRUNCATED_TO_W01 202601" \
    "at 2026w01 the settled week is w01, not 2025w53 (the year-arithmetic bug)"
  assert_output_contains "TRUNCATED_TO_W02 202602" \
    "the week after a year boundary is unaffected"
  assert_output_contains "UNTRUNCATED_UNCHANGED True" \
    "the fix changes nothing about the week selected today"
else
  echo "  SKIP  no mirror -- the year boundary is UNVERIFIED"
fi

# ---- the SECOND way a rule can be a lie: it parses but cannot evaluate ------
#
# The join above proves every metric a rule names is produced. It does NOT
# prove the rule can run. On 2026-08-28 WidespreadGeoDrift shipped with an
# implicit many-to-one vector match: valid YAML, valid PromQL grammar,
# `promtool check rules` -> SUCCESS, 6 rules found. Prometheus loaded it and
# failed to evaluate it on every cycle for 11 hours. During that window the
# board showed `prometheus  ok  running (none)` and `alertmgr  ok  no active
# alerts` -- and "no active alerts" is indistinguishable from a rule that
# cannot produce any.
#
# promtool cannot catch this, because vector matching depends on the LABELS
# PRESENT AT RUNTIME, which a static file does not contain. Only evaluation
# knows. So this section asks the running Prometheus, and is explicit when it
# cannot.
PROM="${PROM_URL:-http://127.0.0.1:19090}"
RULES_JSON="$(curl -s -m 8 "$PROM/api/v1/rules" 2>/dev/null || true)"
if printf '%s' "$RULES_JSON" | grep -q '"groups"'; then
  UNHEALTHY="$(printf '%s' "$RULES_JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)['data']['groups']
bad=[r['name'] for g in d for r in g['rules'] if r.get('health') not in ('ok','unknown')]
print(','.join(bad))
")"
  N_RULES="$(printf '%s' "$RULES_JSON" | python3 -c "
import json,sys; print(sum(len(g['rules']) for g in json.load(sys.stdin)['data']['groups']))")"
  if [ -z "$UNHEALTHY" ]; then
    _pass "all $N_RULES loaded rules evaluate without error"
  else
    _fail "all loaded rules evaluate without error" \
          "these are loaded but cannot evaluate: $UNHEALTHY"
  fi
else
  echo "  SKIP  Prometheus unreachable at $PROM -- rule EVALUATION is UNVERIFIED"
fi

# ---- and the board must not be able to stay green while a rule is broken ---
#
# Detecting it is not the same as telling anyone. check_health.py DID detect
# this and wrote UNKNOWN into evidence every 15 minutes for 11 hours; the board
# is what people actually read, and the board said ok. Both halves are asserted
# here: the probe reports rule health, and it goes non-OK when a rule cannot
# evaluate. Stubbed rather than mutating the live rules file -- restarting
# Prometheus inside a test suite is a 15s cost per run for a fact a fake proves
# just as well.
run_cmd python3 -c "
import sys, json, io, urllib.request
sys.path.insert(0, '$REPO_ROOT/platform/statusdag')
import dag

class R(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *a): return False

def fake(payload):
    def _open(url, timeout=0):
        if 'api/v1/rules' in url:
            return R(json.dumps({'data': {'groups': payload}}).encode())
        raise AssertionError('unexpected url ' + url)
    return _open

dag.probe_docker = lambda name: (dag.OK, 'running (none)')
real = urllib.request.urlopen
try:
    urllib.request.urlopen = fake([{'name': 'g', 'rules': [
        {'name': 'A', 'health': 'ok'}, {'name': 'B', 'health': 'ok'}]}])
    print('HEALTHY_CASE', dag.probe_prometheus())
    urllib.request.urlopen = fake([{'name': 'g', 'rules': [
        {'name': 'A', 'health': 'ok'},
        {'name': 'Broken', 'health': 'err', 'lastError': 'many-to-one'}]}])
    print('BROKEN_CASE', dag.probe_prometheus())
    urllib.request.urlopen = fake([])
    print('NO_RULES_CASE', dag.probe_prometheus())
finally:
    urllib.request.urlopen = real
"
assert_rc 0 "probe_prometheus runs against a stubbed rules API"
assert_output_contains "HEALTHY_CASE ('ok', 'running, 2 rules evaluating'" \
  "reports the rule count when every rule evaluates"
assert_output_contains "BROKEN_CASE ('warn', '1 rule(s) cannot evaluate: Broken'" \
  "goes WARN and NAMES the rule when one cannot evaluate"
assert_output_contains "NO_RULES_CASE ('warn', 'running, but NO alert rules" \
  "zero rules is WARN, not silence -- it looks identical to a quiet system"

# ── probe_alertmanager: a channel that is declared but not wired ────────────
#
# The 2026-08-19 outage ended in a null receiver; the fix wired Telegram and
# the config comment says there are TWO channels. On 2026-09-03 mail turned
# out never to have been wired at all, and NOTHING reported it -- Alertmanager
# was up, alerts were firing, the node read "5 alert(s) firing" and said
# nothing about half the delivery being absent.
#
# These three cases fix the direction of that check: the wired case must be
# able to go green, the unwired case must go WARN with zero alerts firing (the
# only moment it is still cheap to fix), and a channel whose sends FAIL must
# not look the same as one that works.
run_cmd python3 -c "
import io, json, sys, urllib.request
sys.path.insert(0, '$REPO_ROOT/platform/statusdag')
import dag

class R(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *a): return False

METRICS = 'alertmanager_notifications_failed_total{integration=\"%s\",reason=\"other\"} %s\n'

def fake(alerts, live_cfg, failed_pairs):
    def _open(url, timeout=0):
        if 'api/v2/alerts' in url:
            return R(json.dumps(alerts).encode())
        if 'api/v2/status' in url:
            return R(json.dumps({'config': {'original': live_cfg}}).encode())
        if 'metrics' in url:
            body = ''.join(METRICS % (k, v) for k, v in failed_pairs)
            return R(body.encode())
        raise AssertionError('unexpected url ' + url)
    return _open

dag.declared_channels = lambda: {'telegram', 'email'}
BOTH = 'receivers:\n  - name: r\n    telegram_configs:\n    email_configs:\n'
ONLY_TG = 'receivers:\n  - name: r\n    telegram_configs:\n'
real = urllib.request.urlopen
try:
    urllib.request.urlopen = fake([], BOTH, [('telegram', '0'), ('email', '0')])
    print('WIRED_CASE', dag.probe_alertmanager())
    urllib.request.urlopen = fake([], ONLY_TG, [('telegram', '0')])
    print('UNWIRED_CASE', dag.probe_alertmanager())
    urllib.request.urlopen = fake([], BOTH, [('telegram', '7'), ('email', '0')])
    print('FAILING_CASE', dag.probe_alertmanager())
finally:
    urllib.request.urlopen = real
"
assert_rc 0 "probe_alertmanager runs against a stubbed Alertmanager"
assert_output_contains "WIRED_CASE ('ok', 'no active alerts, all declared channels wired')" \
  "every declared channel wired and delivering is the only way to green"
assert_output_contains "UNWIRED_CASE ('warn', '宣告了但沒接上: email')" \
  "a declared-but-missing channel is WARN with ZERO alerts firing, and is named"
assert_output_contains "FAILING_CASE ('warn', '送出失敗: telegram')" \
  "configured is not delivered: a channel whose sends fail is not green"

# ── probe_prod_cluster: report what kubectl said, not a sentence we chose ───
#
# NOTE FOR WHOEVER ADDS THE NEXT PROBE TEST HERE: assert_output_contains reads
# the output of the LAST run_cmd. Inserting a run_cmd between an assert_rc and
# the assert_output_contains lines that belong to it silently retargets them --
# which is exactly what happened when this block was first added, and the three
# alertmanager assertions above went red. Add new blocks AFTER a complete
# assertion group, never inside one.
#
# Co-located with the probe_alertmanager stub above rather than in a suite of
# its own: both stub one dependency and assert on what the probe says.
#
# Until 2026-09-05 the unreachable branch was `rc, _ = run(...)` followed by a
# fixed string, so a TLS name mismatch, a dead machine and a broken route all
# printed the same sentence -- docs/Backlog.md T2. kubectl does say which one
# it is; the probe threw the line away.
#
# Only the SAN case is branched on, because only its message is deterministic.
# The same unreachable host was measured returning four different timeout
# strings, so the generic case must carry the raw line rather than name a
# cause. The third case is the control that keeps the first two honest: if the
# healthy path ever started reporting an error, the two above would still pass.
run_cmd python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/platform/statusdag')
import dag

SAN = ('Unable to connect to the server: tls: failed to verify certificate: '
       'x509: certificate is valid for kubernetes, ubu, ubu.local, '
       'not not-in-the-san.invalid')
TIMEOUT = 'Unable to connect to the server: context deadline exceeded'

dag.run = lambda cmd, timeout=25: (0, 'k3d-devops-lab\nubu\n')
dag.run_diag = lambda cmd, timeout=25: (1, '', SAN)
print('SAN_CASE', dag.probe_prod_cluster())
dag.run_diag = lambda cmd, timeout=25: (1, '', TIMEOUT)
print('TIMEOUT_CASE', dag.probe_prod_cluster())

def _run(cmd, timeout=25):
    if 'get-contexts' in cmd: return (0, 'k3d-devops-lab\nubu\n')
    return (0, '')          # no deployments -> ready-but-empty
dag.run = _run
dag.run_diag = lambda cmd, timeout=25: (0, 'ok', '')
print('READY_CASE', dag.probe_prod_cluster())
"
assert_rc 0 "probe_prod_cluster runs against a stubbed kubectl"
assert_output_contains "SAN_CASE ('warn', 'prod 叢集連不上：憑證 SAN 不符" \
  "a TLS name mismatch is named, because that message is deterministic"
assert_output_contains "context deadline exceeded" \
  "an unnamed failure carries kubectl's own line instead of a guessed cause"
assert_output_contains "READY_CASE ('warn', '叢集就緒但沒有任何工作負載" \
  "a reachable empty cluster still refuses to read as green"

# ---- MLOps: the board must report the CURRENT model, not the best one ever --
#
# probe_model_gate used to select every rolling-origin run and take max(margin)
# per horizon, under a sentence that reads as the present tense. On 2026-09-08
# that reported -12.08% / +0.55% -- which happened to be correct, because every
# retrain so far had improved. The run that would expose it is the first one
# that REGRESSES, and history already holds a -56.25% run at t+1 that the max
# had been hiding since 2026-08-20.
#
# Two layers, because the defect lived in the SQL and a stubbed psql() would
# have certified it happily:
#
#   1. the SQL itself, EVALUATED on DuckDB against a synthetic regression
#   2. the Python that turns its rows into the sentence on the board
if [ -x "$VENVPY" ]; then
  run_cmd "$VENVPY" -c "
import sys, duckdb
sys.path.insert(0, '$REPO_ROOT/platform/statusdag')
import dag
d = duckdb.connect()
d.execute('CREATE TABLE model_run(model_run_id INT, horizon_weeks INT, '
          'split_strategy VARCHAR, trained_at TIMESTAMP, mae DOUBLE, '
          'baseline_persistence_mae DOUBLE, algorithm VARCHAR, '
          'feature_set_id INT)')
# feature_set joins in from 2026-09-09: the query is keyed on the TARGET as
# well as the horizon, because two diseases are forecast and their margins
# differ by a factor of four. Two targets are in the fixture for that reason --
# with one, a query that dropped the target would still pass.
d.execute('CREATE TABLE feature_set(feature_set_id INT, target VARCHAR)')
d.execute(chr(73)+\"NSERT INTO feature_set VALUES (10,'pct_ili'),(20,'pct_flu')\")
# t+1 (ILI): an older run BEATS persistence by 10%, the newest LOSES by 30%.
# max() would report +10.00; the current state is -30.00.
d.execute(chr(73)+'NSERT INTO model_run VALUES '
          \"(1,1,'rolling_origin','2026-08-20',0.90,1.00,'HistGradientBoostingRegressor',10),\"
          \"(2,1,'rolling_origin','2026-09-05',1.30,1.00,'Ridge',10),\"
          \"(3,2,'rolling_origin','2026-09-05',0.95,1.00,'Ridge',10),\"
          \"(4,1,'rolling_origin','2026-09-05',0.50,1.00,'Ridge',20)\")
d.execute('CREATE TABLE forecast(forecast_id INT, model_run_id INT, horizon_weeks INT)')
d.execute('INSERT INTO forecast VALUES (1,1,1)')
rows = d.execute(dag.MODEL_GATE_SQL).fetchall()
print('SQL_ROWS', [(int(a), float(b), str(c), str(e), str(f), str(g))
                  for a,b,c,e,f,g in rows])
dag.psql = lambda sql, timeout=20: chr(10).join('|'.join(str(x) for x in r) for r in rows)
print('REGRESSION_CASE', dag.probe_model_gate())
dag.psql = lambda sql, timeout=20: '2|5.00|3|||pct_ili'
print('WINNING_CASE', dag.probe_model_gate())
dag.psql = lambda sql, timeout=20: None
print('NO_DB_CASE', dag.probe_model_gate())
"
  assert_rc 0 "probe_model_gate's SQL evaluates and the probe formats its rows"
  assert_output_contains "(1, 50.0, '4 Ridge', '', '', 'pct_flu')" \
    "the flu target gets its OWN row -- one slot per (target, horizon)"
  assert_output_contains "(1, -30.0, '2 Ridge', '10.00', '1', 'pct_ili')" \
    "the SQL names the LATEST run at t+1 (-30.00), not the best ever (+10.00)"
  assert_output_contains "ili t+1 最新 run2 Ridge -30.00%（線上 run1 +10.00%）" \
    "the challenger's score, its family, and the score of the model actually serving"
  assert_output_contains "ili t+2 最新 run3 Ridge" \
    "carrying the algorithm is what stops two families sharing one slot unlabelled"
  assert_output_contains "flu t+1 最新 run4 Ridge +50.00%" \
    "and a healthy target does NOT mask a losing one -- both are named"
  assert_output_contains "尚未上線" \
    "a horizon with no published forecast says so instead of comparing to nothing"
  assert_output_contains "WINNING_CASE ('ok', '全數勝過持平基準" \
    "the amber is a fact about the numbers, not a permanent colour"
  assert_output_contains "NO_DB_CASE ('unknown'" \
    "no answer from the database is not the same claim as a losing model"
else
  echo "  SKIP  no venv -- probe_model_gate is UNVERIFIED"
fi

# ---- MLOps: a published forecast must be scored against what happened -------
#
# The mlops row read 5/5 green while nothing had ever compared a published
# number to the week that arrived. Backtest MAE is not that measurement: a
# rolling-origin fold scores a model against history it was fitted around.
#
# Two controls, and the second one exists because of a defect made while
# writing this node: the `actual` CTE grouped by geo_code and visit_type
# without selecting or joining on them, so the LEFT JOIN fanned 2 forecasts
# out to 44 rows. It reported "22/44 勝過持平基準" -- a healthy-looking sample
# size assembled entirely from duplicates. Nothing about that string looks
# wrong; only the invariant catches it.
run_cmd python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/platform/statusdag')
import dag
# FIVE columns: horizon|target|scored|pending|won. The query gained the
# horizon on 2026-09-08 when platform/mlops/pipeline_metrics.py became its
# second reader, and the TARGET on 2026-09-09 when a second disease was
# published -- until then the two targets summed into one bucket and the
# sentence could not say which model the scored one belonged to. These stubs
# caught BOTH changes on the day they were made, which is what a stub of a
# query's SHAPE is for.
dag.psql = lambda sql, timeout=20: '2|pct_ili|1|1|1'
print('WIN_CASE', dag.probe_forecast_score())
dag.psql = lambda sql, timeout=20: '2|pct_ili|2|0|1'
print('LOSS_CASE', dag.probe_forecast_score())
dag.psql = lambda sql, timeout=20: '2|pct_ili|0|2|0'
print('PENDING_CASE', dag.probe_forecast_score())
dag.psql = lambda sql, timeout=20: None
print('NO_DB_CASE', dag.probe_forecast_score())
# Two horizons at once: the board must SUM them, not report the first row.
# Nothing exercised this before, because t+1 has never published anything --
# so the summation was untested code that would first run on the day t+1
# finally passed the gate.
dag.psql = lambda sql, timeout=20: '1|pct_ili|3|0|2\n2|pct_ili|1|1|1'
print('TWO_HORIZON_CASE', dag.probe_forecast_score())
# TWO TARGETS at once. The sum is identical to the single-target case above,
# which is the whole problem: 4 scored, 3 won reads the same whether both
# models are mediocre or one is perfect and the other is broken. The sentence
# must name them once more than one target has published.
dag.psql = lambda sql, timeout=20: '2|pct_flu|2|0|2\n2|pct_ili|2|1|1'
print('TWO_TARGET_CASE', dag.probe_forecast_score())
"
assert_rc 0 "probe_forecast_score classifies scored, pending and no-answer"
assert_output_contains "WIN_CASE ('ok', '已發布預測事後評分：1/1 勝過持平基準（n=1" \
  "a scored win reports n, so 1/1 cannot be read as a track record"
assert_output_contains "LOSS_CASE ('warn'" \
  "a published forecast that lost to persistence is amber, not green"
assert_output_contains "TWO_HORIZON_CASE ('warn', '已發布預測事後評分：3/4 勝過持平基準" \
  "two horizons are summed into one sentence, not reported one row deep"
assert_output_contains "TWO_TARGET_CASE" \
  "two targets can both publish at the same horizon"
assert_output_contains "pct_flu t+2 2/2" \
  "and the sentence names each target's own record, not only their sum"
assert_output_contains "pct_ili t+2 1/2" \
  "including the one that is doing worse, which the sum would have hidden"
assert_output_contains "PENDING_CASE ('ok', '2 筆已發布預測的目標週尚未到" \
  "a t+2 forecast that cannot be scored yet is not a failure"
assert_output_contains "NO_DB_CASE ('unknown'" \
  "no answer from the database is not the same claim as an unscored forecast"

# The invariant, against the real database: the probe cannot score more
# forecasts than exist. This is what a fan-out looks like from the outside.
if docker exec station2-twin-db-1 true 2>/dev/null; then
  run_cmd python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/platform/statusdag')
import dag
n = int(dag.psql('SELECT count(*) FROM forecast;'))
state, detail = dag.probe_forecast_score()
import re
got = sum(int(x) for x in re.findall(r'n=(\d+)|另 (\d+) 筆', detail) for x in x if x)
print('FORECAST_ROWS', n)
print('PROBE_ACCOUNTS_FOR', got)
print('NO_FANOUT', got <= n)
"
  assert_rc 0 "the scoring probe runs against the live pilot database"
  assert_output_contains "NO_FANOUT True" \
    "the probe accounts for no more rows than the forecast table holds"
else
  echo "  SKIP  pilot database not running -- the fan-out invariant is UNVERIFIED"
fi

# ---- the empty-fetch rule, verified by EVALUATION (docs/Backlog.md §19) ----
#
# ADR-0007's origin is in this very file's subject: WidespreadGeoDrift shipped
# without an explicit group_left, PARSED, reported SUCCESS from
# `promtool check rules`, and failed every evaluation for 11 hours.
# SourcePublishedNothingNew joins the same two metric families, so parsing is
# not evidence for it either.
if command -v docker >/dev/null 2>&1 && timeout 20 docker info >/dev/null 2>&1; then
  PROMDIR="$REPO_ROOT/platform/observability/prometheus"
  ef_promtool() {
    timeout 180 docker run --rm -v "$PROMDIR:/p:ro" \
      --entrypoint promtool "$(prom_image)" "$@"
  }

  run_cmd ef_promtool test rules /p/rule_tests/dataops-emptyfetch_test.yml
  assert_rc 0 "the empty-fetch rule fires past the cadence and stays silent inside it"

  EF_RULES="$PROMDIR/alerts/dataops.yml"
  EF_BAK="$(mktemp)"
  cp "$EF_RULES" "$EF_BAK"
  on_exit 'cp "$EF_BAK" "$EF_RULES"; rm -f "$EF_BAK"'

  # THE mutation for this rule. Without group_left the join is many-to-many,
  # evaluation errors, and the alert can never fire while still parsing.
  mutate "$EF_RULES" 's| group_left(provenance)||' "remove the group_left modifier"
  ef_promtool test rules /p/rule_tests/dataops-emptyfetch_test.yml >/dev/null 2>&1
  EF_MUT1=$?
  cp "$EF_BAK" "$EF_RULES"

  # Collapse the cadence multiplier. An annual source unchanged for 100 days
  # would then alert -- the behaviour that makes a whole alert class
  # unreadable, and the reason the threshold is per-source at all.
  mutate "$EF_RULES" 's|(3 \* dataops_source_expected_interval_seconds)|(0.001 * dataops_source_expected_interval_seconds)|' \
    "collapse the cadence multiplier"
  ef_promtool test rules /p/rule_tests/dataops-emptyfetch_test.yml >/dev/null 2>&1
  EF_MUT2=$?
  cp "$EF_BAK" "$EF_RULES"

  if [ "$EF_MUT1" -ne 0 ]; then
    _pass "the control fails when group_left is removed (the ADR-0007 defect)"
  else
    _fail "the control fails when group_left is removed" "mutant survived"
  fi
  if [ "$EF_MUT2" -ne 0 ]; then
    _pass "the control fails when the cadence multiplier is collapsed"
  else
    _fail "the control fails when the cadence multiplier is collapsed" "mutant survived"
  fi
  if cmp -s "$EF_BAK" "$EF_RULES"; then
    _pass "dataops.yml is byte-identical after mutation"
  else
    _fail "dataops.yml is byte-identical after mutation" "the restore did not"
  fi

  # ---- the drift rule's denominator floor (docs/Backlog.md T13) -----------
  #
  # The floor is a SECOND vector match on the rule that already shipped a
  # broken first one. A wrong label in `on(...)` drops every series, the rule
  # goes permanently silent, and silence reads exactly like "nothing is
  # drifting". Parsing cannot tell those apart; evaluation can.
  run_cmd ef_promtool test rules /p/rule_tests/dataops-geodrift_test.yml
  assert_rc 0 "the drift rule fires at N=19, stays silent at N=3, and survives a scrape gap"

  # Drop the floor: the 猩紅熱 shape (3 comparable geographies, share 1.0)
  # alerts again. This is the defect the floor exists for, measured
  # 2026-09-04.
  mutate "$EF_RULES" 's|comparable_count >= 11|comparable_count >= 0|' \
    "drop the denominator floor"
  ef_promtool test rules /p/rule_tests/dataops-geodrift_test.yml >/dev/null 2>&1
  GD_MUT1=$?
  cp "$EF_BAK" "$EF_RULES"

  # Move the floor by one. `> 11` written where `>= 11` was meant passes every
  # other case in the control file and silently loses the boundary disease.
  mutate "$EF_RULES" 's|comparable_count >= 11|comparable_count >= 12|' \
    "move the floor off the boundary"
  ef_promtool test rules /p/rule_tests/dataops-geodrift_test.yml >/dev/null 2>&1
  GD_MUT2=$?
  cp "$EF_BAK" "$EF_RULES"

  if [ "$GD_MUT1" -ne 0 ]; then
    _pass "the control fails when the denominator floor is dropped"
  else
    _fail "the control fails when the denominator floor is dropped" "mutant survived"
  fi
  if [ "$GD_MUT2" -ne 0 ]; then
    _pass "the control fails when the floor moves off the boundary"
  else
    _fail "the control fails when the floor moves off the boundary" "mutant survived"
  fi
  if cmp -s "$EF_BAK" "$EF_RULES"; then
    _pass "dataops.yml is byte-identical after the floor mutations"
  else
    _fail "dataops.yml is byte-identical after the floor mutations" "the restore did not"
  fi

  # ---- the lookback that survives a scrape gap ---------------------------
  #
  # `for` needs the condition true at EVERY evaluation, and this host sleeps.
  # Measured 2026-09-04/05: nine gaps of 4-14 minutes in sixteen hours, and
  # the one real signal this rule has caught flapped firing/pending for thirty
  # hours while the condition never changed. A bare instant vector cannot
  # express "still true" across a gap.
  mutate "$EF_RULES" 's|max_over_time(dataops:yoy_geo_drift_share\[1h\])|dataops:yoy_geo_drift_share|' \
    "drop the lookback"
  ef_promtool test rules /p/rule_tests/dataops-geodrift_test.yml >/dev/null 2>&1
  GD_MUT3=$?
  cp "$EF_BAK" "$EF_RULES"

  # A window shorter than the measured gaps is the same defect wearing a
  # number, and it would pass every other case in the control file.
  mutate "$EF_RULES" 's|dataops:yoy_geo_drift_share\[1h\]|dataops:yoy_geo_drift_share[10m]|' \
    "shrink the lookback below the measured gap"
  ef_promtool test rules /p/rule_tests/dataops-geodrift_test.yml >/dev/null 2>&1
  GD_MUT4=$?
  cp "$EF_BAK" "$EF_RULES"

  if [ "$GD_MUT3" -ne 0 ]; then
    _pass "the control fails when the lookback is dropped"
  else
    _fail "the control fails when the lookback is dropped" "mutant survived"
  fi
  if [ "$GD_MUT4" -ne 0 ]; then
    _pass "the control fails when the lookback is shorter than the gap"
  else
    _fail "the control fails when the lookback is shorter than the gap" "mutant survived"
  fi
  if cmp -s "$EF_BAK" "$EF_RULES"; then
    _pass "dataops.yml is byte-identical after the lookback mutations"
  else
    _fail "dataops.yml is byte-identical after the lookback mutations" "the restore did not"
  fi
else
  echo "  SKIP  no docker -- the empty-fetch rule is UNVERIFIED by evaluation"
fi


suite_summary

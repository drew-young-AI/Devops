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
trap 'rm -rf "$OUT_DIR"' EXIT

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

# ---- promtool: Prometheus' own parser, not ours ---------------------------
if command -v docker >/dev/null 2>&1; then
  run_cmd docker run --rm -v "$REPO_ROOT/platform/observability/prometheus/alerts:/a:ro" \
      --entrypoint promtool prom/prometheus:v3.6.0 check rules /a/dataops.yml
  assert_rc 0 "promtool accepts the rules"
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

suite_summary

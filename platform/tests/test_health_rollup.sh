#!/usr/bin/env bash
# The health rollup must find what nobody reads, and must refuse to be vacuous.
#
# WHY THIS SUITE EXISTS (2026-09-01).
#
# ADR-0006 recorded a problem and prescribed a remedy but shipped neither:
# `evidence/observability` had grown to 1,215 identical snapshots that no agent
# and no human would ever read, and the ADR's conclusion was "收斂要用彙總,
# 不是用 find -mtime -delete". `rollup_health.py` is that aggregation.
#
# The first run over the real evidence proved the ADR's point by finding a
# 73.7-hour unbroken window (2026-08-21 -> 2026-08-24) in which Prometheus and
# Alertmanager both refused connections. The probe wrote ~200 snapshots saying
# exactly that, every 15 minutes, for three days. Nobody opened one.
#
# WHY THE CONTROLS ARE SYNTHETIC.
#
# Running the detector against the real directory proves almost nothing: that
# history is mostly clean, so a detector hardwired to return "no episodes
# found" would pass against it on most days, and would pass forever once the
# platform stabilised. Each check below therefore FABRICATES the condition --
# an outage, a gap, an empty directory -- and requires the detector to report
# it. A detector that cannot be made to fire on demand is not a detector.
#
# The negative control matters just as much: evenly spaced, all-ok snapshots
# must produce zero episodes and zero gaps. A "detector" that fires on
# everything is as useless as one that fires on nothing, and is harder to
# notice, because its output looks like vigilance.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="health-rollup"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== health snapshots must aggregate into an answer, not a pile =="

ROLLUP="$REPO_ROOT/platform/observability/rollup_health.py"

# Builds a directory of synthetic snapshots.
#   synth <dir> <count> <start_epoch> <step_s> <ok:true|false>
# Written as one helper rather than fixture files so each control states its
# own shape inline: a reader can see what "a 6-hour outage" means here without
# opening another directory.
synth() {
  local dir="$1" count="$2" start="$3" step="$4" ok="$5"
  local i epoch stamp verdict
  mkdir -p "$dir"
  for i in $(seq 0 $((count - 1))); do
    epoch=$((start + i * step))
    stamp="$(python3 -c "
import datetime,sys
print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ'))" "$epoch")"
    if [ "$ok" = "true" ]; then verdict=HEALTHY; else verdict=UNKNOWN; fi
    cat > "$dir/health_${stamp}.json" <<EOF
{
  "verdict": "$verdict",
  "exit_code": 0,
  "checked_at": "$(python3 -c "
import datetime,sys
print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$epoch")",
  "monitoring_integrity": [
    {"check": "prometheus_reachable", "ok": $ok, "detail": "synthetic"}
  ],
  "integrity_blockers": [],
  "active_alerts": [],
  "scrape_targets": {},
  "sources": {}
}
EOF
  done
}

# run_rollup <snapshot_dir> -- isolates every output path inside the sandbox so
# a test run can never touch the real evidence or the live textfile directory.
# Without HEALTH_ROLLUP_PROM pointed away, a passing test would overwrite the
# metrics node-exporter is serving with numbers derived from fabricated data.
run_rollup() {
  local dir="$1"
  run_cmd env \
    HEALTH_SNAPSHOT_DIR="$dir" \
    HEALTH_ROLLUP_JSON="$dir/rollup.json" \
    HEALTH_ROLLUP_PROM="$dir/rollup.prom" \
    python3 "$ROLLUP" --json
}

# --- control 1: an empty directory must be refused, not reported clean -------
#
# This is the failure the whole platform is organised against. Over zero
# samples, "every check passed" is true, and a rollup that answered HEALTHY
# would write a green .prom that Prometheus carries forward indefinitely.
EMPTY="$(mktemp -d)"
run_rollup "$EMPTY"
assert_rc 1 "refuses to summarise an empty snapshot directory"
assert_output_contains "vacuous" "says WHY it refused, not just that it failed"
if [ -f "$EMPTY/rollup.prom" ]; then
  _fail "writes no metrics when it has nothing to summarise" "rollup.prom was created"
else
  _pass "writes no metrics when it has nothing to summarise"
fi
rm -rf "$EMPTY"

# --- control 2: a fabricated 6-hour outage must be reported as ONE episode ---
#
# 24 consecutive not-ok snapshots at the nominal 900s cadence. Reported as 24
# scattered samples this reads like flapping; the number an incident review
# needs is the 6-hour span.
OUTAGE="$(mktemp -d)"
synth "$OUTAGE" 24 1756000000 900 false
run_rollup "$OUTAGE"
assert_rc 0 "summarises a directory of failing snapshots"
EP_COUNT="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(len([e for e in d['episodes'] if e['check']=='prometheus_reachable']))" "$OUTAGE/rollup.json" 2>/dev/null || echo ERR)"
assert_equals "1" "$EP_COUNT" "catches: 24 consecutive failures collapse into one episode"
EP_SECS="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(max(e['duration_s'] for e in d['episodes'] if e['check']=='prometheus_reachable'))" "$OUTAGE/rollup.json" 2>/dev/null || echo ERR)"
assert_equals "20700" "$EP_SECS" "reports the episode's real duration (23 x 900s)"
rm -rf "$OUTAGE"

# --- control 3: a fabricated hole must be reported as a coverage gap ---------
#
# "We looked and it was broken" and "we never looked" must not be summed.
# Only the first is evidence. This builds ten normal samples, then jumps four
# hours before continuing -- the shape a sleeping laptop leaves behind.
GAP="$(mktemp -d)"
synth "$GAP" 10 1756000000 900 true
synth "$GAP" 10 $((1756000000 + 10 * 900 + 14400)) 900 true
run_rollup "$GAP"
assert_rc 0 "summarises a directory with a hole in it"
GAP_COUNT="$(python3 -c "
import json,sys
print(len(json.load(open(sys.argv[1]))['coverage_gaps']))" "$GAP/rollup.json" 2>/dev/null || echo ERR)"
assert_equals "1" "$GAP_COUNT" "catches: a 4-hour hole where no snapshot was written"
GAP_VERDICTS="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for e in d['episodes']))" "$GAP/rollup.json" 2>/dev/null || echo ERR)"
assert_equals "0" "$GAP_VERDICTS" "does not report the hole as a health failure -- absence is not evidence"
rm -rf "$GAP"

# --- control 4: clean input must stay quiet ---------------------------------
#
# The negative control. A detector that fires on everything looks like
# vigilance and is worthless.
CLEAN="$(mktemp -d)"
synth "$CLEAN" 40 1756000000 900 true
run_rollup "$CLEAN"
assert_rc 0 "summarises a clean directory"
CLEAN_SUM="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print('%d/%d/%s' % (len(d['episodes']), len(d['coverage_gaps']), d['verdicts'].get('HEALTHY')))" "$CLEAN/rollup.json" 2>/dev/null || echo ERR)"
assert_equals "0/0/40" "$CLEAN_SUM" "does not cry wolf: 40 evenly spaced healthy samples"
rm -rf "$CLEAN"

# --- the emitted metrics must be parseable by the collector -----------------
#
# node-exporter's textfile collector drops a whole file on a parse error, and
# the symptom is the metric silently disappearing -- which on a dashboard is
# indistinguishable from the platform being fine. So the format is checked
# here rather than trusted.
FMT="$(mktemp -d)"
synth "$FMT" 20 1756000000 900 true
run_cmd env \
  HEALTH_SNAPSHOT_DIR="$FMT" \
  HEALTH_ROLLUP_JSON="$FMT/rollup.json" \
  HEALTH_ROLLUP_PROM="$FMT/rollup.prom" \
  python3 "$ROLLUP"
assert_rc 0 "writes the textfile output"
assert_file_exists "$FMT/rollup.prom" "textfile metrics written for the collector"
BAD_LINES="$(python3 -c "
import re,sys
bad=0
for line in open(sys.argv[1]):
    line=line.rstrip('\n')
    if not line or line.startswith('#'):
        continue
    if not re.match(r'^[a-zA-Z_:][a-zA-Z0-9_:]*(\{[^}]*\})? -?[0-9.eE+-]+\$', line):
        bad+=1
print(bad)" "$FMT/rollup.prom" 2>/dev/null || echo ERR)"
assert_equals "0" "$BAD_LINES" "every metric line matches the Prometheus exposition format"
rm -rf "$FMT"

# --- the real evidence must actually be covered -----------------------------
#
# Tier 1 runs on machines that have the repo but not necessarily its history,
# so this is a presence check, not a threshold: if snapshots exist, the rollup
# must account for all of them. A rollup that silently summarised a subset
# would understate every outage in it.
REAL_DIR="$REPO_ROOT/evidence/observability"
REAL_COUNT="$(find "$REAL_DIR" -name 'health_2*.json' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$REAL_COUNT" = "0" ]; then
  echo "  SKIP  no committed snapshots on this checkout -- real coverage is UNVERIFIED"
else
  SCRATCH="$(mktemp -d)"
  run_cmd env \
    HEALTH_SNAPSHOT_DIR="$REAL_DIR" \
    HEALTH_ROLLUP_JSON="$SCRATCH/rollup.json" \
    HEALTH_ROLLUP_PROM="$SCRATCH/rollup.prom" \
    python3 "$ROLLUP" --json
  assert_rc 0 "summarises the real evidence directory"
  ACCOUNTED="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(d['snapshots'] + d['snapshots_undated'] + d['snapshots_unreadable'])" "$SCRATCH/rollup.json" 2>/dev/null || echo ERR)"
  assert_equals "$REAL_COUNT" "$ACCOUNTED" "every snapshot on disk is accounted for, none silently dropped"
  rm -rf "$SCRATCH"
fi

suite_summary

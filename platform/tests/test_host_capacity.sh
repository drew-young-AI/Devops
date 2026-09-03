#!/usr/bin/env bash
# Host disk capacity: the metric, the rules, and proof the rules can go red.
#
# WHY THIS SUITE EXISTS.
#
# On 2026-09-03 the macOS data volume reached 100%. Prometheus stopped
# answering, Docker's engine died at 11:23, every container went down. At that
# moment this platform had 14 alert rules, 91 registered capabilities and 777
# passing assertions -- and not one of them referenced free disk space. The
# monitoring could not report the resource it was itself running on running
# out. 「監控系統被它沒有監控的東西弄停了」.
#
# The rules added afterwards are only worth as much as the proof that they
# fire. Four things are checked here, in increasing order of what they buy:
#
#   1. the exporter produces the metrics          (cheap, catches typos)
#   2. it still does so under `env -i`            (launchd gives a scheduled
#                                                  job no HOME; the first
#                                                  version failed on every
#                                                  scheduled run and none by
#                                                  hand)
#   3. every metric the rules NAME is produced    (catches the phantom-metric
#                                                  failure: parses, passes
#                                                  promtool, can never fire)
#   4. the rules go red on synthetic data, and    (the only one that is
#      the test itself goes red when the rules     actually evidence)
#      are mutated
#
# The fault is simulated, never injected: CLAUDE.md §5c names 「填滿磁碟」 as
# forbidden on this host, and filling the disk to test the disk alert would
# kill the process running the test.

set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="host-capacity"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== host capacity: the disk that stopped the platform is now measured =="

EXPORTER="$REPO_ROOT/platform/observability/host_disk_metrics.sh"
RULES="$REPO_ROOT/platform/observability/prometheus/alerts/host-capacity.yml"
RULETEST="$REPO_ROOT/platform/observability/prometheus/rule_tests/host-capacity_test.yml"

assert_file_exists "$EXPORTER" "host_disk_metrics.sh exists"
assert_file_exists "$RULES" "host-capacity.yml exists"
assert_file_exists "$RULETEST" "the rules have a synthetic control file"

# ---- 1. the exporter runs and writes atomically ---------------------------
OUT_DIR="$(mktemp -d)"
OUT="$OUT_DIR/host_disk.prom"
trap 'rm -rf "$OUT_DIR"' EXIT

run_cmd env HOST_DISK_PROM="$OUT" "$EXPORTER"
assert_rc 0 "the exporter runs"
assert_file_exists "$OUT" "and writes a .prom file"

# node-exporter drops the WHOLE scrape on a malformed textfile, so a
# half-written file does not lose one metric -- it loses every metric in the
# directory, including the DAG board. A surviving .tmp means the rename did not
# happen.
if [ -f "$OUT.tmp" ]; then
  _fail "the write is atomic" "$OUT.tmp was left behind"
else
  _pass "the write is atomic (no .tmp left behind)"
fi

# ---- 2. THE JOIN: every metric the rules name must be produced ------------
# Written against the exporter's own output rather than a live Prometheus, so
# it still holds when nothing is scraping -- which is the state this suite is
# most likely to be run in.
# Names are read out of the parsed `expr:` fields, not grepped off the whole
# file. Grepping also matches the exporter's own filename inside the runbook
# annotations and invents a metric called host_disk_metrics that nothing
# produces -- a test that fails on its own false positive is a test people
# learn to ignore.
PRODUCED="$(grep -oE '^host_[a-z_]+' "$OUT" | sort -u)"
NAMED="$(python3 "$SUITE_DIR/rule_metric_names.py" "$RULES")"
MISSING=""
for m in $NAMED; do
  grep -qx "$m" <<<"$PRODUCED" || MISSING="$MISSING $m"
done
assert_equals "" "$MISSING" "every host_* metric named in the rules is actually produced"

# And the reverse direction, as a WARNING not a failure: a produced metric with
# no rule is a deliberate choice often enough (the two Docker.raw gauges are
# reported for context, not alerted on) that failing on it would be wrong.
for m in $PRODUCED; do
  grep -q "$m" "$RULES" || echo "  NOTE  $m is exported but no rule references it"
done

# ---- the volume being measured must be the real one, ON THIS OS -----------
#
# On Apple Silicon `df /` reports the sealed read-only system snapshot, which
# sits at ~100% used permanently: a disk alert pointed at it would either
# scream forever or describe a volume that cannot fill. The data volume is
# /System/Volumes/Data. On Linux there is no such split and `/` is correct.
#
# Asserted per-OS rather than against the macOS path, because the first version
# hardcoded /System/Volumes/Data and CI (Linux) went red within hours -- the
# platform runs on two operating systems now (ADR-0008) and this suite has to
# be true on both.
case "$(uname -s)" in
  Darwin) WANT_MOUNT="/System/Volumes/Data" ;;
  *)      WANT_MOUNT="/" ;;
esac
if grep -qF "mountpoint=\"$WANT_MOUNT\"" "$OUT"; then
  _pass "the mount point is the right volume for $(uname -s) ($WANT_MOUNT)"
else
  _fail "the mount point is the right volume for $(uname -s) ($WANT_MOUNT)" \
        "no $WANT_MOUNT series in $OUT"
fi

# The staleness gauge is what keeps the two threshold rules honest when the
# disk is too full for the exporter to write. Without it they evaluate a frozen
# value and stay green through the exact event they exist for.
if grep -q '^host_disk_metrics_generated_seconds ' "$OUT"; then
  _pass "the exporter timestamps its own output so staleness is detectable"
else
  _fail "the exporter timestamps its own output so staleness is detectable" \
        "no host_disk_metrics_generated_seconds in $OUT"
fi

# ---- it survives the environment the SCHEDULER gives it -------------------
# launchd hands a scheduled job an almost empty environment. Under `set -u` a
# bare $HOME is an unbound-variable error, so a script can work perfectly by
# hand and fail on every single scheduled run -- 「登記為存在，但不執行」, and
# the job's own freshness check is the only thing that would ever say so.
# `env -i` is the cheapest honest reproduction of that environment.
BARE_OUT="$OUT_DIR/bare.prom"
run_cmd env -i /bin/bash "$EXPORTER" --stdout
assert_rc 0 "the exporter runs under a bare launchd-style environment (env -i)"
cp "$LAST_STDOUT" "$BARE_OUT" 2>/dev/null
if [ "$(grep -cE '^host_' "$BARE_OUT" 2>/dev/null)" = "$(grep -cE '^host_' "$OUT")" ]; then
  _pass "and emits the same metrics it does interactively"
else
  _fail "and emits the same metrics it does interactively" \
        "bare: $(grep -cE '^host_' "$BARE_OUT" 2>/dev/null), interactive: $(grep -cE '^host_' "$OUT")"
fi

# ---- the job is scheduled --------------------------------------------------
# A metric nothing writes on a schedule is a metric that was right once. The
# scheduler is what turns it into monitoring.
JOBS="$REPO_ROOT/platform/scheduler/jobs.conf"
if grep -q '^disk|' "$JOBS"; then
  _pass "the exporter is registered as a scheduled job"
else
  _fail "the exporter is registered as a scheduled job" "no 'disk|' line in jobs.conf"
fi

# ---- 3. the synthetic control ---------------------------------------------
if ! command -v docker >/dev/null 2>&1 || ! timeout 20 docker info >/dev/null 2>&1; then
  echo "  SKIP  no docker -- promtool rule evaluation is UNVERIFIED"
  echo "        (this is the LOUD half of the suite: without it, all that has"
  echo "         been shown is that the metrics exist, not that they alert)"
  suite_summary
  exit $?
fi

PROMDIR="$REPO_ROOT/platform/observability/prometheus"
promtool() {
  timeout 180 docker run --rm -v "$PROMDIR:/p:ro" \
    --entrypoint promtool "$(prom_image)" "$@"
}

run_cmd promtool check rules /p/alerts/host-capacity.yml
assert_rc 0 "promtool parses the rules"

run_cmd promtool test rules /p/rule_tests/host-capacity_test.yml
assert_rc 0 "the rules FIRE on a synthetic low disk, and stay silent on a healthy one"

# ---- the control must be able to fail -------------------------------------
# 「沒有被證明能失敗的守衛，和不能失敗的守衛，從輸出上分不出來」. A rule test
# that passes proves nothing until it has been shown to fail on a broken rule.
#
# Mutation only, restored in a trap: the rules file is edited in place and put
# back even if the suite is interrupted (§5c -- no unrestored damage).
BAK="$(mktemp)"
cp "$RULES" "$BAK"
restore_rules() { cp "$BAK" "$RULES"; rm -f "$BAK"; }
trap 'restore_rules; rm -rf "$OUT_DIR"' EXIT INT TERM

# Loosen the warning threshold by an order of magnitude. A control that cannot
# see this is not measuring the threshold at all.
mutate "$RULES" 's|host_filesystem_size_bytes < 0.10|host_filesystem_size_bytes < 0.01|' \
  "loosen the warning threshold by an order of magnitude"
promtool test rules /p/rule_tests/host-capacity_test.yml >/dev/null 2>&1
MUT1=$?
cp "$BAK" "$RULES"

# Remove the `for:` window, so a single scrape dip would page someone. The
# empty-set mutation that used to sit here moved with the staleness rule into
# test_exporter_freshness.sh.
# `for: 15m`, not `for: 5m`. The 5m one belongs to HostDiskCritical, whose
# controls would still pass without it -- a mutation the suite cannot kill
# says nothing about the suite. 15m is HostDiskLow's, and the paired control
# at eval_time 14m exists precisely to notice its absence.
mutate "$RULES" 's|for: 15m|for: 0m|' "drop HostDiskLow's for: clause"
promtool test rules /p/rule_tests/host-capacity_test.yml >/dev/null 2>&1
MUT2=$?
cp "$BAK" "$RULES"

if [ "$MUT1" -ne 0 ]; then
  _pass "the control fails when the threshold is loosened (mutation killed)"
else
  _fail "the control fails when the threshold is loosened" "mutant survived: rc=0"
fi
if [ "$MUT2" -ne 0 ]; then
  _pass "the control fails when the for: window is removed (mutation killed)"
else
  _fail "the control fails when the for: window is removed" "mutant survived: rc=0"
fi

# The restore is itself asserted. A mutation suite that silently leaves the
# repository modified is worse than no mutation suite.
if cmp -s "$BAK" "$RULES"; then
  _pass "the rules file is byte-identical after mutation"
else
  _fail "the rules file is byte-identical after mutation" "the restore did not"
fi

suite_summary

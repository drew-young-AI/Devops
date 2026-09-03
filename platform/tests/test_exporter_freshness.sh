#!/usr/bin/env bash
# The freshness rules must cover every exporter, at a threshold derived from
# that exporter's actual cadence.
#
# WHY A SUITE AND NOT A THIRD ALERT.
#
# alerts/exporter-freshness.yml watches the .prom files for going stale. The
# gap it cannot watch is a NEW .prom file appearing with no threshold at all:
# that file would simply never be checked, and an unchecked exporter reads
# exactly like a healthy one. Writing that as another alert would mean a rule
# watching the rules -- the regress the guard-on-a-guard question is really
# about.
#
# It stops here instead, and the reason is a property rather than a preference.
# The uncovered-file condition is a fact about the CONFIGURATION: it changes
# only when a human edits a file, never at runtime. A test runs exactly when
# that happens (pre-commit, CI) and costs nothing in between, whereas an alert
# would re-derive an unchanged answer every 15 seconds forever. Runtime
# problems get alerts; configuration problems get tests. The chain is two
# links, not infinite, because the second link is a different KIND of check.
#
# What is asserted:
#   1. every .prom file the exporters write has a threshold
#   2. every threshold names a file that is actually written
#   3. every threshold is exactly 3x its writer job's interval in jobs.conf
#   4. every writer job named in the table exists in jobs.conf
#
# (3) is what stops the table being decoration. Without it the comment could
# say anything and the rule could say anything else.

set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="exporter-freshness"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== exporter freshness: a frozen .prom is indistinguishable from a steady one =="

RULES="$REPO_ROOT/platform/observability/prometheus/alerts/exporter-freshness.yml"
RULETEST="$REPO_ROOT/platform/observability/prometheus/rule_tests/exporter-freshness_test.yml"
JOBS="$REPO_ROOT/platform/scheduler/jobs.conf"
COMPOSE="$REPO_ROOT/platform/observability/compose.yaml"
PROMDIR_EVIDENCE="$REPO_ROOT/evidence/statusdag"

assert_file_exists "$RULES" "exporter-freshness.yml exists"
assert_file_exists "$RULETEST" "it has a synthetic control"
assert_file_exists "$JOBS" "jobs.conf exists"

# ---- the four cross-checks ------------------------------------------------
run_cmd python3 "$SUITE_DIR/exporter_freshness_check.py" \
  --rules "$RULES" --jobs "$JOBS" --textfile-dir "$PROMDIR_EVIDENCE" \
  --compose "$COMPOSE"
assert_rc 0 "table, expression, jobs.conf, compose mount and the files agree"
sed 's/^/  /' "$LAST_STDOUT"
[ -s "$LAST_STDERR" ] && sed 's/^/  ! /' "$LAST_STDERR"

# ---- the cross-check must be able to disagree -----------------------------
# A checker that has never been seen to fail and one that cannot fail produce
# the same output. Three synthetic disagreements, each in a copy, none of them
# touching the real files.
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT

check_fixture() {  # <description> -- expects rc 1
  python3 "$SUITE_DIR/exporter_freshness_check.py" \
    --rules "$FIX/rules.yml" --jobs "$FIX/jobs.conf" \
    --textfile-dir "$FIX/textfile" --compose "$FIX/compose.yaml" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" -ne 0 ]; then _pass "catches: $1"; else _fail "catches: $1" "rc=0"; fi
}

reset_fixture() {
  cp "$RULES" "$FIX/rules.yml"
  cp "$JOBS" "$FIX/jobs.conf"
  cp "$COMPOSE" "$FIX/compose.yaml"
  rm -rf "$FIX/textfile"; mkdir -p "$FIX/textfile"
  for f in "$PROMDIR_EVIDENCE"/*.prom; do : > "$FIX/textfile/$(basename "$f")"; done
}

# The clean copy must PASS, or the three failures below prove nothing.
reset_fixture
run_cmd python3 "$SUITE_DIR/exporter_freshness_check.py" \
  --rules "$FIX/rules.yml" --jobs "$FIX/jobs.conf" --textfile-dir "$FIX/textfile" \
  --compose "$FIX/compose.yaml"
assert_rc 0 "does not cry wolf: an unmodified copy agrees"

# 1. cadence changed in jobs.conf, threshold left behind. This is the one that
#    actually happens: someone tunes a schedule and never looks at the rules.
reset_fixture
# `#` as the sed delimiter, not `|`: jobs.conf is a pipe-separated file and a
# pipe delimiter would end the pattern in the middle of the field.
sed_i 's#^disk|300|#disk|60|#' "$FIX/jobs.conf"
check_fixture "a cadence changed in jobs.conf without the threshold"

# 2. a new exporter with no rule -- the gap this whole suite exists for.
reset_fixture
: > "$FIX/textfile/newthing.prom"
check_fixture "a new .prom file that no threshold covers"

# 3. the table and the expression disagree, i.e. the comment became decoration.
reset_fixture
mutate "$FIX/rules.yml" 's#> 2700#> 1234#' "edit the expression, leave the table"
check_fixture "the expression edited while the table still says the old number"

# 4. compose remounts the textfile directory elsewhere. The absent() rule
#    hardcodes that path because absent() cannot carry a regex matcher's
#    labels, so this is the one thing that would silently uncover the
#    never-appeared case.
reset_fixture
sed_i 's#evidence/statusdag:/textfile#evidence/statusdag:/somewhere-else#' "$FIX/compose.yaml"
check_fixture "compose moved the textfile mount out from under the absent() rule"

# ---- the control ----------------------------------------------------------
if ! command -v docker >/dev/null 2>&1 || ! timeout 20 docker info >/dev/null 2>&1; then
  echo "  SKIP  no docker -- rule evaluation is UNVERIFIED"
  suite_summary
  exit $?
fi

PROMDIR="$REPO_ROOT/platform/observability/prometheus"
promtool() {
  timeout 180 docker run --rm -v "$PROMDIR:/p:ro" \
    --entrypoint promtool "$(prom_image)" "$@"
}

run_cmd promtool check rules /p/alerts/exporter-freshness.yml
assert_rc 0 "promtool parses the rules"

run_cmd promtool test rules /p/rule_tests/exporter-freshness_test.yml
assert_rc 0 "a frozen file fires, a fresh one does not, and the cadences differ"

# ---- the control must be able to fail -------------------------------------
BAK="$(mktemp)"
cp "$RULES" "$BAK"
trap 'cp "$BAK" "$RULES"; rm -f "$BAK"' EXIT INT TERM

# Collapse the per-file thresholds onto one number. The suite must notice that
# dag.prom, whose cadence is nine times host_disk's, now alerts nine times too
# early -- otherwise "per-file thresholds" is a claim nothing checks.
mutate "$RULES" 's#> 2700#> 900#' "collapse dag.prom onto host_disk's threshold"
promtool test rules /p/rule_tests/exporter-freshness_test.yml >/dev/null 2>&1
MUT1=$?
cp "$BAK" "$RULES"

# Remove the absent() rule's second operand: dag.prom could then vanish
# entirely with nothing to say so.
mutate "$RULES" 's#or absent(node_textfile_mtime_seconds{file="/textfile/dag.prom"})#or vector(0) > 1#' \
  "remove dag.prom's absent() guard"
promtool test rules /p/rule_tests/exporter-freshness_test.yml >/dev/null 2>&1
MUT2=$?
cp "$BAK" "$RULES"

if [ "$MUT1" -ne 0 ]; then
  _pass "the control fails when the per-file thresholds are collapsed (mutation killed)"
else
  _fail "the control fails when the per-file thresholds are collapsed" "mutant survived"
fi
if [ "$MUT2" -ne 0 ]; then
  _pass "the control fails when a file loses its absent() guard (mutation killed)"
else
  _fail "the control fails when a file loses its absent() guard" "mutant survived"
fi
if cmp -s "$BAK" "$RULES"; then
  _pass "the rules file is byte-identical after mutation"
else
  _fail "the rules file is byte-identical after mutation" "the restore did not"
fi

suite_summary

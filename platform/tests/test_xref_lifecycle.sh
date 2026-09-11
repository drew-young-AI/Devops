#!/usr/bin/env bash
# Do the names in this repository still refer to anything?
#
# WHY THIS SUITE EXISTS (2026-09-11), AND WHY IT IS NOT THE OTHER FIVE AGAIN.
#
# Five closure checks already run here, and every one asks "is X covered, now":
# documents reachable, capabilities described, services and jobs watched by a
# node, artifact fields present, SQL identifiers resolvable. Not one of them
# asks what happens to a NAME when the thing it names is deleted. So on
# 2026-09-10 four nodes were removed from NODES, every suite stayed green, and
# `NEW_SERVICE_GUIDE.md` went on telling readers that `prodlike` (REMOVED) 節點
# 在板面上是 `superseded` -- not stale, FALSE: it is not on the board at all.
#
# First run found, with nobody looking for them:
#   - `prodlike`, REMOVED that day, described as a live board node in two docs
#   - an Alertmanager `inhibit_rules` entry whose source alert was deleted with
#     production-like Compose three weeks earlier -- a routing rule that could
#     not fire, in a file nobody re-reads
#   - the REMOVED `ProductionLikeAllColorsDown` in the README's rule table
#   - four board nodes (`geo`, `dcontract`, `k8s`, `gateleak`) that no
#     non-generated document mentioned at all
#   - B10 meaning two different blocked things, in two documents, with `dag.py`
#     citing the bare id -- this session's own handover had already recorded
#     the wrong one
#
# THE CONTROLS ARE THE POINT, AND TWO OF THEM ARE MY OWN BUGS.
#
# The checker was wrong twice before it was right, both times in the direction
# that reports CLEAN. Both are now permanent controls, because a guard nobody
# has seen fail is indistinguishable from a guard that cannot fail:
#
#   1. Section-scoped markers. Allowing a retirement marker anywhere in the
#      enclosing markdown section silenced the very finding this file was
#      written for: the section around NEW_SERVICE_GUIDE.md:225 contains
#      「`Architecture.md` 已於 2026-09-09 刪除」 -- a marker about a DIFFERENT
#      noun. A marker that does not name the thing it retires proves nothing.
#   2. Row-shaped definitions. Reading Backlog ids as "has an open §27 row"
#      reported T13/T22/T25 as never defined while they sat in that file four
#      times over. Closing an item removes its row and keeps its prose.
#
# The fixture is a real throwaway git repository, built and thrown away in
# under a second, because RETIRED is derived from git history rather than a
# hand-written list -- and a control that stubs out the derivation is testing
# the stub.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="xref-lifecycle"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

XREF="$REPO_ROOT/platform/docs/xref.py"

echo "== the repository's own names still resolve =="
assert_file_exists "$XREF" "xref.py exists"

run_cmd python3 "$XREF"
assert_rc 0 "no dangling, undefined, colliding or undocumented name in the repository"

REAL_JSON="$(mktemp)"
python3 "$XREF" --json > "$REAL_JSON" 2>/dev/null
read -r NS_COUNT NODE_COUNT RETIRED_COUNT <<< "$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
n=d['namespaces']
print(len(n), len(n['node']['defined']),
      sum(len(v['retired']) for v in n.values()))" "$REAL_JSON")"
[ "${NS_COUNT:-0}" -ge 4 ] && _pass "four namespaces resolved ($NS_COUNT)" \
  || _fail "expected >=4 namespaces, got ${NS_COUNT:-none}"
[ "${NODE_COUNT:-0}" -ge 40 ] && _pass "the node enumeration sees the whole board ($NODE_COUNT)" \
  || _fail "node enumeration collapsed to ${NODE_COUNT:-none}"
[ "${RETIRED_COUNT:-0}" -ge 1 ] && _pass "git history yields a non-empty retired set ($RETIRED_COUNT)" \
  || _fail "retired set is empty -- history derivation is not running"

# ── the fixture ────────────────────────────────────────────────────────────
FIX="$(mktemp -d)"
# on_exit, not trap: lib.sh installs its own EXIT handler and a bare trap
# replaces it, which silently drops the suite summary.
on_exit 'rm -rf "$FIX"'

build_fixture() {
  rm -rf "${FIX:?}/"* 2>/dev/null
  mkdir -p "$FIX/platform/statusdag" "$FIX/docs/decisions" \
           "$FIX/platform/observability/prometheus/alerts"
  cat > "$FIX/platform/statusdag/dag.py" <<'PY'
NODES = [
    ("alpha",      "A 節點",     "foundation",  probe_alpha),
    ("beta",       "B 節點",     "foundation",  probe_beta),
]
PY
  cat > "$FIX/platform/observability/prometheus/alerts/a.yml" <<'YML'
      - alert: AlphaDown
      - alert: BetaDown
YML
  printf '| T1 | an item | why | when |\n' > "$FIX/docs/Backlog.md"
  printf -- '---\ntitle: x\n---\n# x\n' > "$FIX/docs/decisions/0001-x.md"
  printf '# fixture\n\n`alpha` 與 `beta` 都在板面上。AlphaDown 與 BetaDown 都會燒。\n' \
    > "$FIX/README.md"
  git -C "$FIX" init -q 2>/dev/null
  git -C "$FIX" add -A >/dev/null 2>&1
  git -C "$FIX" -c user.email=t@t -c user.name=t commit -qm one >/dev/null 2>&1
}

# Delete `beta` and BetaDown, leaving the prose untouched: the exact shape of
# the 2026-09-10 defect.
retire_beta() {
  python3 - "$FIX" <<'PY'
import io, sys, re
r = sys.argv[1]
p = r + "/platform/statusdag/dag.py"
s = io.open(p).read()
io.open(p, "w").write(re.sub(r'^\s+\("beta".*\n', "", s, flags=re.M))
p = r + "/platform/observability/prometheus/alerts/a.yml"
s = io.open(p).read()
io.open(p, "w").write(s.replace("      - alert: BetaDown\n", ""))
PY
  git -C "$FIX" add -A >/dev/null 2>&1
  git -C "$FIX" -c user.email=t@t -c user.name=t commit -qm two >/dev/null 2>&1
}

xref_fix() { XREF_ROOT="$FIX" python3 "$XREF" "$@"; }

echo "== a deleted name still described in prose must be reported =="
build_fixture
run_cmd env XREF_ROOT="$FIX" python3 "$XREF"
assert_rc 0 "fixture is clean before anything is retired"

retire_beta
run_cmd env XREF_ROOT="$FIX" python3 "$XREF"
assert_rc 1 "a retired node still named in a document fails the check"
assert_output_contains "beta" "names the retired node"
assert_output_contains "BetaDown" "names the retired alert -- one mechanism, four namespaces"

echo "== a document that says the name is dead is allowed to mention it =="
printf '# fixture\n\n`alpha` 在板面上。`beta` 已移除。BetaDown 已移除。\n' > "$FIX/README.md"
run_cmd env XREF_ROOT="$FIX" python3 "$XREF"
assert_rc 0 "a name-specific retirement note clears the mention"

echo "== PERMANENT CONTROL: a marker about a different noun must not silence =="
# This is bug #1 above, reproduced exactly: the marker is three lines away, in
# the same section, and it retires something else.
cat > "$FIX/README.md" <<'MD'
# fixture

## 擁有權界線

原本的 `docs/Architecture.md` 已於 2026-09-09 刪除：它的控制平面圖是反的，
而 `beta` 節點在板面上是 `superseded`。
MD
run_cmd env XREF_ROOT="$FIX" python3 "$XREF"
assert_rc 1 'a retirement marker naming a DIFFERENT document does not clear the node'
assert_output_contains "beta" "still reports the dangling node"

echo "== PERMANENT CONTROL: closing an item is not deleting its name =="
# Bug #2: a Backlog id whose table row is gone but whose prose remains is
# DEFINED. Reading only row-shaped lines reported live ids as never defined.
printf '# 待辦\n\nT1 於 2026-09-11 結案，紀錄留在本節。\n' > "$FIX/docs/Backlog.md"
printf '# fixture\n\n`alpha` 在板面上。`beta` 已移除。BetaDown 已移除。見 T1。\n' \
  > "$FIX/README.md"
run_cmd env XREF_ROOT="$FIX" python3 "$XREF"
assert_rc 0 "a closed backlog id cited elsewhere is defined, not dangling"

echo "== an id that resolves to nothing at all is reported =="
# Composed, never written literally: this file is scanned by the checker too,
# and a fixture id spelled out here would be an unresolvable citation in the
# real repository. That is the rule working, not an exception to it.
BAD_ID="T$(( 9 * 11 ))"
printf '# fixture\n\n`alpha` 在板面上。`beta` 已移除。BetaDown 已移除。見 T1 與 %s。\n' \
  "$BAD_ID" > "$FIX/README.md"
run_cmd env XREF_ROOT="$FIX" python3 "$XREF"
assert_rc 1 "a reference to an id no document defines fails the check"
assert_output_contains "$BAD_ID" "names the unresolvable id"

echo "== one id, two owners, and both lists silent about it =="
build_fixture
printf '| T1 | a DIFFERENT item with the same id | why | when |\n' > "$FIX/docs/Other-Plan.md"
git -C "$FIX" add -A >/dev/null 2>&1
git -C "$FIX" -c user.email=t@t -c user.name=t commit -qm three >/dev/null 2>&1
run_cmd env XREF_ROOT="$FIX" python3 "$XREF"
assert_rc 1 "the same row id owned by two documents is reported"
assert_output_contains "COLLIDING" "reports it as a collision, not as a missing name"

printf '| T1 | a DIFFERENT item with the same id | why | when |\n\n本檔的編號和 Backlog.md 不是同一份清單。\n' \
  > "$FIX/docs/Other-Plan.md"
run_cmd env XREF_ROOT="$FIX" python3 "$XREF"
assert_rc 1 "one-sided disambiguation is not enough -- the other list is still silent"

printf '| T1 | an item | why | when |\n\n本檔的編號和 Other-Plan.md 不是同一份清單。\n' \
  > "$FIX/docs/Backlog.md"
run_cmd env XREF_ROOT="$FIX" python3 "$XREF"
assert_rc 0 "a shared id space is allowed once BOTH lists say so"

echo "== a node no document names is reported =="
build_fixture
printf '# fixture\n\n`alpha` 在板面上。AlphaDown 與 BetaDown 都會燒。\n' > "$FIX/README.md"
run_cmd env XREF_ROOT="$FIX" python3 "$XREF"
assert_rc 0 "an undocumented name alone does not fail the run"
assert_output_contains "beta" "but it is reported, so it can be answered"

echo "== a GENERATED page is not documentation =="
printf -- '---\ngenerator: platform/statusdag/stage_report.py\n---\n\n`beta` 節點\n' \
  > "$FIX/docs/Generated.md"
run_cmd env XREF_ROOT="$FIX" python3 "$XREF"
assert_output_contains "beta" "a mention in a generated page does not count as documented"

echo "== an enumeration that found nothing is refused, not reported clean =="
build_fixture
printf 'NODES = [\n]\n' > "$FIX/platform/statusdag/dag.py"
run_cmd env XREF_ROOT="$FIX" python3 "$XREF"
assert_rc 2 "a namespace that resolved to zero definitions refuses to answer"
assert_output_contains "REFUSED" "says why, rather than printing a clean report"

suite_summary

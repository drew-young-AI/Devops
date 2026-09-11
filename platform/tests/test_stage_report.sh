#!/usr/bin/env bash
# The stage report is the artifact a reviewer reads instead of the platform.
# Two things about it can be wrong without anything else failing, and this
# suite exists for exactly those two:
#
#   1. COVERAGE. dag.py grows a node, nobody adds it to LINES, and the node
#      vanishes from the report. An absent stage looks identical to a healthy
#      one -- the report gets quieter as the platform gets worse. Every guard
#      below is verified by deliberately breaking it first.
#
#   2. THE HAND-WRITTEN ASKS. Everything else on the page is probed live; the
#      asks are the one part written by a person, so they are the one part that
#      can outlive the condition they describe. They are bound to a node id
#      plus a substring of that node's CURRENT detail, and that binding is what
#      is tested here -- a note that survives its own reason is worse than no
#      note, because it is read as current.
#
# The mutations run against an in-memory copy of the module's metadata, not
# against the file. Nothing on disk is modified, so there is no restore step
# that can itself fail (CLAUDE.md 5c).

set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="stage-report"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== stage report: coverage guard, ask binding, three renderings =="

REPORT="$REPO_ROOT/platform/statusdag/stage_report.py"
assert_file_exists "$REPORT" "stage_report.py exists"

# Portable temp file. `mktemp -t name.XXXXXX.ext` works on macOS and is
# rejected by GNU coreutils ("Invalid argument"), which requires the X's to end
# the template -- and macOS does not even substitute them, leaving a literal
# "XXXXXX" in the name. A temp DIRECTORY with a fixed filename inside is the one
# form that behaves identically on both, keeps the extension the tool needs, and
# has no create-then-rename race.
HARNESS_DIR="$(mktemp -d)"
HARNESS="$HARNESS_DIR/stage_report_mut.py"
BOARD_SELFCHECK="$HARNESS_DIR/board.json"
on_exit 'rm -rf "$HARNESS_DIR"'

cat > "$HARNESS" <<'PYEOF'
"""Break one guard, and exit 0 only if the guard notices.

Each case mutates the imported module's metadata in memory. The module is
re-imported fresh per process, so no case can leak into another.
"""
import copy, importlib.util, io, json, os, sys, contextlib

REPO = os.environ["REPO_ROOT"]
spec = importlib.util.spec_from_file_location(
    "sr", os.path.join(REPO, "platform", "statusdag", "stage_report.py"))
sr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sr)

# EVERY CASE RUNS AGAINST A FIXTURE BOARD, NOT A LIVE PROBE.
#
# stage_model() with no argument calls dag.build(), which talks to Docker,
# Postgres, kubectl, Prometheus and the scheduler. Seven cases in this harness
# called it, so this suite probed the whole platform seven times to check
# guards that only ever read board["nodes"] against LINES. Measured
# 2026-09-08: 110s, 22% of the entire test run.
#
# It was also non-deterministic evidence (CLAUDE.md §5b): the guards passed or
# failed on a board whose contents depended on what happened to be running.
fspec = importlib.util.spec_from_file_location(
    "fixture_board", os.path.join(REPO, "platform", "tests", "fixture_board.py"))
fixture_board = importlib.util.module_from_spec(fspec)
fspec.loader.exec_module(fixture_board)
BOARD = fixture_board.make_board()

case = sys.argv[1]

def expect_exit(substr):
    """The guard must refuse, and must name the thing it refused over."""
    try:
        sr.stage_model(BOARD)
    except SystemExit as e:
        msg = str(e)
        if substr in msg:
            print("guard fired:", msg.splitlines()[0])
            return 0
        print("guard fired with the WRONG message:", msg)
        return 1
    print("NOT CAUGHT: stage_model() rendered a report with the defect in it")
    return 1

def selfcheck_rc(expect_fail_substr=None, expect_note_substr=None):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = sr.selfcheck(BOARD)
    out = buf.getvalue()
    if expect_fail_substr is not None:
        if rc == 0:
            print("NOT CAUGHT: selfcheck passed with the defect in it"); return 1
        if expect_fail_substr not in out:
            print("caught, but not for this reason:\n" + out); return 1
        print("selfcheck refused:", [l for l in out.splitlines() if l.startswith("FAIL")][0])
        return 0
    if expect_note_substr is not None:
        if rc != 0:
            print("expected a NOTE, got a FAIL:\n" + out); return 1
        if expect_note_substr not in out:
            print("no NOTE about the stale ask:\n" + out); return 1
        print("selfcheck noted:", [l for l in out.splitlines() if l.startswith("NOTE")][0])
        return 0
    print(out.strip())
    return rc

# -- coverage ------------------------------------------------------------
if case == "drop-node":
    sr.LINES[0][3][0]["nodes"] = [n for n in sr.LINES[0][3][0]["nodes"] if n != "vault"]
    sys.exit(expect_exit("does not show"))

if case == "phantom-node":
    sr.LINES[0][3][0]["nodes"].append("no-such-node")
    sys.exit(expect_exit("does not produce"))

# -- ask metadata --------------------------------------------------------
if case == "ask-bad-node":
    sr.ASKS[0] = dict(sr.ASKS[0], node="no-such-node")
    sys.exit(selfcheck_rc(expect_fail_substr="不存在的節點"))

if case == "ask-owner-eng":
    sr.ASKS[0] = dict(sr.ASKS[0], owner="eng")
    sys.exit(selfcheck_rc(expect_fail_substr="owner 是 eng"))

if case == "ask-no-options":
    sr.ASKS[0] = dict(sr.ASKS[0], options=[])
    sys.exit(selfcheck_rc(expect_fail_substr="沒有可選項"))

if case == "ask-bad-ref":
    sr.ASKS[0] = dict(sr.ASKS[0], ref="docs/there-is-no-such-file.md")
    sys.exit(selfcheck_rc(expect_fail_substr="不存在的檔案"))

if case == "ask-duplicate-id":
    sr.ASKS.append(dict(sr.ASKS[0]))
    sys.exit(selfcheck_rc(expect_fail_substr="ask id 重複"))

def _block_node(node_id, detail):
    """Put ONE node into a state that blocks completion, with a chosen detail.

    The fixture board is 47 green nodes, which is right for the coverage
    guards and useless for anything about OWNERSHIP: with nothing blocking,
    the ownership code never runs. A control that cannot enter the branch it
    names measures the branch it already had.
    """
    b = copy.deepcopy(BOARD)
    for n in b["nodes"]:
        if n["id"] == node_id:
            n["state"], n["detail"] = "warn", detail
            return b
    raise SystemExit("fixture has no node " + node_id)


if case == "ask-ownership-regression":
    # THE DEFECT, REPLAYED (2026-09-11). A node that is still blocking, whose
    # ask stopped matching because the probe started describing the same
    # situation in different words. `prodk8s` did exactly this when
    # `ubu.local` stopped resolving: the ask fell away, the node dropped to the
    # `eng` default, and DevOps' engineering ceiling rose to exactly the 90%
    # landing standard. A number that decides "have we landed" must not move
    # because a hostname stopped resolving.
    a = sr.ASKS[0]
    BOARD = _block_node(a["node"], a["when"])
    if selfcheck_rc() != 0:
        print("PRECONDITION FAILED: a blocking node WITH a matching ask must be clean")
        sys.exit(1)
    sr.ASKS[0] = dict(a, when="這個字串不可能出現在任何 detail 裡")
    sys.exit(selfcheck_rc(expect_fail_substr="仍在擋完成度"))

if case == "ask-regression-needs-no-owner":
    # The inverse control: the SAME broken ask, on a node that is NOT
    # blocking, must stay a NOTE -- otherwise every resolved problem breaks
    # the build.
    sr.ASKS[0] = dict(sr.ASKS[0], when="這個字串不可能出現在任何 detail 裡")
    sys.exit(selfcheck_rc(expect_note_substr="條件已消失"))

if case == "ask-second-ask-covers":
    # A node may carry several asks and only one can match at a time. prodk8s
    # has "reachable but empty" and "not reachable at all". The one that is
    # quiet today is not a regression.
    a = sr.ASKS[0]
    BOARD = _block_node(a["node"], a["when"])
    sr.ASKS.append(dict(a, id=a["id"] + "-alt",
                        when="這個字串不可能出現在任何 detail 裡"))
    sys.exit(selfcheck_rc(expect_note_substr="條件已消失"))

if case == "ask-stale":
    # The condition the ask describes is gone. This is NOT an error -- it is a
    # deletion candidate, and the difference matters: treating it as an error
    # would mean every resolved problem breaks the build.
    sr.ASKS[0] = dict(sr.ASKS[0], when="這個字串不可能出現在任何 detail 裡")
    sys.exit(selfcheck_rc(expect_note_substr="條件已消失"))

# -- renderings ----------------------------------------------------------
if case == "renderings":
    m = sr.stage_model(BOARD)
    md, js, ht = sr.render_markdown(m), sr.render_json(m), sr.render_html(m)
    problems = []

    d = json.loads(js)
    if d["schema"] != sr.SCHEMA:
        problems.append("json schema key is not " + sr.SCHEMA)
    if not d["lines"] or not d["totals"]:
        problems.append("json is missing lines/totals")

    # Every stage must appear in the digest. The digest is the AI's whole view;
    # a stage dropped from it is a stage the AI will report as absent.
    names = [s["name"] for l in m["lines"] for s in l["stages"]]
    for n in names:
        if n not in md:
            problems.append("digest omits stage " + n)

    # The digest exists to fit in a context window. If it stops doing that it
    # has stopped being a digest, and the HTML would do just as well.
    if len(md.encode()) > 8192:
        problems.append("digest is %d bytes, over the 8 KB it exists to stay under"
                        % len(md.encode()))

    if m["headline"] not in ht:
        problems.append("html does not carry the headline sentence")
    if m["generated_at"] not in ht or m["generated_at"] not in md:
        problems.append("a rendering is missing its generated-at stamp")

    # Every actionable stage is in exactly one owner bucket -- no double count,
    # no silently dropped row.
    bucketed = sum(len(v) for v in m["by_owner"].values())
    if bucketed != m["totals"]["attention"]:
        problems.append("owner buckets hold %d of %d attention stages"
                        % (bucketed, m["totals"]["attention"]))

    for p in problems:
        print("PROBLEM:", p)
    if not problems:
        print("json/md/html agree; digest %d bytes" % len(md.encode()))
    sys.exit(1 if problems else 0)

print("unknown case:", case)
sys.exit(2)
PYEOF

export REPO_ROOT

# ---- positive control: the metadata as it actually stands ----------------
run_cmd python3 "$SUITE_DIR/fixture_board.py" "$BOARD_SELFCHECK"
assert_rc 0 "a fixture board for the selfcheck is generated from dag.NODES"
run_cmd python3 "$REPORT" --selfcheck --from-board "$BOARD_SELFCHECK"
assert_rc 0 "selfcheck passes on the real metadata"
assert_output_contains "OK" "selfcheck says OK"

# ---- coverage guard -------------------------------------------------------
run_cmd python3 "$HARNESS" drop-node
assert_rc 0 "a dag node missing from LINES is refused, not silently dropped"

run_cmd python3 "$HARNESS" phantom-node
assert_rc 0 "a LINES entry for a node dag does not produce is refused"

# ---- ask metadata ---------------------------------------------------------
for case in ask-bad-node ask-owner-eng ask-no-options ask-bad-ref ask-duplicate-id; do
  run_cmd python3 "$HARNESS" "$case"
  assert_rc 0 "selfcheck catches: $case"
done

run_cmd python3 "$HARNESS" ask-stale
assert_rc 0 "an ask whose condition is gone is a NOTE, not a build failure"

# ---- ownership cannot be lost quietly -------------------------------------
#
# `pct_ceiling_eng_only` counts every eng-owned blocker as closeable, and a
# node with no matching ask falls back to eng. So an ask that stops matching
# RAISES the ceiling -- the number moves in the flattering direction with
# nothing in the repository changed. It happened on 2026-09-11.
run_cmd python3 "$HARNESS" ask-ownership-regression
assert_rc 0 "a blocking node that lost its only ask is a FAIL, not a note"

run_cmd python3 "$HARNESS" ask-regression-needs-no-owner
assert_rc 0 "the same broken ask on a node that is NOT blocking stays a note"

run_cmd python3 "$HARNESS" ask-second-ask-covers
assert_rc 0 "a node whose OTHER ask still matches is not a regression"

# ---- the three renderings agree ------------------------------------------
run_cmd python3 "$HARNESS" renderings
assert_rc 0 "json / markdown / html render from one model and agree"

# ---- the artifacts are actually produced ---------------------------------
#
# FROM A FIXTURE BOARD, NOT A LIVE PROBE.
#
# This block used to run `stage_report.py --out-dir tmp` with no arguments,
# which calls dag.build() and probes Docker, Postgres, kubectl, Prometheus and
# the scheduler. Measured 2026-09-08: 110 seconds, 22% of the entire test run,
# to prove that three files get written. The rendering does not depend on any
# of that; only on a board.
#
# The fixture is GENERATED from dag.NODES (fixture_board.py), never typed. A
# hand-written node list would drift from dag.py, and then the coverage guard
# this suite exists for would be checking the fixture against itself.
#
# `mktemp -d -t prefix.XXXXXX` is not portable: macOS leaves the literal
# XXXXXX in the name and appends its own suffix, GNU rejects the template
# outright. Plain `mktemp -d` behaves identically on both.
OUT_DIR="$(mktemp -d)"
BOARD_FIXTURE="$(mktemp)"
on_exit "rm -rf '$OUT_DIR' '$BOARD_FIXTURE'"

run_cmd python3 "$SUITE_DIR/fixture_board.py" "$BOARD_FIXTURE"
assert_rc 0 "the fixture board is generated from dag.NODES"

run_cmd python3 "$REPORT" --from-board "$BOARD_FIXTURE" --out-dir "$OUT_DIR"
assert_rc 0 "stage_report.py writes all three formats"
for f in Stage-Report.html Stage-Report.json Stage-Report.md; do
  assert_file_exists "$OUT_DIR/$f" "wrote $f"
done

# --from-board is an optimisation, and an optimisation that can present last
# week as today is not one. Both refusals are asserted, because a renderer
# that reads any JSON on disk is how a stale status page gets published --
# twice already in this repo's history.
run_cmd python3 "$SUITE_DIR/fixture_board.py" "$BOARD_FIXTURE" --stale 7200
assert_rc 0 "a deliberately old board can be generated"
run_cmd python3 "$REPORT" --from-board "$BOARD_FIXTURE" --stdout --format md
assert_rc 1 "a board older than the limit is REFUSED, not rendered"
assert_output_contains "over the" "the refusal states the age and the limit"

python3 - "$BOARD_FIXTURE" <<'STRIP'
import json, sys
b = json.load(open(sys.argv[1]))
b.pop("generated_at", None)
json.dump(b, open(sys.argv[1], "w"))
STRIP
run_cmd python3 "$REPORT" --from-board "$BOARD_FIXTURE" --stdout --format md
assert_rc 1 "a board with no timestamp is REFUSED: undatable reads as fresh"

# And the default path must still be the live one. If --from-board became the
# only way in, the probe would stop being exercised and nothing would say so.
run_cmd grep -n "dag.build() if board is None else board" "$REPORT"
assert_rc 0 "with no --from-board, the report still probes the platform itself"


# ---- the completion figure must state its denominator ----------------------
#
# WHY (2026-09-09). The user set a landing standard of "all three lines at
# 90%". The report already published two numbers that could both be called
# completion -- DevOps read 3/9 by STAGE and 16/24 by NODE, 33% against 67% for
# the same platform -- and neither said which it was. A target measured against
# an unnamed denominator is not a target.
#
# The blocking OWNER matters more than the number and is asserted for the same
# reason: only `eng` is work this repository can close. Driving `external` or
# `research` green means waiting on someone else, or making a node stop
# reporting something true.
# READ THE REPORT THIS SUITE JUST GENERATED, not docs/Stage-Report.json.
#
# Those three files are gitignored build output (a committed status snapshot is
# the stale status page the generator exists to replace), so on a fresh clone
# they do not exist -- and asserting on them made this suite pass here and fail
# in CI. Second time in one day for that exact confusion between "a generated
# path" and "a missing path"; $OUT_DIR is written by the fixture run above and
# is present everywhere.
run_cmd python3 "$SUITE_DIR/assert_completion.py" "$OUT_DIR"
assert_rc 0 "every line publishes a completion figure with its denominator named"
assert_output_contains "denom=nodes" \
  "and the denominator is nodes, so 'three lines at 90 percent' means one thing"

run_cmd cat "$OUT_DIR/Stage-Report.md"
assert_output_contains "分母是節點，不是階段" \
  "the markdown says which denominator it used, next to the number"
assert_output_contains "阻擋者" \
  "and publishes who each blocker belongs to, because only one owner is us"

# ---- ownership belongs to a NODE, never to its neighbours -----------------
#
# The owner column is the honest half of the landing standard: the percentage
# moves when nodes are added, "engineering-owned blockers = 0" does not. So a
# node that inherits a neighbour's owner does not just mis-colour a row -- it
# silently improves the number the standard is measured against.
#
# That happened. `dastcov` was added to the 驗證 stage next to `llmreview`,
# whose ask is owned by `decision`, and dastcov -- engineering's to fix or to
# accept -- was reported to the platform owner as something waiting on them.
# The cause was one line: owners were computed per stage and fanned out to
# every node in it.
run_cmd python3 - <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.getcwd(), "platform", "statusdag"))
import dag, stage_report as sr

# Two blocking nodes in one stage, only one of which has an ask.
board = {"nodes": [], "counts": {}, "verdict": "ok",
         "generated_at": "2026-09-10T00:00:00Z"}
# The ask must be one whose node SHARES A STAGE with dastcov, or this control
# tests nothing: an ask two stages away could never have leaked its owner here.
#
# It is CONSTRUCTED, not picked out of the live ASKS list. The first version
# did `next(a for a in sr.ASKS if ...)` and broke on 2026-09-11 the moment an
# unrelated question was answered and its ask deleted -- the last one that
# happened to share dastcov's stage. A control that stops working because
# someone resolved a different problem is testing the wrong thing, and it
# fails in the direction that looks like a regression in the code under test.
stage_of = {n: st["name"] for _, _, _, sts in sr.LINES for st in sts for n in st["nodes"]}
neighbours = [n for n, st in stage_of.items()
              if st == stage_of["dastcov"] and n != "dastcov"]
if not neighbours:
    raise SystemExit("REFUSING: dastcov has no stage-mate, so per-stage "
                     "leakage could not happen here and this control is empty")
ask = {"id": "synthetic-neighbour", "node": neighbours[0],
       "when": "這個節點正在等某個人", "owner": "decision",
       "ask": "synthetic", "options": ["x"], "ref": "docs/Backlog.md"}
sr.ASKS = list(sr.ASKS) + [ask]
for nid, label, layer, probe in dag.NODES:
    if nid == ask["node"]:
        state, detail = dag.WARN, ask["when"]
    elif nid == "dastcov":
        state, detail = dag.WARN, "掃得到 4/10 條路由（40%）"
    else:
        state, detail = dag.OK, "ok"
    board["nodes"].append({"id": nid, "label": label, "layer": layer,
                           "state": state, "detail": detail, "impacted_by": []})

m = sr.stage_model(board)
owners = {}
for line in m["lines"]:
    for b in line["completion"]["blocking"]:
        owners[b["id"]] = b["owner"]
print("ASKNODE %s=%s" % (ask["node"], owners.get(ask["node"])))
print("NEIGHBOUR dastcov=%s" % owners.get("dastcov"))
PY
assert_rc 0 "the per-node ownership model renders"
assert_output_contains "NEIGHBOUR dastcov=eng" \
  "a blocking node with no ask of its own is engineering's, even when a neighbour in the same stage is waiting on someone else"

suite_summary

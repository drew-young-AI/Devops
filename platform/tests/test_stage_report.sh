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
import importlib.util, io, json, os, sys, contextlib

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

suite_summary

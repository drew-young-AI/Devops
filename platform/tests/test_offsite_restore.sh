#!/usr/bin/env bash
# The off-site restore pipeline: its refusals, its resume, and its reporting.
#
# WHAT THIS SUITE DOES NOT DO. It does not run a full restore. That takes two
# minutes, moves 55 MB across a network and rewrites a production database --
# it is a procedure, run deliberately, and its evidence is
# evidence/dr/offsite_restore_state.json. What a test can hold still is
# everything around it: that it refuses the things it must refuse, resumes
# where it says it resumes, and reports failure to somebody.
#
# WHY THE FAILURE CASES ARE SYNTHETIC. CLAUDE.md §5c: faults are simulated,
# never injected. So the unreachable-host case points the script at a name
# that cannot resolve, rather than taking ubu off the network -- the code path
# is the same one and the host stays up.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="offsite-restore"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

DR="$REPO_ROOT/platform/dr/offsite_restore.sh"

# THE SUITE RUNS THE REAL SCRIPT, SO IT MUST NOT WRITE THE REAL EVIDENCE.
#
# Found in review (2026-09-20): this suite ran the pipeline against an
# unreachable host, which appended a FAILED preflight to the platform's
# disaster-recovery state file and sent a real "[DevOps] 異地還原失敗" message.
# The next real drill would read that state, and the notification channel
# would carry an alarm for a failure that never happened -- a test that lies
# to the operator is worse than no test.
SANDBOX_DR="$(mktemp -d)"
FAKE_NOTIFY="$SANDBOX_DR/emit_event.sh"
cat > "$FAKE_NOTIFY" <<'FAKE'
#!/usr/bin/env bash
# Records the call; sends nothing. The assertions below read this file.
printf '%s\n' "$*" >> "$(dirname "$0")/events.log"
FAKE
chmod +x "$FAKE_NOTIFY"
EVENTS="$SANDBOX_DR/events.log"
: > "$EVENTS"
export DR_STATE_FILE="$SANDBOX_DR/state.json"
export DR_EVIDENCE_DIR="$SANDBOX_DR"
export DR_NOTIFY="$FAKE_NOTIFY"
# on_exit, not a bare trap: lib.sh installs its own EXIT handler (it is what
# cleans the sandbox), and `trap ... EXIT` REPLACES it silently. test_static
# checks for exactly this -- a suite whose cleanup quietly stopped running is
# the 2026-09-04 incident the helper exists for.
on_exit 'rm -rf "$SANDBOX_DR"' 

echo "== 異地還原：它拒絕什麼、從哪裡續跑、失敗時誰會知道 =="

assert_file_exists "$DR" "the pipeline exists"
[ -x "$DR" ] && _pass "and is executable" || _fail "and is executable" "not +x"

# --- 1. every stage has a distinct exit code, and they are written down -----
#
# "restore failed" is the least useful true sentence available: the operator's
# next move is completely different for "the remote would not answer" and "the
# data came back short". The codes are the machine-readable form of that.
# The documentation block wraps onto two lines, so read BOTH. The first
# version grepped one line, reported 14 and 15 missing, and then printed a
# PASS anyway -- a check that fails and passes in the same breath is worse
# than no check.
# EXACTLY the documentation block: the first version used a sed RANGE whose
# end pattern matched nothing until line 320, so it "found" the digits 10-13
# inside unrelated code and only noticed 14 and 15 missing. A guard that reads
# the whole file to check a comment is not checking the comment.
CODES="$(grep -A1 '^# Exit codes:' "$DR" | tr '\n' ' ')"
MISSING_CODES=""
for code in 10 11 12 13 14 15; do
  case "$CODES" in
    *"$code"*) ;;
    *) MISSING_CODES="$MISSING_CODES $code" ;;
  esac
done
if [ -z "$MISSING_CODES" ]; then
  _pass "every stage's exit code is documented (10-15, one per stage)"
else
  _fail "every stage's exit code is documented" "missing:$MISSING_CODES in: $CODES"
fi

STAGES_IN_CODE="$(grep -oE '^STAGES=\(.*\)' "$DR" | sed 's/STAGES=(//; s/)//')"
assert_equals "preflight fetch ship restore confirm verify" "$STAGES_IN_CODE" \
  "the stage list is the one the documentation and the exit codes describe"

# --- 2. an unreachable target fails at preflight, and says so --------------
BEFORE="$(wc -l < "$EVENTS" 2>/dev/null | tr -d ' ')"
run_cmd env DR_TARGET_HOST=nosuchhost.invalid "$DR" --preflight-only
assert_rc 10 "an unreachable target host fails at preflight, with preflight's own code"
assert_output_contains "ssh nosuchhost.invalid" "and names what it could not reach"

AFTER="$(wc -l < "$EVENTS" 2>/dev/null | tr -d ' ')"
if [ "${AFTER:-0}" -gt "${BEFORE:-0}" ]; then
  LAST="$(tail -1 "$EVENTS")"
  case "$LAST" in
    *offsite-restore*failed*preflight*) _pass "the failure emitted one event naming the stage" ;;
    *) _fail "the failure emitted one event naming the stage" "last event: ${LAST:0:120}" ;;
  esac
else
  _fail "the failure emitted an event" "events.jsonl did not grow"
fi

# The control for the control: an event only counts if a human could act on
# it, and "try again from here" is the action. Guarded on the event having
# actually been emitted -- reading the last line unconditionally would pass
# off a PREVIOUS run's event as this one's.
if [ "${AFTER:-0}" -gt "${BEFORE:-0}" ]; then
  case "$(tail -1 "$EVENTS")" in
    *--from\ preflight*) _pass "and tells the reader how to resume" ;;
    *) _fail "and tells the reader how to resume" "no --from hint in the event detail" ;;
  esac
else
  _fail "and tells the reader how to resume" "no event was emitted to inspect"
fi

# --- 3. it will not overwrite a populated production database --------------
#
# A recovery tool whose failure mode is destroying what you were recovering
# TO is not a recovery tool. This is the assertion that keeps --force meaning
# something.
if kubectl --context ubu get nodes >/dev/null 2>&1; then
  ROWS="$(kubectl --context ubu -n station2 exec prod-db-0 -- \
    psql -U twin -d twin -qtAX -c 'select count(*) from surveillance_fact' 2>/dev/null | tr -d ' \r')"
  QRC=$?
  # THREE OUTCOMES, AND THE THIRD IS NOT A SKIP.
  #
  # The first version read an empty answer as "prod-db holds no data" and
  # skipped -- stating a cause it had not established. A pod mid-rollout, a
  # blocked exec or a renamed table all produce the same empty string, and in
  # every one of those the suite would quietly stop checking the assertion
  # that protects a production database.
  if [ "$QRC" -ne 0 ] || [ -z "$ROWS" ]; then
    _fail "the refusal path is checkable" \
          "could not read prod-db's row count (rc=$QRC) -- that is not 'the database is empty'"
  elif [ "$ROWS" != "0" ]; then
    run_cmd "$DR" --preflight-only
    assert_rc 10 "a populated prod-db is refused without --force"
    assert_output_contains "--force" "and says which flag would allow it"
  else
    echo "  SKIP  prod-db really is empty (0 rows) -- nothing to refuse, so this path is UNVERIFIED"
  fi
else
  echo "  SKIP  ubu unreachable -- the refusal path is UNVERIFIED"
fi

# --- 4. the manifest must carry what the restore will check against --------
#
# `confirm` compares the restored database against the manifest, not against
# the source machine -- the premise of a disaster drill is that the source is
# gone. That only works if backup.sh recorded the contents.
LATEST="$(ls -t "$REPO_ROOT"/platform/backup/archives/*/manifest.json 2>/dev/null | head -1)"
if [ -z "$LATEST" ]; then
  echo "  SKIP  no local archive -- the manifest contract is UNVERIFIED"
else
  run_cmd python3 - "$LATEST" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
db = next((v for v in m.get("volumes", []) if v.get("volume", "").endswith("twin-db")), None)
if not db:
    print("NO_DB_ENTRY"); raise SystemExit(1)
c = db.get("contents") or {}
need = ("schema_version", "surveillance_fact", "demographic_fact")
missing = [k for k in need if c.get(k) is None]
print("MISSING", missing) if missing else print("CONTENTS_OK", c)
raise SystemExit(1 if missing else 0)
PY
  assert_rc 0 "the newest manifest records what is inside the dump"
  assert_output_contains "CONTENTS_OK" "with schema version and both fact counts"
fi

# --- 4b. a null count must read as UNVERIFIED, not as a mismatch -----------
#
# backup.sh writes JSON null for any count whose psql probe failed. The
# extractor used `c.get(key, "")`, which returns None for a present-but-null
# key, and `%s` renders that as the four characters "None" -- so the shell saw
# a non-empty expectation, skipped the UNVERIFIED branch, and compared a real
# row count against the string "None". A byte-perfect restore would be
# reported as "schema 版本不符", on every retry, forever.
#
# This exercises the extractor itself: no cluster, no restore, deterministic.
run_cmd python3 - "$DR" <<'PYNULL'
import io, json, os, subprocess, sys, tempfile
src = io.open(sys.argv[1], encoding="utf-8").read()
i = src.index("expect_schema expect_sf expect_df")
start = src.index("<<'PY'", i) + len("<<'PY'")
body = src[start:src.index("\nPY\n", start)]

mf = tempfile.mktemp(suffix=".json")
try:
    cases = {
        "null":   {"schema_version": None, "surveillance_fact": 10, "demographic_fact": 20},
        "normal": {"schema_version": 20, "surveillance_fact": 10, "demographic_fact": 20},
    }
    out = {}
    for name, contents in cases.items():
        json.dump({"volumes": [{"volume": "station2-twin-db", "contents": contents}]},
                  open(mf, "w"))
        r = subprocess.run([sys.executable, "-c", body, mf], capture_output=True, text=True)
        out[name] = dict(line.split("=", 1) for line in r.stdout.strip().splitlines())
finally:
    os.path.exists(mf) and os.unlink(mf)

print("NULL_RENDERS", repr(out["null"]["expect_schema"]))
print("NORMAL_RENDERS", repr(out["normal"]["expect_schema"]))
ok = out["null"]["expect_schema"] == "" and out["normal"]["expect_schema"] == "20"
print("NULL_IS_EMPTY" if ok else "NULL_LEAKED")
raise SystemExit(0 if ok else 1)
PYNULL
assert_rc 0 "a null count in the manifest is extracted as empty, not as the string None"
assert_output_contains "NULL_IS_EMPTY" \
  "so confirm reports UNVERIFIED instead of a mismatch that cannot be fixed by retrying"

# --- 5. the resume path skips what it says it skips ------------------------
#
# The control: `--from confirm` must not go back to the remote. A resume that
# quietly re-downloads is not a resume, and on a bad link it is the difference
# between finishing and not.
if kubectl --context ubu get nodes >/dev/null 2>&1; then
  run_cmd "$DR" --from confirm
  assert_rc 0 "resuming from confirm completes"
  assert_output_not_contains "2/6 fetch" "and does not go back to the off-site remote"
  assert_output_contains "5/6 confirm" "but does run the stage it was asked for"
else
  echo "  SKIP  ubu unreachable -- the resume path is UNVERIFIED"
fi

suite_summary

#!/usr/bin/env bash
# The check that makes the OTHER checks stop being a list of past failures.
#
# THE PROBLEM THIS ANSWERS.
#
# Every guard in this repository was written after a specific failure, so the
# guard set is a list of things that have already gone wrong. That is why each
# review round finds new gaps: finding them depends on somebody happening to
# look. On 2026-09-10 six surfaces were found that way in one session --
# certificate expiry, host disk, rotation coverage, IaC, source freshness,
# prod node health -- every one of them with a working script and no board
# node. Writing a seventh test would have added one more past failure to the
# list and changed nothing about the seventh gap.
#
# So this suite does not test a behaviour. It enumerates a POPULATION -- every
# service any compose file declares, every job the scheduler runs -- and
# refuses unless each member is either mapped to a node in dag.COVERAGE or
# written down in dag.UNMEASURED with a reason.
#
# The consequence is the point: adding a service or a job now FAILS THIS SUITE
# until somebody says where it is measured. Discovery stops being luck.
#
# WHAT IT DELIBERATELY DOES NOT DO. It does not require everything to be
# measured. Nine surfaces are unmeasured today and each carries a sentence
# saying why. An unmeasured thing somebody wrote a sentence about is a
# decision; one that is merely absent is what this exists to stop.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="coverage-closure"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== 每一個表面都有人在問它問題，或有人寫下為什麼沒有 =="

run_cmd python3 - "$REPO_ROOT" <<'PY'
import os, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root / "platform" / "statusdag"))
import dag

# ---- enumerate the population -------------------------------------------
found = set()
compose = sorted(p for p in root.rglob("compose*.y*ml")
                 if "venv" not in str(p) and ".git" not in str(p))
for f in compose:
    text = f.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"^services:\s*$(.*?)(?=^\S|\Z)", text, re.M | re.S)
    if not m:
        continue
    for svc in re.findall(r"^  ([a-z0-9][a-z0-9_-]*):", m.group(1), re.M):
        found.add("service:" + svc)

jobs_conf = root / "platform" / "scheduler" / "jobs.conf"
for line in jobs_conf.read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    found.add("job:" + line.split("|", 1)[0])

# An enumeration that found nothing is not a pass. Every empty-scan bug this
# platform has had looked exactly like a clean run.
if len(found) < 10:
    sys.exit("REFUSING: only %d surfaces enumerated from %d compose file(s) and "
             "jobs.conf -- the enumeration is broken, not the platform"
             % (len(found), len(compose)))

declared = set(dag.COVERAGE)
node_ids = {n[0] for n in dag.NODES}

undeclared = sorted(found - declared)
phantom = sorted(declared - found)
bad_node = sorted(k for k, v in dag.COVERAGE.items() if v is not None and v not in node_ids)
missing_reason = sorted(k for k, v in dag.COVERAGE.items()
                        if v is None and not (dag.UNMEASURED.get(k) or "").strip())
stray_reason = sorted(set(dag.UNMEASURED) - {k for k, v in dag.COVERAGE.items() if v is None})

print("SURFACES %d" % len(found))
print("UNMEASURED %d" % sum(1 for v in dag.COVERAGE.values() if v is None))
print("UNDECLARED %s" % (", ".join(undeclared) or "none"))
print("PHANTOM %s" % (", ".join(phantom) or "none"))
print("BADNODE %s" % (", ".join(bad_node) or "none"))
print("NOREASON %s" % (", ".join(missing_reason) or "none"))
print("STRAYREASON %s" % (", ".join(stray_reason) or "none"))
PY
assert_rc 0 "the population can be enumerated at all"
assert_output_contains "UNDECLARED none" \
  "every service and job that exists is declared in the coverage ledger"
assert_output_contains "PHANTOM none" \
  "and every ledger entry still exists -- a mapping to a deleted job hides that the ledger is stale"
assert_output_contains "BADNODE none" \
  "every node a surface is mapped to is a real node id, not a name that was renamed away"
assert_output_contains "NOREASON none" \
  "an unmeasured surface must carry a reason: absent and decided must not look the same"
assert_output_contains "STRAYREASON none" \
  "and a reason without an unmeasured surface means something got measured and nobody removed the excuse"

# ---- the control: the ledger must actually be able to fail -----------------
#
# Without this, "UNDECLARED none" is satisfied by an enumeration that finds
# nothing and a ledger that declares nothing -- the vacuous pass this platform
# has been caught by five times.
run_cmd python3 - "$REPO_ROOT" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root / "platform" / "statusdag"))
import dag
before = dict(dag.COVERAGE)
try:
    del dag.COVERAGE["job:backup"]          # simulate a job nobody declared
    missing = "job:backup" not in dag.COVERAGE
    dag.COVERAGE["job:nonexistent"] = "backup"
    dag.COVERAGE["job:disk"] = "no_such_node"
    node_ids = {n[0] for n in dag.NODES}
    print("CONTROL_UNDECLARED %s" % missing)
    print("CONTROL_PHANTOM %s" % ("job:nonexistent" in dag.COVERAGE))
    print("CONTROL_BADNODE %s" % (dag.COVERAGE["job:disk"] not in node_ids))
finally:
    dag.COVERAGE.clear()
    dag.COVERAGE.update(before)
    print("RESTORED %s" % (dag.COVERAGE == before))
PY
assert_rc 0 "the mutation control runs"
assert_output_contains "CONTROL_UNDECLARED True" "removing a declaration is detectable"
assert_output_contains "CONTROL_PHANTOM True" "so is declaring something that does not exist"
assert_output_contains "CONTROL_BADNODE True" "so is pointing a surface at a node id that is not real"
assert_output_contains "RESTORED True" "and the ledger is restored -- an in-place mutation that leaks is a broken suite"

suite_summary

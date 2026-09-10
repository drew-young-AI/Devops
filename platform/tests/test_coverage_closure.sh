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

# ---- retiring a node must retire its probe too ----------------------------
#
# When ci / trivy / registry / prodlike were removed from NODES on 2026-09-10,
# their rows went and `probe_ci` and `probe_registry` stayed -- forty lines
# each, referenced by nothing, still reading evidence/_retired/ and still
# returning a SUPERSEDED sentence nobody would ever see. Exactly the orphan
# shape the removal was meant to end, one layer down: the DOCUMENT said the
# work had moved, and the CODE still described the old path.
#
# Scoped to statusdag deliberately. Elsewhere in this repo a function can be
# reached by CLI dispatch or by a sibling module, so "unreferenced in its own
# file" would be a false positive generator. Here every function is either a
# probe named in NODES, a helper called by one, or dead.
run_cmd python3 - "$REPO_ROOT" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
files = sorted((root / "platform" / "statusdag").glob("*.py"))
if not files:
    sys.exit("REFUSING: no statusdag modules found -- the scan is broken")
corpus = {f: f.read_text(encoding="utf-8") for f in files}
whole = "\n".join(corpus.values())
dead = []
for f, text in corpus.items():
    for name in re.findall(r"^def (\w+)\(", text, re.M):
        if name.startswith("__") or name == "main":
            continue
        if len(re.findall(r"\b%s\b" % re.escape(name), whole)) <= 1:
            dead.append("%s:%s" % (f.name, name))
print("SCANNED %d module(s)" % len(files))
print("DEAD %s" % (", ".join(sorted(dead)) or "none"))
PY
assert_rc 0 "the statusdag modules can be scanned"
assert_output_contains "DEAD none" \
  "no probe outlives the node it served -- a retired node must take its code with it"

# ---- a name that does not exist is not a runtime surprise -----------------
#
# On 2026-09-10 a text-offset deletion of two retired probes also took the
# module constant defined immediately after them. The board did not crash --
# build() catches, so probe_alertmanager rendered as UNKNOWN with "probe
# error: name 'ALERT_CHANNEL_RE' is not defined". Visible, and shaped exactly
# like "the service is unreachable". A whole class of edit produces that: the
# code compiles, imports, and is wrong only on the path nobody ran.
#
# ruff answers it statically in under a second. F821 is the undefined name,
# F811 a redefinition that silently shadows, F401 an import that outlived the
# code using it -- the same orphan family as a probe that outlived its node.
#
# SKIP when ruff is absent rather than passing: this runner then says nothing
# about the class, which is the repository's convention for an unrun check.
if command -v ruff >/dev/null 2>&1; then
  RUFF=ruff
elif [ -x "$HOME/ENV/dev/bin/ruff" ]; then
  RUFF="$HOME/ENV/dev/bin/ruff"
else
  RUFF=""
fi
if [ -z "$RUFF" ]; then
  echo "  SKIP  no ruff on this runner -- undefined names are UNVERIFIED here."
else
  run_cmd "$RUFF" check --select F821,F811,F401 --output-format concise \
    --exclude '*/venv/*' "$REPO_ROOT/platform" "$REPO_ROOT/pilots"
  assert_rc 0 "no undefined name, shadowed definition, or orphaned import"
fi

# ---- the reader must agree with the writer about the shape ----------------
#
# The third dimension, after "does it work" and "is anything unwatched": does
# the probe's belief about an artifact match the artifact. A missing field is
# falsy, and falsy is a verdict -- `probe_capability_catalog` guessed four key
# names, missed all four, and reported 94 orphans while the generator said 0.
# That failure is indistinguishable from a finding unless something checks the
# shape, and nothing did.
run_cmd python3 - "$REPO_ROOT" <<'PY'
import glob, json, os, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root / "platform" / "statusdag"))
import dag

def resolve(doc, path):
    """True if `path` is satisfied by `doc`. See dag.EVIDENCE_READS for grammar."""
    node = doc
    for i, part in enumerate(path.split(".")):
        listy = part.endswith("[]")
        key = part[:-2] if listy else part
        alts = key.split("|")
        if isinstance(node, dict):
            hit = next((a for a in alts if a in node), None)
            if hit is None:
                return False
            node = node[hit]
        elif isinstance(node, list):
            rest = ".".join(path.split(".")[i:])
            # every element must satisfy the remainder
            return bool(node) and all(resolve(el, rest) for el in node)
        else:
            return False
        if listy:
            if not isinstance(node, list):
                return False
            rest = ".".join(path.split(".")[i + 1:])
            if not rest:
                return True
            return bool(node) and all(resolve(el, rest) for el in node)
    return True

def newest(pattern):
    hits = sorted(glob.glob(os.path.join(str(root / "evidence"), pattern)))
    return hits[-1] if hits else None

# 1. CLOSURE: every probe that reads evidence must be declared.
src = (root / "platform" / "statusdag" / "dag.py").read_text(encoding="utf-8")
reading = set()
for chunk in re.split(r"\ndef ", src)[1:]:
    name = chunk.split("(", 1)[0]
    if not name.startswith("probe_"):
        continue
    body = chunk.split("\n\n\n", 1)[0]
    if "EVIDENCE" in body or "newest(" in body:
        reading.add(name)
undeclared = sorted(reading - set(dag.EVIDENCE_READS))
phantom = sorted(set(dag.EVIDENCE_READS) - reading)
print("READERS %d" % len(reading))
print("UNDECLARED_READER %s" % (", ".join(undeclared) or "none"))
print("PHANTOM_READER %s" % (", ".join(phantom) or "none"))

# 2. CONFORMANCE: each declared field must resolve in the real artifact.
misses, absent = [], []

def check(probe, path, fields, misses):
    if path.endswith(".prom"):
        body = open(path, encoding="utf-8", errors="replace").read()
        for f in fields:
            name = f.split("metric:", 1)[1]
            if not re.search(r"^%s[{ ]" % re.escape(name), body, re.M):
                misses.append("%s: %s has no %s" % (probe, os.path.basename(path), f))
        return
    try:
        doc = json.load(open(path, encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        misses.append("%s: %s unreadable (%s)" % (probe, os.path.basename(path), e))
        return
    for f in fields:
        if not resolve(doc, f):
            misses.append("%s: %s has no %s" % (probe, os.path.basename(path), f))

for probe, (patterns, fields) in sorted(dag.EVIDENCE_READS.items()):
    for pattern in ([patterns] if isinstance(patterns, str) else patterns):
        path = newest(pattern)
        if not path:
            absent.append("%s(%s)" % (probe, pattern))
            continue
        check(probe, path, fields, misses)
print("NO_ARTIFACT %s" % (", ".join(absent) or "none"))
print("SCHEMA_MISS %s" % ("; ".join(misses) or "none"))
PY
assert_rc 0 "the schema contract can be evaluated"
assert_output_contains "UNDECLARED_READER none" \
  "every probe that reads an artifact declares which fields it depends on"
assert_output_contains "PHANTOM_READER none" \
  "and every declaration belongs to a probe that still reads something"
assert_output_contains "SCHEMA_MISS none" \
  "every declared field resolves in the artifact its producer actually writes"

# The control. Without it, "SCHEMA_MISS none" is satisfied by a resolver that
# says yes to everything -- which is precisely the bug being guarded against,
# wearing the guard's clothes.
run_cmd python3 - "$REPO_ROOT" <<'PY'
import json, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
doc = json.load(open(root / "evidence" / "capabilities.json", encoding="utf-8"))
sys.path.insert(0, str(root / "platform" / "statusdag"))
def resolve(doc, path):
    node = doc
    for i, part in enumerate(path.split(".")):
        listy = part.endswith("[]")
        key = part[:-2] if listy else part
        alts = key.split("|")
        if isinstance(node, dict):
            hit = next((a for a in alts if a in node), None)
            if hit is None:
                return False
            node = node[hit]
        else:
            return False
        if listy:
            if not isinstance(node, list):
                return False
            rest = ".".join(path.split(".")[i + 1:])
            if not rest:
                return True
            return bool(node) and all(resolve(el, rest) for el in node)
    return True
# the real field, and the four that were guessed on 2026-09-10
print("REAL %s" % resolve(doc, "capabilities[].described|internal_to"))
print("GUESSED %s" % resolve(doc, "capabilities[].described_by|reachable_from"))
print("MISSPELT %s" % resolve(doc, "capabilitys[].described"))
PY
assert_rc 0 "the resolver control runs"
assert_output_contains "REAL True" "the field the generator actually writes resolves"
assert_output_contains "GUESSED False" \
  "and the four names guessed on 2026-09-10 do NOT -- this is the check that would have caught it"
assert_output_contains "MISSPELT False" "a mistyped container name is a miss, not a pass"

suite_summary

#!/usr/bin/env bash
# Three nodes added 2026-09-10, and the case each one exists to catch.
#
# WHY THESE THREE TOGETHER.
#
# Each covers a surface that had a working script and no board node, and each
# fails in the same shape: it is fine, it is fine, it is fine, and then it is
# not, with no slope in between and nothing watching.
#
#   certs      a certificate does not degrade. It works perfectly until a
#              timestamp somebody else chose months ago, then everything that
#              uses it stops at once. The pinned TWCA intermediate is the
#              clearest case: when it lapses every public-health feed fails
#              verification together, and the error names neither the file nor
#              the date.
#   hostdisk   the number that stopped this whole platform once, and was the
#              last one nobody measured.
#   rotation   the sweep prints PASS whether it checked three secrets or none.
#              It already learned that once (all three exempt, "every
#              non-exempt secret is within its interval" true over the empty
#              set) -- the node has to carry the denominator or it re-learns it.
#
# EVERY ASSERTION BELOW HAS A NEGATIVE CONTROL. A node added the day it is
# green proves nothing on its own: green is also what a probe returns when it
# is looking at the wrong thing. These fixtures make each one go red on demand.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="foundation-nodes"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== 三個會安靜過期的東西 =="

FIX="$(mktemp -d)"
cleanup() { rm -rf "$FIX"; }
on_exit cleanup

# ---------------------------------------------------------------- certificates
# openssl generates the fixtures: a self-signed certificate with a chosen
# lifetime is the real object, so the probe is parsing what it parses in
# production rather than a string we shaped to match it.
mkcert_days() {  # <dir> <name> <days-from-now, positive only>
  mkdir -p "$1/platform/fixtures"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null \
    -out "$1/platform/fixtures/$2.crt" -subj "/CN=$2" -days "$3" 2>/dev/null
}

# The EXPIRED certificate is a committed fixture, not generated here.
# macOS ships LibreSSL 3.3, which has no -not_before/-not_after and silently
# ignores `-days 0` (it produced a 30-day certificate), so there is no way to
# mint a past-dated one on this machine. It was generated once inside
# alpine/openssl (OpenSSL 3.5) and checked in. It expired 2026-09-05 and can
# never become valid again, which is the property a fixture wants.
EXPIRED_FIXTURE="$SUITE_DIR/fixtures/expired-selfsigned.crt"

certs_probe() {  # <root>
  python3 - "$1" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.getcwd(), "platform", "statusdag"))
import dag
dag.CERT_ROOT = sys.argv[1]
dag.CERT_GLOBS = ("platform/**/*.crt", "platform/**/*.pem")
dag.CERT_PROBE_UBU = False          # LAN handshake is not part of this claim
print("%s|%s" % dag.probe_certificates())
PY
}

HEALTHY="$FIX/healthy"; mkcert_days "$HEALTHY" long 400
run_cmd certs_probe "$HEALTHY"
assert_output_contains "ok|" "a certificate with 400 days left is green"

SOON="$FIX/soon"; mkcert_days "$SOON" long 400; mkcert_days "$SOON" soon 10
run_cmd certs_probe "$SOON"
assert_output_contains "warn|" "10 days left is WARN -- 30 is the threshold, and it is early on purpose"
assert_output_contains "soon" "and the certificate is NAMED: 'something expires soon' sends nobody anywhere"

assert_file_exists "$EXPIRED_FIXTURE" "the expired-certificate fixture is present"
run_cmd sh -c "openssl x509 -in '$EXPIRED_FIXTURE' -noout -checkend 0 >/dev/null 2>&1; echo rc=\$?"
assert_output_contains "rc=1" "and it is STILL expired -- a fixture that quietly became valid would make the control vacuous"

GONE="$FIX/gone"; mkcert_days "$GONE" long 400
cp "$EXPIRED_FIXTURE" "$GONE/platform/fixtures/dead.crt"
run_cmd certs_probe "$GONE"
assert_output_contains "fail|" "an already-expired certificate is FAIL, not WARN"
assert_output_contains "dead" "and it is the EXPIRED one that gets named, not the healthiest"

# The empty-scan refusal. This platform has been caught by a vacuous pass five
# times; a certificate scan that reads nothing must not render as 'nothing is
# expiring'.
EMPTY="$FIX/empty"; mkdir -p "$EMPTY/platform"
run_cmd certs_probe "$EMPTY"
assert_output_contains "unknown|" "a scan that found no certificate is UNKNOWN, never OK"

# A key is not a certificate. Counting it as healthy would inflate the count
# and, worse, let a directory of keys read as a directory of valid certs.
KEYS="$FIX/keys"; mkdir -p "$KEYS/platform/fixtures"
openssl genrsa -out "$KEYS/platform/fixtures/private.pem" 2048 2>/dev/null
run_cmd certs_probe "$KEYS"
assert_output_contains "unknown|" "a directory holding only a private key is UNKNOWN, not OK"

# ------------------------------------------------------------------ host disk
disk_probe() {  # <avail-bytes> <size-bytes> <age-seconds>
  python3 - "$FIX" "$1" "$2" "$3" <<'PY'
import os, sys, time
root, avail, size, age = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
d = os.path.join(root, "ev", "statusdag"); os.makedirs(d, exist_ok=True)
open(os.path.join(d, "host_disk.prom"), "w").write(
    "host_filesystem_size_bytes{mountpoint=\"/\"} %s\n"
    "host_filesystem_avail_bytes{mountpoint=\"/\"} %s\n"
    "host_disk_metrics_generated_seconds %d\n" % (size, avail, time.time() - age))
sys.path.insert(0, os.path.join(os.getcwd(), "platform", "statusdag"))
import dag
dag.EVIDENCE = os.path.join(root, "ev")
print("%s|%s" % dag.probe_host_disk())
PY
}

run_cmd disk_probe 500000000000 1000000000000 60
assert_output_contains "ok|" "half the disk free is green"
run_cmd disk_probe 100000000000 1000000000000 60
assert_output_contains "warn|" "10% free is WARN -- the point is to be told before it is urgent"
run_cmd disk_probe 20000000000 1000000000000 60
assert_output_contains "fail|" "2% free is FAIL: below this the platform stops"

# Freshness is part of the verdict. A two-hour-old reading of a healthy disk
# is not a claim about the disk now, and the disk job runs every 300s.
run_cmd disk_probe 500000000000 1000000000000 7200
assert_output_contains "warn|" "a stale reading is WARN even when the numbers in it are healthy"
assert_output_contains "分鐘" "and it says how stale, so the reader can tell which problem they have"

# ------------------------------------------------------------------- rotation
rot_probe() {  # <json>
  python3 - "$FIX" "$1" <<'PY'
import datetime, json, os, sys
root, doc = sys.argv[1], json.loads(sys.argv[2])
d = os.path.join(root, "ev2", "vault"); os.makedirs(d, exist_ok=True)
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
json.dump(doc, open(os.path.join(d, "rotation_summary_%s.json" % stamp), "w"))
sys.path.insert(0, os.path.join(os.getcwd(), "platform", "statusdag"))
import dag
dag.EVIDENCE = os.path.join(root, "ev2")
print("%s|%s" % dag.probe_secret_rotation())
PY
}

run_cmd rot_probe '{"gate_result":"PASS","total_secrets":3,"checked_secrets":3,"exempt":0,"due":0,"without_record":0}'
assert_output_contains "ok|" "every secret checked and within interval is green"

# THE ASSERTION THIS NODE EXISTS FOR. The sweep prints PASS either way; only
# the denominator separates a rotation policy that is met from one that has
# verified nothing.
run_cmd rot_probe '{"gate_result":"PASS","total_secrets":3,"checked_secrets":0,"exempt":3,"due":0,"without_record":0}'
assert_output_contains "warn|" "a PASS that checked nothing is not OK, whatever the sweep printed"
run_cmd rot_probe '{"gate_result":"PASS","total_secrets":3,"checked_secrets":1,"exempt":2,"due":0,"without_record":0}'
assert_output_contains "1/3" "and a partial sweep states its denominator on the board"

run_cmd rot_probe '{"gate_result":"FAIL","total_secrets":3,"checked_secrets":3,"exempt":0,"due":2,"without_record":1}'
assert_output_contains "fail|" "an overdue secret is FAIL"
assert_output_contains "2 筆逾期" "and the count is carried, not just the word"

# ------------------------------------------------------------------------ iac
# The board carried "No `iac` node" as known gap #1 for months, next to the
# consequence: it is part of why platform/iac went unverified. These fixtures
# are whole tofu directories, so the probe runs the real binary against real
# HCL -- a stubbed validate would assert only that the branch exists.
iac_probe() {  # <dir>
  python3 - "$1" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.getcwd(), "platform", "statusdag"))
import dag
dag.IAC_DIR = sys.argv[1]
print("%s|%s" % dag.probe_iac())
PY
}

if ! command -v tofu >/dev/null 2>&1 && ! command -v terraform >/dev/null 2>&1; then
  echo "  SKIP  no tofu/terraform here -- the iac node is UNVERIFIED on this runner."
else
  # NOT INITIALISED. The single most important control here: `validate` in an
  # uninitialised directory fails for a reason that has nothing to do with the
  # configuration, and calling that OK is the vacuous green this platform keeps
  # meeting.
  NOINIT="$FIX/iac-noinit"; mkdir -p "$NOINIT"
  printf 'resource "null_resource" "a" {}\n' > "$NOINIT/main.tf"
  run_cmd iac_probe "$NOINIT"
  assert_output_contains "unknown|" "an uninitialised IaC directory is UNKNOWN, never OK"
  assert_output_contains "init" "and the detail names the command that fixes it"

  # BROKEN HCL. Copy the real .terraform so providers resolve, then break the
  # configuration: this proves the node reports the CONFIGURATION's state and
  # not merely that the tool ran.
  if [ -d "$REPO_ROOT/platform/iac/.terraform" ]; then
    BAD="$FIX/iac-bad"; mkdir -p "$BAD"
    cp -R "$REPO_ROOT/platform/iac/.terraform" "$BAD/.terraform"
    cp "$REPO_ROOT/platform/iac/.terraform.lock.hcl" "$BAD/" 2>/dev/null || true
    printf 'resource "null_resource" "a" {\n  no_such_argument = 1\n}\n' > "$BAD/main.tf"
    run_cmd iac_probe "$BAD"
    assert_output_contains "fail|" "a configuration that does not validate is FAIL"

    # FORMAT DRIFT is WARN, not FAIL: it parses and would apply, so calling it
    # broken would train people to ignore the colour.
    UGLY="$FIX/iac-ugly"; mkdir -p "$UGLY"
    cp -R "$REPO_ROOT/platform/iac/.terraform" "$UGLY/.terraform"
    cp "$REPO_ROOT/platform/iac/.terraform.lock.hcl" "$UGLY/" 2>/dev/null || true
    # Valid HCL, wrong indentation. `x = 1` was the first attempt and it made
    # this control vacuous: null_resource has no such argument, so validate
    # failed and the assertion was measuring the FAIL branch it already had.
    printf 'resource "null_resource" "a" {\n     triggers = { a = "b" }\n}\n' > "$UGLY/main.tf"
    run_cmd iac_probe "$UGLY"
    assert_output_contains "warn|" "valid HCL with unapplied formatting is WARN, not FAIL"

    # The positive control, so the three above cannot be satisfied by a probe
    # that always reports a problem.
    GOOD="$FIX/iac-good"; mkdir -p "$GOOD"
    cp -R "$REPO_ROOT/platform/iac/.terraform" "$GOOD/.terraform"
    cp "$REPO_ROOT/platform/iac/.terraform.lock.hcl" "$GOOD/" 2>/dev/null || true
    printf 'resource "null_resource" "a" {\n}\n' > "$GOOD/main.tf"
    run_cmd iac_probe "$GOOD"
    assert_output_contains "ok|" "a valid, formatted configuration is green"
  else
    echo "  SKIP  platform/iac not initialised -- the configuration controls are UNVERIFIED here."
  fi
fi

# ------------------------------------------------------- prod node health
# `prodk8s` asks whether the API server answers and whether anything runs.
# Both stay true on a machine that is out of disk or that kubelet has started
# evicting from. Separate question, separate node -- and the fake kubectl below
# is what makes the FAIL branches reachable without breaking a real machine
# (CLAUDE.md section 5c: simulate the fault, do not create it).
prodnode_probe() {  # <node-json> <stats-json>
  python3 - "$FIX" "$1" "$2" <<'PY'
import json, os, sys
root, node_json, stats_json = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, os.path.join(os.getcwd(), "platform", "statusdag"))
import dag

def fake_run(cmd, timeout=25):
    return 0, "ubu\nk3d-devops-lab\n"

def fake_diag(cmd, timeout=25):
    joined = " ".join(cmd)
    if "stats/summary" in joined:
        return (1, "", "no stats") if stats_json == "-" else (0, stats_json, "")
    if "get" in cmd and "node" in cmd:
        return 0, node_json, ""
    return 1, "", "unexpected: " + joined

dag.run, dag.run_diag = fake_run, fake_diag
print("%s|%s" % dag.probe_prod_node())
PY
}

node_doc() {  # <ready> <diskpressure>
  cat <<JSON
{"items":[{"metadata":{"name":"ubu"},"status":{"conditions":[
 {"type":"Ready","status":"$1","reason":"KubeletReady"},
 {"type":"DiskPressure","status":"$2","reason":"KubeletHasNoDiskPressure"},
 {"type":"MemoryPressure","status":"False"},{"type":"PIDPressure","status":"False"}]}}]}
JSON
}
stats_doc() {  # <avail-bytes> <capacity-bytes>
  printf '{"node":{"fs":{"availableBytes":%s,"capacityBytes":%s}}}' "$1" "$2"
}

run_cmd prodnode_probe "$(node_doc True False)" "$(stats_doc 88000000000 105000000000)"
assert_output_contains "ok|" "a Ready node with 84% free is green"

run_cmd prodnode_probe "$(node_doc True True)" "$(stats_doc 88000000000 105000000000)"
assert_output_contains "fail|" "DiskPressure is FAIL even while the free-space number still looks fine"
assert_output_contains "DiskPressure" "and the condition is named"

run_cmd prodnode_probe "$(node_doc False False)" "$(stats_doc 88000000000 105000000000)"
assert_output_contains "fail|" "a NotReady node is FAIL"

# The earlier signal. DiskPressure only flips at kubelet's eviction threshold,
# by which time pods are already being killed; 10% free must already be amber.
run_cmd prodnode_probe "$(node_doc True False)" "$(stats_doc 10000000000 105000000000)"
assert_output_contains "warn|" "10% free is WARN before kubelet reports any pressure at all"
run_cmd prodnode_probe "$(node_doc True False)" "$(stats_doc 2000000000 105000000000)"
assert_output_contains "fail|" "2% free is FAIL"

# A cluster that answers with no nodes is an answer about nothing.
run_cmd prodnode_probe '{"items":[]}' "$(stats_doc 88000000000 105000000000)"
assert_output_contains "unknown|" "a cluster reporting zero nodes is UNKNOWN, never OK"

# Conditions fine, usage unreadable: not measured is not the same as not a
# problem, and this is the half a conditions-only probe would call green.
run_cmd prodnode_probe "$(node_doc True False)" "-"
assert_output_contains "warn|" "healthy conditions with unreadable disk usage is WARN, not OK"

# ------------------------------------------------ coverage-of-the-coverage
# Three nodes whose whole job is to carry a DENOMINATOR next to a verdict.
# "DAST PASS" over 4 of 10 routes prints the same word as PASS over 10 of 10;
# a health rollup that saw four fifths of its windows makes a weaker claim
# about every one of them; a capability catalogue is only evidence if it
# enumerated something.
json_probe() {  # <subdir> <filename> <json> <probe-fn>
  python3 - "$FIX" "$1" "$2" "$3" "$4" <<'PY'
import json, os, sys, tempfile
root, sub, name, doc, fn = sys.argv[1:6]
d = tempfile.mkdtemp(dir=root)
target = os.path.join(d, sub) if sub != "." else d
os.makedirs(target, exist_ok=True)
open(os.path.join(target, name), "w").write(doc)
sys.path.insert(0, os.path.join(os.getcwd(), "platform", "statusdag"))
import dag
dag.EVIDENCE = d
print("%s|%s" % getattr(dag, fn)())
PY
}
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# -- rollup ----------------------------------------------------------------
run_cmd json_probe observability health_rollup.json   "{\"generated_at\":\"$NOW\",\"snapshots\":1000,\"coverage_ratio\":0.97,\"verdicts\":{\"HEALTHY\":900,\"DEGRADED\":100}}"   probe_health_rollup
assert_output_contains "ok|" "a rollup that saw 97% of its windows is green"

run_cmd json_probe observability health_rollup.json   "{\"generated_at\":\"$NOW\",\"snapshots\":1000,\"coverage_ratio\":0.85,\"verdicts\":{\"HEALTHY\":900}}"   probe_health_rollup
assert_output_contains "warn|" "85% coverage is WARN: the green periods mean less than they look"

run_cmd json_probe observability health_rollup.json   "{\"generated_at\":\"$NOW\",\"snapshots\":1000,\"coverage_ratio\":0.60,\"verdicts\":{\"HEALTHY\":900}}"   probe_health_rollup
assert_output_contains "fail|" "60% coverage is FAIL"

# The regression this node was written twice for: an old CRITICAL is history,
# not a current state, and colouring on it makes the node permanently amber
# for something already fixed -- the cumulative-counter mistake again.
run_cmd json_probe observability health_rollup.json   "{\"generated_at\":\"$NOW\",\"snapshots\":1000,\"coverage_ratio\":0.97,\"verdicts\":{\"HEALTHY\":900,\"CRITICAL\":1}}"   probe_health_rollup
assert_output_contains "ok|" "a CRITICAL from a month ago does not hold the node amber forever"
assert_output_contains "CRITICAL" "but it is still stated in the text -- silent is not the alternative to amber"

run_cmd json_probe observability health_rollup.json   "{\"generated_at\":\"$NOW\",\"snapshots\":0,\"coverage_ratio\":1.0,\"verdicts\":{}}"   probe_health_rollup
assert_output_contains "unknown|" "a rollup over zero snapshots is UNKNOWN, never a clean month"

# -- dast coverage ---------------------------------------------------------
run_cmd json_probe security dast_coverage.json   "{\"generated_at\":\"$NOW\",\"routes_total\":10,\"routes_reachable\":9,\"unreachable_by_reason\":{\"write\":1}}"   probe_dast_coverage
assert_output_contains "ok|" "9 of 10 routes reachable is green"

run_cmd json_probe security dast_coverage.json   "{\"generated_at\":\"$NOW\",\"routes_total\":10,\"routes_reachable\":4,\"unreachable_by_reason\":{\"write\":1,\"parameterised\":3,\"unlinked\":2}}"   probe_dast_coverage
assert_output_contains "warn|" "a scan reaching under half the routes is WARN however green its verdict was"
assert_output_contains "parameterised 3" "and the reasons are carried: which six were missed decides whether it matters"

run_cmd json_probe security dast_coverage.json   "{\"generated_at\":\"$NOW\",\"routes_total\":0,\"routes_reachable\":0}"   probe_dast_coverage
assert_output_contains "unknown|" "an empty route table is UNKNOWN: no denominator, no coverage"

# -- capability catalogue --------------------------------------------------
run_cmd json_probe . capabilities.json   '{"capabilities":[{"path":"a.sh","described":true},{"path":"b.py","internal_to":"a.sh"}]}'   probe_capability_catalog
assert_output_contains "ok|" "described, or internal to something described, is not an orphan"

run_cmd json_probe . capabilities.json   '{"capabilities":[{"path":"a.sh","described":true},{"path":"orphan.py","described":false}]}'   probe_capability_catalog
assert_output_contains "warn|" "a capability no document describes is WARN"
assert_output_contains "orphan.py" "and it is named"

run_cmd json_probe . capabilities.json '{"capabilities":[]}' probe_capability_catalog
assert_output_contains "unknown|" "an empty catalogue is UNKNOWN -- the enumeration broke, the repo did not empty"

suite_summary

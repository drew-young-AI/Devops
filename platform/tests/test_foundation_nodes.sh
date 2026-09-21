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

# The two ways a read can fail, which used to be one sentence.
#
# Every non-zero rc read 「生產節點讀不到」, so "the machine is not on the
# network" and "the machine answered and something is wrong" were the same
# string -- and `stage_report` binds OWNERSHIP to that string. An unreachable
# machine therefore looked like an engineering fault, fell back to the `eng`
# default, and raised `pct_ceiling_eng_only`, the number the landing standard
# reads. Observed 2026-09-11 when ubu.local stopped resolving.
prodnode_err() {  # <stderr-text>
  python3 - "$1" <<'PY2'
import os, sys
err = sys.argv[1]
sys.path.insert(0, os.path.join(os.getcwd(), "platform", "statusdag"))
import dag
dag.run = lambda cmd, timeout=25: (0, "ubu\nk3d-devops-lab\n")
dag.run_diag = lambda cmd, timeout=25: (1, "", err)
print("%s|%s" % dag.probe_prod_node())
PY2
}

run_cmd prodnode_err "Unable to connect to the server: dial tcp: lookup ubu.local: no such host"
assert_output_contains "連不上" "a name that does not resolve is reported as unreachable"

run_cmd prodnode_err "Command '['kubectl', '--context', 'ubu']' timed out after 15 seconds"
assert_output_contains "連不上" "a hung lookup that hits the timeout is unreachable too"

# NEGATIVE CONTROL: a machine that IS reachable and answering wrongly must NOT
# be absorbed into the question addressed to the user.
run_cmd prodnode_err "error: You must be logged in to the server (Unauthorized)"
assert_output_contains "讀不到" "a reachable node that refuses is still an engineering fault"
assert_output_not_contains "連不上" "and is not reported as unreachable"

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
#
# `coverage_provenance` and `observed_window` are part of every fixture from
# 2026-09-15 on, because the probe now refuses a coverage document that does
# not state it was measured -- see the two controls at the end of this block.
OBSW="\"observed_window\":{\"from\":\"$NOW\",\"to\":\"$NOW\"},\"coverage_provenance\":\"observed\""

run_cmd json_probe security dast_coverage.json   "{\"generated_at\":\"$NOW\",$OBSW,\"routes_total\":10,\"routes_reachable\":9,\"unreachable_by_reason\":{\"write\":1}}"   probe_dast_coverage
assert_output_contains "ok|" "9 of 10 routes reachable is green"

run_cmd json_probe security dast_coverage.json   "{\"generated_at\":\"$NOW\",$OBSW,\"routes_total\":10,\"routes_reachable\":4,\"unreachable_by_reason\":{\"write\":1,\"parameterised\":3,\"unlinked\":2}}"   probe_dast_coverage
assert_output_contains "warn|" "a scan reaching under half the routes is WARN however green its verdict was"
assert_output_contains "parameterised 3" "and the reasons are carried: which six were missed decides whether it matters"

run_cmd json_probe security dast_coverage.json   "{\"generated_at\":\"$NOW\",$OBSW,\"routes_total\":0,\"routes_reachable\":0}"   probe_dast_coverage
assert_output_contains "unknown|" "an empty route table is UNKNOWN: no denominator, no coverage"

# A coverage document with no provenance is one written before coverage was
# measured -- or by something that declared it. Either way the number is not
# evidence of what the scan touched, and reading it as though it were is the
# exact defect the 2026-09-15 change removed. It must not quietly go green.
run_cmd json_probe security dast_coverage.json   "{\"generated_at\":\"$NOW\",\"routes_total\":10,\"routes_reachable\":9,\"unreachable_by_reason\":{\"write\":1}}"   probe_dast_coverage
assert_output_contains "unknown|" "catches: a coverage number that does not say it was measured is UNKNOWN, not green"

# AGE COMES FROM THE SCAN, NOT FROM THE ARITHMETIC. `dastcov` recomputes daily,
# so `generated_at` is always fresh; if the probe aged on that, a scan that had
# not run for six weeks would still read as current. This fixture is the shape
# that produces: today's report over a long-dead observation.
STALEW="$(python3 -c "
import datetime
print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=40)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
run_cmd json_probe security dast_coverage.json   "{\"generated_at\":\"$NOW\",\"observed_window\":{\"from\":\"$STALEW\",\"to\":\"$STALEW\"},\"coverage_provenance\":\"observed\",\"routes_total\":10,\"routes_reachable\":9,\"unreachable_by_reason\":{\"write\":1}}"   probe_dast_coverage
assert_output_contains "warn|" "catches: a fresh report over a 40-day-old scan is WARN, not green"
assert_output_contains "40 天" "and it says how old the SCAN is, not how old the report is"

# -- capability catalogue --------------------------------------------------
run_cmd json_probe . capabilities.json   '{"capabilities":[{"path":"a.sh","described":true},{"path":"b.py","internal_to":"a.sh"}]}'   probe_capability_catalog
assert_output_contains "ok|" "described, or internal to something described, is not an orphan"

run_cmd json_probe . capabilities.json   '{"capabilities":[{"path":"a.sh","described":true},{"path":"orphan.py","described":false}]}'   probe_capability_catalog
assert_output_contains "warn|" "a capability no document describes is WARN"
assert_output_contains "orphan.py" "and it is named"

run_cmd json_probe . capabilities.json '{"capabilities":[]}' probe_capability_catalog
assert_output_contains "unknown|" "an empty catalogue is UNKNOWN -- the enumeration broke, the repo did not empty"

# --------------------------------- published is not still publishing (MLOps)
# `forecast` counts rows and cannot fall. If publishing stopped a month ago it
# still reads "4 筆已發布預測" while the actuals march on and every one of
# those four becomes a forecast of a week we already know the answer to.
sql_probe() {  # <probe-fn> <first-answer> <second-answer>
  python3 - "$1" "$2" "$3" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.getcwd(), "platform", "statusdag"))
import dag
answers = [sys.argv[2], sys.argv[3]]
calls = {"n": 0}
def fake_psql(q, *a, **k):
    i = calls["n"]; calls["n"] += 1
    v = answers[i] if i < len(answers) else ""
    return None if v == "NULL" else v.replace("~", "\n")
dag.psql = fake_psql
print("%s|%s" % getattr(dag, sys.argv[1])())
PY
}

run_cmd sql_probe probe_forecast_lead "2026|35" "2026|37"
assert_output_contains "ok|" "a t+2 model whose newest target leads the newest actual by 2 is working"

run_cmd sql_probe probe_forecast_lead "2026|37" "2026|37"
assert_output_contains "warn|" "a forecast for a week we already have actuals for is not a forecast"
run_cmd sql_probe probe_forecast_lead "2026|40" "2026|37"
assert_output_contains "warn|" "and falling behind is WARN however many rows the forecast table holds"

run_cmd sql_probe probe_forecast_lead "2026|35" ""
assert_output_contains "fail|" "no forecast at all is FAIL"
run_cmd sql_probe probe_forecast_lead "" "2026|37"
assert_output_contains "unknown|" "forecasts with no actuals to compare against is UNKNOWN, not OK"
run_cmd sql_probe probe_forecast_lead "NULL" "NULL"
assert_output_contains "unknown|" "a database that did not answer is UNKNOWN"

# ------------------------------------- balanced and accepting nothing (DataOps)
# `lineage` proves file rows = accepted + rejected + duplicate, and that stays
# true when a source rejects EVERY row -- which is what an upstream column
# rename does. `facts` reports a count that does not fall. Three green nodes
# over a feed that has stopped contributing.
run_cmd sql_probe probe_ingest_quality "a|1000|5~b|500|1" ""
assert_output_contains "ok|" "half a percent rejected is green"
run_cmd sql_probe probe_ingest_quality "a|1000|80~b|500|1" ""
assert_output_contains "warn|" "8% rejected on one source is WARN"
assert_output_contains "a " "and the source is named -- 'ingest quality is down' sends nobody anywhere"
run_cmd sql_probe probe_ingest_quality "a|1000|1000~b|500|1" ""
assert_output_contains "fail|" "a source rejecting every row is FAIL: it has stopped contributing"
run_cmd sql_probe probe_ingest_quality "" ""
assert_output_contains "unknown|" "no ingest runs is UNKNOWN -- an empty scan is not a clean one"
run_cmd sql_probe probe_ingest_quality "NULL" ""
assert_output_contains "unknown|" "a database that did not answer is UNKNOWN"

# ------------------------------------------- the gate must not be bypassable
# publish_forecast.py enforces `AND mr.beats_baselines` at publish time. That
# is a guarantee about one code path; probe_lineage exists because a CHECK
# constraint that was dropped leaves no trace, and neither does an edited
# WHERE clause. This asks the data instead.
run_cmd sql_probe probe_gate_integrity "0|4" ""
assert_output_contains "ok|" "four published forecasts, none from a losing run, is green"
run_cmd sql_probe probe_gate_integrity "1|4" ""
assert_output_contains "fail|" "a single forecast from a run that lost to the baselines is FAIL"
run_cmd sql_probe probe_gate_integrity "0|0" ""
assert_output_contains "unknown|" "an empty forecast table is UNKNOWN: 'nothing was published in violation' is trivially true over nothing"
run_cmd sql_probe probe_gate_integrity "NULL" ""
assert_output_contains "unknown|" "a database that did not answer is UNKNOWN"


# ── epiweek: the crosswalk, and the day it runs out ────────────────────────
#
# This node used to count `time_period` rows with a NULL cal_date and call that
# the gap. 1,027 of those rows are weeks and 21 are years, and neither IS a
# date -- so it could only go green by writing a misleading value into a column
# that means "this day" everywhere else. It measured a modelling artefact.
#
# It now measures joinability, filled from 疾管署's own published crosswalk.
# The controls below matter more than usual because THE NUMBER MOVED IN THE
# FLATTERING DIRECTION: DataOps gained a green node on the same day the person
# who decided the old measurement was wrong was the one who benefited. So every
# branch that can refuse has to be shown refusing.
#
# The horizon branch is the real silent failure: the snapshot ends 2026-12-31,
# after which new days arrive unlabelled and every week-vs-day comparison
# quietly stops including them.
epiweek_probe() {  # <json>
  python3 - "$FIX" "$1" <<'PY2'
import json, os, sys
root, doc = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(os.getcwd(), "platform", "statusdag"))
import dag
d = os.path.join(root, "epiweek_ev", "data")
os.makedirs(d, exist_ok=True)
if doc != "-":
    with open(os.path.join(d, "epiweek_calendar.json"), "w") as fh:
        fh.write(doc)
dag.EVIDENCE = os.path.join(root, "epiweek_ev")
print("%s|%s" % dag.probe_epiweek())
PY2
}

epiweek_doc() {  # <total> <mappable> <crosswalk-last> [labelled] [dupdates]
  printf '{"day_periods":%s,"day_periods_mappable":%s,"crosswalk_last":"%s",' "$1" "$2" "$3"
  printf '"day_rows_with_week_label":%s,"duplicate_day_dates":%s,' "${4:-0}" "${5:-0}"
  printf '"rows_in_epi_calendar":7305,"weeks_joinable":558,'
  printf '"unmappable_days":["2027-01-01"],'
  printf '"source_url":"https://nidss.cdc.gov.tw/config/DIM_CAL.csv"}'
}

# UTC, and never within a day of a boundary.
#
# The first version used `date.today()` -- LOCAL time -- while probe_epiweek
# compares against `datetime.now(timezone.utc).date()`. In UTC+8 the two
# disagree for eight hours out of every day, so "yesterday" locally could still
# be "today" in UTC: days_left came out 0 instead of -1, WARN instead of FAIL,
# and the suite went red on 2026-09-13 for no reason but the clock. A control
# that depends on the hour is worse than no control -- it teaches people that
# red means "run it again".
_utc_day() { python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc).date()+datetime.timedelta(days=$1)))"; }
FAR="$(_utc_day 400)"
SOON="$(_utc_day 30)"
GONE="$(_utc_day -3)"

run_cmd epiweek_probe "$(epiweek_doc 3885 3885 "$FAR")"
assert_output_contains "ok|" "every day labelled and the crosswalk still has a year left is green"

run_cmd epiweek_probe "$(epiweek_doc 3885 3800 "$FAR")"
assert_output_contains "fail|" "days the crosswalk does not cover are FAIL, not a rounding error"
assert_output_contains "2027-01-01" "and one of them is named"

run_cmd epiweek_probe "$(epiweek_doc 3885 3885 "$SOON")"
assert_output_contains "warn|" "a crosswalk that runs out in 30 days warns BEFORE it runs out"

run_cmd epiweek_probe "$(epiweek_doc 3885 3885 "$GONE")"
assert_output_contains "fail|" "a crosswalk that has already run out is FAIL"

run_cmd epiweek_probe "$(epiweek_doc 0 0 "$FAR")"
assert_output_contains "unknown|" "zero day periods is UNKNOWN: the enumeration broke, the database is not empty"

run_cmd epiweek_probe -
assert_output_contains "unknown|" "no evidence file is UNKNOWN, not a clean calendar"

# THE REGRESSION THAT COST 4.1M ROWS (2026-09-13, rolled back 09-14).
#
# The crosswalk was first written into time_period.epi_year/epi_week on the day
# rows. Those columns are part of
#   UNIQUE NULLS NOT DISTINCT (time_level, epi_year, epi_week, cal_date)
# so labelling a day row changed its natural key, load_dimensional.py's
# ON CONFLICT stopped matching, and one ingest inserted a second copy of every
# day row: 3,885 -> 7,777 periods and 4.1M -> 8.2M facts. Nothing noticed until
# the labelling job itself failed on the constraint it had made unsatisfiable.
#
# Migration 019 moved the mapping to its own table. These two controls are what
# makes a relapse loud instead of silent -- a day row carrying a week label is
# the defect, not a symptom of it.
run_cmd epiweek_probe "$(epiweek_doc 3892 3892 "$FAR" 17 0)"
assert_output_contains "fail|" "a day row carrying a week label is FAIL: the natural key is broken"
assert_output_contains "自然鍵" "and says the natural key is what broke"

run_cmd epiweek_probe "$(epiweek_doc 3892 3892 "$FAR" 0 5)"
assert_output_contains "fail|" "duplicate day rows for one date are FAIL: an ingest already re-inserted"

run_cmd epiweek_probe "$(epiweek_doc 3892 3892 "$FAR" 0 0)"
assert_output_contains "ok|" "and a clean natural key with a live crosswalk is green"

# The crosswalk must stay a LOOKUP. A rule would be wrong for 2007-2009, where
# CDC truncated weeks at the calendar boundary: 2009 week 01 is Jan 1-3 and
# week 02 starts Jan 4, contradicting CDC's own published rule. These three
# dates are the exact cases an arithmetic implementation gets wrong, and they
# are asserted against the vendored file so a "simplification" to a formula
# cannot pass silently.
run_cmd python3 - <<'PY3'
import os, sys
sys.path.insert(0, os.path.join(os.getcwd(), "pilots", "station2-publichealth", "ingest"))
from load_epiweek_calendar import load_crosswalk
cal = load_crosswalk()
want = {"2008-12-28": (2008, 53), "2008-12-31": (2008, 53),
        "2009-01-01": (2009, 1),  "2009-01-03": (2009, 1),
        "2009-01-04": (2009, 2),  "2010-01-02": (2009, 53)}
bad = {d: (cal.get(d), w) for d, w in want.items() if cal.get(d) != w}
print("MISMATCH" if bad else "OK", bad or "")
PY3
assert_output_contains "OK" "the year-boundary weeks a formula would get wrong are read from the table"

echo "== age_hours_iso must parse the stamps this repo actually writes =="
#
# THE ROOT CAUSE, TESTED DIRECTLY. The dast-coverage fixture above catches this
# end to end, but only for one probe. The helper is shared, and the failure is
# silent by construction: an unparseable stamp is caught and returned as None,
# which every caller reads as "no age known" and therefore "not stale". A guard
# that cannot fire reads exactly like a guard with nothing to report.
#
# Two shapes are in use here and BOTH must work:
#   2026-09-09T20:31:07+08:00   isoformat() with a local offset (gha_status)
#   2026-09-15T14:26:34Z        strftime("%Y-%m-%dT%H:%M:%SZ") (everything else)
# On Python 3.9 `fromisoformat` accepts the first and REJECTS the second.
# A HEREDOC INSIDE $( ) IS WHY THIS IS A FILE. The first version nested
# `<<'AGEPY'` inside a command substitution; bash accepted it, the substitution
# produced an empty string, and the assertion failed with no diagnostic at all.
# The same shape broke sync_remote.sh earlier this month.
AGEPROBE="$(mktemp)"
cat > "$AGEPROBE" <<'AGEPY'
import datetime, importlib.util, sys
spec = importlib.util.spec_from_file_location("dag", sys.argv[1])
dag = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dag)
past = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=48)
out = []
for label, stamp in (
        ("Z", past.strftime("%Y-%m-%dT%H:%M:%SZ")),
        ("offset", past.astimezone().isoformat(timespec="seconds")),
        ("naive", past.strftime("%Y-%m-%dT%H:%M:%S")),
):
    hours = dag.age_hours_iso(stamp)
    out.append("%s=%s" % (label, "none" if hours is None else round(hours)))
print(",".join(out))
AGEPY
AGES="$(python3 "$AGEPROBE" "$REPO_ROOT/platform/statusdag/dag.py" 2>&1)"
rm -f "$AGEPROBE"
assert_equals "Z=48,offset=48,naive=48" "$AGES" \
  "catches: a trailing Z is an age, not an unparseable stamp silently read as fresh"

echo "== newest() must mean most-recently-written, not last-by-name =="
#
# `llm_review_<sha>_<ts>.json` puts the sha before the timestamp, so name order
# and time order disagree: llm_review_9daa7fa_20260911 sorts AFTER
# llm_review_0b597bc_20260914. The board read a three-day-old review as current
# and called it stale while a fresh one sat beside it (2026-09-14). Re-running
# the review changed nothing, which is how a wrong "newest" hides -- the output
# is a real artefact, just not the right one.
run_cmd python3 - <<'PY4'
import os, sys, tempfile, time
sys.path.insert(0, os.path.join(os.getcwd(), "platform", "statusdag"))
import dag
d = tempfile.mkdtemp()
older_name_higher = os.path.join(d, "llm_review_9daa7fa_20260911T071645Z.json")
newer_name_lower  = os.path.join(d, "llm_review_0b597bc_20260914T152818Z.json")
open(older_name_higher, "w").write("{}")
time.sleep(1.1)
open(newer_name_lower, "w").write("{}")        # written LAST, sorts FIRST by name
dag.EVIDENCE = d
got = os.path.basename(dag.newest("llm_review_*.json") or "")
print("PICKED", got)
print("CORRECT" if got == os.path.basename(newer_name_lower) else "WRONG")
PY4
assert_rc 0 "newest() runs against a directory where name order and time order disagree"
assert_output_contains "CORRECT" "and returns the file written last, not the one sorting last"

# ---- and mtime must not be the rule, because git resets it ---------------
#
# 2026-09-20: restoring a few historical evidence files with `git checkout`
# stamped four four-day-old DAST summaries with "now". `newest()` was picking
# by mtime, so the board read one of them and reported `PASS, 88h ago --
# stale` while a 19-hour-old PASS sat in the same directory. Nothing errored.
# A fresh clone does this to every probe at once, which is the case worth
# guarding: the producer's timestamp is IN THE NAME and that is what it means.
run_cmd python3 - <<'PY5'
import os, sys, tempfile, time
sys.path.insert(0, os.path.join(os.getcwd(), "platform", "statusdag"))
import dag
d = tempfile.mkdtemp()
real_latest = os.path.join(d, "dast_summary_20260918T210003Z.json")
stale_restored = os.path.join(d, "dast_summary_20260916T002058Z.json")
open(real_latest, "w").write("{}")
time.sleep(1.1)
open(stale_restored, "w").write("{}")   # what `git checkout` does: old file, new mtime
dag.EVIDENCE = d
got = os.path.basename(dag.newest("dast_summary_*.json") or "")
print("PICKED", got)
print("BYNAME" if got == os.path.basename(real_latest) else "BYMTIME")
PY5
assert_rc 0 "newest() runs against a directory whose mtimes were reset by git"
assert_output_contains "BYNAME" \
  "the producer's timestamp in the filename wins over an mtime git rewrote"

# ---- and the mtime fallback still has to work ----------------------------
#
# With the name-stamp rule in front, both cases above now take the SAME code
# path -- so the fallback branch, which is what fixed the llm_review bug in
# the first place, has no control at all. This is that control: candidates
# with no timestamp in their names must still resolve by mtime.
run_cmd python3 - <<'PY6'
import os, sys, tempfile, time
sys.path.insert(0, os.path.join(os.getcwd(), "platform", "statusdag"))
import dag
d = tempfile.mkdtemp()
first = os.path.join(d, "rotation_alpha.json")
second = os.path.join(d, "rotation_beta.json")   # sorts AFTER, written FIRST
open(second, "w").write("{}")
time.sleep(1.1)
open(first, "w").write("{}")                      # sorts BEFORE, written LAST
dag.EVIDENCE = d
got = os.path.basename(dag.newest("rotation_*.json") or "")
print("PICKED", got)
print("BYMTIME" if got == os.path.basename(first) else "BYNAME_OR_WRONG")
PY6
assert_rc 0 "newest() runs against candidates whose names carry no timestamp"
assert_output_contains "BYMTIME" \
  "and falls back to mtime there, which is what fixed the llm_review case"


suite_summary

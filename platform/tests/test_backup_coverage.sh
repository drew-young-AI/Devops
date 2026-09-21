#!/usr/bin/env bash
# The backup coverage gate: does it actually refuse?
#
# WHY THIS SUITE EXISTS.
#
# The gate's whole job is to say "something is unprotected". It had a hole big
# enough to swallow the entire Kubernetes stateful layer: local-path writes PVC
# data into the node's /var/lib/rancher/k3s, that path sits on an ANONYMOUS
# docker volume, and the gate classified 64-hex volumes as "docker's own
# scratch". A database moved into the cluster would have been backed up by
# nothing while the run printed BACKUP PASS.
#
# A gate is only worth having if it can be shown to fail. Four states, and
# three of them must refuse:
#
#   1. clean               PASS
#   2. unclassified PVC    FAIL, naming the PVC
#   3. cluster down, never held a PVC        PASS, assumption stated
#   4. cluster down, DID hold a PVC          FAIL
#
# 3 and 4 are the same command with different history, which is exactly why the
# gate keeps a record instead of asking the cluster: an unreachable cluster
# cannot tell you whether it holds anything.
#
# Uses --check-only (about half a second) so this can live in the suite rather
# than being a thing someone runs by hand once.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
BACKUP="$REPO_ROOT/platform/backup/backup.sh"
STATE="$REPO_ROOT/evidence/backup/last_known_pvcs.txt"
CTX="${K8S_CTX:-k3d-devops-lab}"
PROBE_NS="backupgate-probe"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

echo "=== backup coverage gate ==="

kubectl --context "$CTX" get --raw /readyz >/dev/null 2>&1 \
  || { echo "  cluster '$CTX' does not answer; this suite needs it." >&2; exit 1; }

# The real state file is restored no matter how this exits -- including SIGTERM,
# which is how the scheduler kills a job that overruns. A drill that leaves the
# platform's own bookkeeping altered is worse than no drill.
STATE_BACKUP="$(mktemp)"

cp "$STATE" "$STATE_BACKUP" 2>/dev/null || : > "$STATE_BACKUP"
restore_state() {
  cp "$STATE_BACKUP" "$STATE" 2>/dev/null
  rm -f "$STATE_BACKUP"
  kubectl --context "$CTX" delete ns "$PROBE_NS" --ignore-not-found --wait=false >/dev/null 2>&1
}
# A RAW trap, not lib.sh::on_exit. This suite does not source lib.sh -- it has
# its own PASS/FAIL counters, like the other cluster suites -- so `on_exit`
# here is an undefined command: it prints "command not found" to a stderr
# nobody reads and registers nothing. That is exactly what happened on
# 2026-09-04 when the on_exit conversion was applied by pattern across the
# directory: this suite's state restore silently stopped running and left
# evidence/backup/last_known_pvcs.txt holding the test's fixture value.
#
# lib.sh's own header warns about this shape for assertion helpers. It applies
# to cleanup the same way, and worse: a missing assertion reports a check that
# did not happen, a missing cleanup leaves the platform's bookkeeping altered.
trap restore_state EXIT INT TERM

run_gate() { "$BACKUP" --check-only 2>&1; }

# --- 1. clean ---------------------------------------------------------------
OUT="$(run_gate)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "COVERAGE PASS"; then
  ok "clean platform passes"
else
  bad "clean platform did not pass (rc=$RC)" "$(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')"
fi

# --- 1b. a RUNNING database must be dumped, never tarred --------------------
#
# 2026-09-20. `backup.sh` chooses between `pg_dump` (correct while the database
# is serving) and `tar` of the data directory (correct only while it is
# stopped). The choice was made by matching the container name against
# `docker ps --format '{{.Names}}'`; when the caller started passing a resolved
# container ID, the match could not succeed, and the fall-through branch was
# the TAR one. The backup reported success and archived a live PostgreSQL data
# directory -- a file nobody would question until a restore, months later.
#
# The test is on the ARTEFACT, not on the code path: whatever the script
# decides internally, a running database must leave a `.dump` in the manifest.
# NEWEST BY THE DIRECTORY'S OWN TIMESTAMP, NOT BY mtime.
#
# The archive directories are named 20260920T002141Z. mtime says when the
# filesystem last wrote those bytes, which `git checkout`, a clone or a rebase
# resets to "now" -- the same defect that made the board read a four-day-old
# DAST result as current (see newest() in platform/statusdag/dag.py). Picking
# by mtime here would let this assertion pass against an old manifest while
# last night's backup was the broken one.
LATEST_MANIFEST="$(ls -1d "$REPO_ROOT"/platform/backup/archives/*/ 2>/dev/null \
  | sed 's:/$::' | sort | tail -1)/manifest.json"
[ -f "$LATEST_MANIFEST" ] || LATEST_MANIFEST=""

# THREE STATES, NOT TWO. pilot_db.sh exits 3 for "no running container" and
# non-zero for other failures (docker down, compose file moved). Reading every
# failure as "the database is stopped, so tar was correct" would skip this
# assertion forever after a directory rename -- which is exactly the change
# that broke the dump/tar choice in the first place.
"$REPO_ROOT/platform/db/pilot_db.sh" container >/dev/null 2>&1
case $? in
  0) DB_STATE=running ;;
  3) DB_STATE=down ;;
  *) DB_STATE=unknown ;;
esac
if [ -z "$LATEST_MANIFEST" ]; then
  echo "  SKIP  no backup archive on this host -- the dump-vs-tar rule is UNVERIFIED"
elif [ "$DB_STATE" = "down" ]; then
  echo "  SKIP  the pilot database is not running -- tar would be the correct choice"
elif [ "$DB_STATE" = "unknown" ]; then
  bad "the dump-vs-tar rule is checkable" \
      "pilot_db.sh could not say whether the database is running -- that is not 'it is stopped'"
else
  ARCHIVE_KIND="$(python3 - "$LATEST_MANIFEST" <<'PYK'
import json, sys
m = json.load(open(sys.argv[1]))
for v in m.get("volumes", []):
    if v.get("volume", "").endswith("twin-db"):
        print(v.get("archive", "missing"))
        break
else:
    print("absent")
PYK
)"
  case "$ARCHIVE_KIND" in
    *.dump)   ok "the newest backup dumped the running database ($ARCHIVE_KIND)" ;;
    *.tar.gz) bad "the newest backup dumped the running database" \
                  "it tarred a LIVE data directory instead: $ARCHIVE_KIND" ;;
    *)        bad "the newest backup dumped the running database" \
                  "no entry for the pilot database volume: $ARCHIVE_KIND" ;;
  esac
fi

# --- 2. an unclassified PVC must be refused ---------------------------------
kubectl --context "$CTX" create ns "$PROBE_NS" >/dev/null 2>&1
cat <<YAML | kubectl --context "$CTX" apply -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: unclassified, namespace: $PROBE_NS}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 32Mi}}
YAML
OUT="$(run_gate)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "$PROBE_NS|unclassified"; then
  ok "an unclassified PVC is refused, and named"
else
  bad "an unclassified PVC was NOT refused (rc=$RC)" \
      "this is the hole the rewrite closed; it is open again"
fi
kubectl --context "$CTX" delete ns "$PROBE_NS" --wait=true >/dev/null 2>&1

# --- 3. cluster down, no PVC ever recorded ----------------------------------
: > "$STATE"
OUT="$(K8S_CTX=k3d-definitely-not-a-cluster "$BACKUP" --check-only 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "last successful check found no PVC"; then
  ok "cluster down with no PVC history passes, and says what it assumed"
else
  bad "cluster down with no PVC history did not pass cleanly (rc=$RC)" \
      "a red light that fires every time the laptop's cluster is off is a red light nobody reads"
fi

# --- 4. cluster down, PVCs WERE there ---------------------------------------
printf 'somewhere|important\n' > "$STATE"
OUT="$(K8S_CTX=k3d-definitely-not-a-cluster "$BACKUP" --check-only 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "unreachable with known PVCs"; then
  ok "cluster down with known PVCs is refused"
else
  bad "cluster down with known PVCs was NOT refused (rc=$RC)" \
      "'the cluster was off' would become 'the database was never backed up'"
fi

# k3d node volumes must lose their excuse in state 4 as well: the exclusion is
# justified by 'the PVC data inside is covered per-PVC', which cannot hold when
# the PVCs could not be enumerated.
if printf '%s' "$OUT" | grep -q "k3d node volume(s) hold"; then
  ok "k3d node volumes lose their exemption while Kubernetes is unreachable"
else
  bad "k3d node volumes stayed exempt with an unreachable cluster" \
      "/var/lib/rancher/k3s holds every PVC's data and was excused with no basis"
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

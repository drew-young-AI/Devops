#!/usr/bin/env bash
# Blue/green on Kubernetes, proved end to end -- including that a BAD colour
# cannot be promoted.
#
# The positive path is the easy half. Every blue/green demo shows traffic moving
# from one version to another. What makes it a deploy STRATEGY is the half that
# refuses, so three of the five scenarios below are negative controls.
#
# NEGATIVE CONTROL 1 already found a real bug in this very directory. The first
# deployment template used a bare `SCHEMA_VERSION` placeholder, and sed matched
# it INSIDE the variable name `EXPECTED_SCHEMA_VERSION` -- producing a container
# with `EXPECTED_99=99` and no EXPECTED_SCHEMA_VERSION at all. The app fell back
# to its compiled default, which happened to equal the database, so a
# deliberately-broken green reported "ready" and the gate promoted it. Nothing
# in review caught that; the negative control did, on its first run.
#
# NEGATIVE CONTROL 2 found a second one: readyReplicas counts pods from the
# PREVIOUS generation during a stuck rollout, so a green whose new pods can
# never start still reports 2/2. The gate now checks updatedReplicas as well.
#
# Time-bounded: ~3 minutes. Leaves the cluster on blue with both colours
# deployed, which is the resting state.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTX="${CTX:-k3d-devops-lab}"
NS=station2
PASS=0; FAIL=0
k() { kubectl --context "$CTX" -n "$NS" "$@"; }
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; FAIL=$((FAIL+1)); }

probe_once() {
  k run bgprobe-$RANDOM --rm -i --restart=Never --image=curlimages/curl:8.10.1 \
    --timeout=60s --quiet -- -s --max-time 5 http://station2-twin:8080/version 2>/dev/null \
    | tr -d '\r' | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["version"])
except Exception: print("UNREACHABLE")' 2>/dev/null
}

# Retry, because ONE probe failure is not evidence of anything.
#
# This probe schedules a fresh pod per call, so it can come back UNREACHABLE for
# reasons that have nothing to do with the Service: scheduling delay, image
# pull, the 60s run timeout. On 2026-09-03 that happened during scenario 2 and
# the suite printed "traffic moved despite refusal: 'UNREACHABLE'" -- claiming
# the release gate had leaked traffic, when what actually happened is that the
# probe could not tell. A rerun passed 8/8 with nothing changed.
#
# That message was the real defect. A test that reports "I could not measure"
# as "the safety property was violated" is a test whose red gets explained away
# -- and this suite guards the one gate that stands between a broken build and
# production traffic. Three bounded attempts, then say plainly which of the two
# it is; UNREACHABLE is never again reported as a colour change.
serving() {
  local v i
  for i in 1 2 3; do
    v="$(probe_once)"
    [ "$v" != "UNREACHABLE" ] && { printf '%s' "$v"; return 0; }
  done
  printf 'UNREACHABLE'
  return 1
}

# Assert the Service is serving an expected colour, keeping "wrong colour" and
# "could not measure" as different verdicts.
# A THIRD OUTCOME: THE SELECTOR MOVED BUT THE ENDPOINTS HAVE NOT YET.
#
# `promote.sh` patches the Service selector and returns. kube-proxy rewrites
# the endpoint set asynchronously, so a probe issued immediately afterwards can
# still land on the previous colour. That is propagation, not a failed
# promotion -- but the first version of this function could not tell them
# apart, and reported the old colour as "promote reported success but Service
# serves 'blue-v15'". It passed standalone and failed inside the full suite,
# which is the signature of a race and not of a defect in promote.sh.
#
# So the wrong colour is retried, bounded, and the convergence time is PRINTED
# rather than swallowed. Bounded because an unbounded wait would turn a genuine
# failed promotion into a slow pass; printed because "how long does a promote
# take to reach traffic" is a number worth having, and hiding it is how a
# gradually worsening propagation becomes invisible until it crosses the bound.
SERVES_DEADLINE="${SERVES_DEADLINE:-20}"

serves() {
  local want="$1" msg="$2" got start elapsed
  start=$(date +%s)
  while :; do
    got="$(serving)"
    elapsed=$(( $(date +%s) - start ))
    [ "$got" = "$want" ] && break
    [ "$elapsed" -ge "$SERVES_DEADLINE" ] && break
    sleep 1
  done

  if [ "$got" = "$want" ]; then
    if [ "$elapsed" -gt 0 ]; then ok "$msg ($got, converged in ${elapsed}s)"
    else ok "$msg ($got)"; fi
  elif [ "$got" = "UNREACHABLE" ]; then
    bad "UNMEASURED: $msg" "probes failed to reach the Service for ${elapsed}s; this is NOT evidence the colour changed"
  else
    bad "$msg -- Service still serves '$got' after ${elapsed}s, expected '$want'"
  fi
}

# ── preflight: prove the probe's own verdicts still work ────────────────────
#
# These stub probe_once and touch no cluster (~0s). They exist because the
# retry and the UNMEASURED verdict below are themselves guards, and a guard
# nobody has seen go red is indistinguishable from one that cannot. Running
# them here rather than in a separate suite keeps them attached to the thing
# they check -- a control in another file is a control that gets deleted.
preflight() {
  local out saved rc=0 cnt
  saved="$(declare -f probe_once)"
  # The two negative controls below stub a probe that never returns the wanted
  # value, so they would otherwise sit out the full propagation deadline twice.
  # A 2s deadline still exercises the loop and keeps preflight at ~0s, which is
  # what makes it cheap enough to leave attached to the suite it guards.
  local SERVES_DEADLINE=2

  probe_once() { echo UNREACHABLE; }
  out="$(serves blue-v15 "probe control" 2>&1)"
  case "$out" in
    *UNMEASURED*) case "$out" in
        *"expected '"*) bad "control: unreachable still claimed a colour change"; rc=1 ;;
        *) ok "control: 3 failed probes report UNMEASURED, not a colour change" ;;
      esac ;;
    *) bad "control: an unreachable Service did not report UNMEASURED" "$out"; rc=1 ;;
  esac

  probe_once() { echo green-v15-green; }
  out="$(serves blue-v15 "probe control" 2>&1)"
  case "$out" in
    *"serves 'green-v15-green'"*|*"expected 'blue-v15'"*)
      ok "control: a real colour change is still reported as one" ;;
    *) bad "control: a real colour change was swallowed" "$out"; rc=1 ;;
  esac

  # a file, not a variable: every $(probe_once) is its own subshell, so an
  # in-memory counter resets each call and attempt 3 is never reached
  cnt="$(mktemp)"; echo 0 > "$cnt"
  probe_once() {
    local n; n=$(( $(cat "$cnt") + 1 )); echo "$n" > "$cnt"
    [ "$n" -lt 3 ] && echo UNREACHABLE || echo blue-v15
  }
  out="$(serves blue-v15 "probe control" 2>&1)"
  rm -f "$cnt"
  case "$out" in
    *PASS*) ok "control: a transient failure recovers on retry, not a red suite" ;;
    *) bad "control: retry did not recover from two transient failures" "$out"; rc=1 ;;
  esac

  eval "$saved"          # always restore the real probe
  return $rc
}
preflight

# ── what this suite must put back ──────────────────────────────────────────
#
# Scenario 5 deletes the green Deployment on purpose -- refusing to promote a
# colour that does not exist is a property worth proving -- and until
# 2026-09-03 it left it deleted. So every full test run quietly dismantled the
# standing green environment and left the platform on blue, which is why
# `promote.sh green` was later REFUSED with "no deployment for colour 'green'"
# on a platform where green had been serving that morning.
#
# CLAUDE.md §5c already requires that a test which mutates state restores it in
# a trap. That rule was being applied to the stubbed functions inside this file
# and not to the cluster the file deploys into -- the more expensive of the
# two, and the one nothing else would notice.
#
# Recorded BEFORE anything is deployed, restored in the trap regardless of how
# the suite exits.
GREEN_EXISTED=0
k get deploy station2-twin-green >/dev/null 2>&1 && GREEN_EXISTED=1
SERVING_AT_START="$(k get svc station2-twin -o jsonpath='{.spec.selector.color}' 2>/dev/null)"

restore_cluster() {
  local rc=$?
  if [ "$GREEN_EXISTED" = 1 ] && ! k get deploy station2-twin-green >/dev/null 2>&1; then
    echo "  [restore] re-creating the green deployment this suite deleted"
    "$HERE/deploy.sh" green v15-green 15 >/dev/null 2>&1 \
      || echo "  [restore] FAILED to re-create green -- promote.sh green will refuse" >&2
  fi
  if [ -n "$SERVING_AT_START" ]; then
    local now
    now="$(k get svc station2-twin -o jsonpath='{.spec.selector.color}' 2>/dev/null)"
    if [ "$now" != "$SERVING_AT_START" ]; then
      echo "  [restore] returning traffic to '$SERVING_AT_START'"
      "$HERE/promote.sh" "$SERVING_AT_START" >/dev/null 2>&1 \
        || echo "  [restore] FAILED to return traffic to $SERVING_AT_START" >&2
    fi
  fi
  return $rc
}
trap restore_cluster EXIT INT TERM

echo "=== blue/green on kubernetes ==="

# ── scenario 1: baseline ────────────────────────────────────────────────────
"$HERE/deploy.sh" blue v15 15 >/dev/null 2>&1
k patch svc station2-twin -p '{"spec":{"selector":{"app":"station2-twin","color":"blue"}}}' >/dev/null 2>&1
serves blue-v15 "baseline: Service serves blue"

# ── scenario 2: NEGATIVE -- a green that cannot become Ready ────────────────
# EXPECTED_SCHEMA_VERSION=99 against a database at 15. The pod runs, answers
# liveness, and is correctly refused readiness -- so it must never receive
# traffic, and promotion must refuse it rather than time out or half-switch.
k delete deploy station2-twin-green --wait=true >/dev/null 2>&1
"$HERE/deploy.sh" green v15-green 99 >/dev/null 2>&1
if "$HERE/promote.sh" green >/dev/null 2>&1; then
  bad "a green expecting schema 99 was PROMOTED" "the gate is not gating"
else
  ok "promotion refused a green whose schema does not match the database"
fi
serves blue-v15 "traffic stayed on blue after the refusal"

# ── scenario 3: POSITIVE -- a healthy green ────────────────────────────────
k delete deploy station2-twin-green --wait=true >/dev/null 2>&1
"$HERE/deploy.sh" green v15-green 15 >/dev/null 2>&1
if "$HERE/promote.sh" green >/dev/null 2>&1; then
  V=$(serving)
  [ "$V" = "green-v15-green" ] && ok "promoted to green, Service now serves $V" \
    || { [ "$V" = "UNREACHABLE" ] \
         && bad "UNMEASURED: promoted to green" "3 probes failed; NOT evidence the promotion failed" \
         || bad "promote reported success but Service serves '$V'"; }
else
  bad "a healthy green was refused promotion"
fi

# ── scenario 4: rollback ───────────────────────────────────────────────────
# The property that separates blue/green from a rolling update: the previous
# version is still running, so going back is a selector flip, not a redeploy.
START=$(date +%s)
"$HERE/promote.sh" blue >/dev/null 2>&1
ELAPSED=$(( $(date +%s) - START ))
V=$(serving)
[ "$V" = "blue-v15" ] && ok "rolled back to blue in ${ELAPSED}s ($V)" \
  || { [ "$V" = "UNREACHABLE" ] \
       && bad "UNMEASURED: rollback" "3 probes failed; NOT evidence the rollback failed" \
       || bad "rollback left Service serving '$V'"; }

BOTH=$(k get deploy -o name 2>/dev/null | wc -l | tr -d ' ')
[ "$BOTH" = "2" ] && ok "both colours still deployed ($BOTH) -- rollback needs no rebuild" \
                  || bad "only $BOTH deployment(s) exist; this is a rolling update, not blue/green"

# ── scenario 5: NEGATIVE -- promoting a colour that does not exist ──────────
k delete deploy station2-twin-green --wait=true >/dev/null 2>&1
if "$HERE/promote.sh" green >/dev/null 2>&1; then
  bad "promoted a colour with no deployment"
else
  ok "promotion refused a colour that does not exist"
fi
serves blue-v15 "Service still serving after all refusals"

echo ""
[ "$FAIL" -gt 0 ] && { echo "  $PASS passed, $FAIL FAILED" >&2; exit 1; }
echo "  $PASS passed, 0 failed"

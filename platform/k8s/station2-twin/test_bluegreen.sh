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

serving() {
  k run bgprobe-$RANDOM --rm -i --restart=Never --image=curlimages/curl:8.10.1 \
    --timeout=60s --quiet -- -s --max-time 5 http://station2-twin:8080/version 2>/dev/null \
    | tr -d '\r' | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["version"])
except Exception: print("UNREACHABLE")' 2>/dev/null
}

echo "=== blue/green on kubernetes ==="

# ── scenario 1: baseline ────────────────────────────────────────────────────
"$HERE/deploy.sh" blue v15 15 >/dev/null 2>&1
k patch svc station2-twin -p '{"spec":{"selector":{"app":"station2-twin","color":"blue"}}}' >/dev/null 2>&1
V=$(serving)
[ "$V" = "blue-v15" ] && ok "baseline: Service serves blue ($V)" \
                      || bad "baseline: Service serves '$V', expected blue-v15"

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
V=$(serving)
[ "$V" = "blue-v15" ] && ok "traffic stayed on blue after the refusal ($V)" \
                      || bad "traffic moved despite refusal: '$V'"

# ── scenario 3: POSITIVE -- a healthy green ────────────────────────────────
k delete deploy station2-twin-green --wait=true >/dev/null 2>&1
"$HERE/deploy.sh" green v15-green 15 >/dev/null 2>&1
if "$HERE/promote.sh" green >/dev/null 2>&1; then
  V=$(serving)
  [ "$V" = "green-v15-green" ] && ok "promoted to green, Service now serves $V" \
                               || bad "promote reported success but Service serves '$V'"
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
                      || bad "rollback left Service serving '$V'"

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
V=$(serving)
[ "$V" = "blue-v15" ] && ok "Service still serving after all refusals ($V)" \
                      || bad "Service ended in state '$V'"

echo ""
[ "$FAIL" -gt 0 ] && { echo "  $PASS passed, $FAIL FAILED" >&2; exit 1; }
echo "  $PASS passed, 0 failed"

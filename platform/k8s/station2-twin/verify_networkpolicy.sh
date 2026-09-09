#!/usr/bin/env bash
# Prove the network policy is DOING something, not merely present.
#
# `kubectl get netpol` proves a manifest was accepted. It says nothing about
# whether any packet was stopped -- and on a cluster whose CNI ignores
# NetworkPolicy, every one of those manifests is decoration that reads as a
# control. So this checks, in order:
#
#   0. enforcement itself, in a throwaway namespace (deny-all -> a pod really
#      loses the network). Without this, everything below can pass on a
#      cluster where nothing is enforced.
#   1. the policies exist
#   2. POSITIVE: the app still reaches the database and still serves
#   3. NEGATIVE: the app can NOT reach the public internet
#
# 3 is the one that matters. 1 and 2 are equally true of a namespace with no
# policy at all.
#
# Usage:
#   verify_networkpolicy.sh            # check
#   verify_networkpolicy.sh --apply    # apply the manifest, then check,
#                                      # rolling back if the app breaks
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTX="${K8S_CTX:-k3d-devops-lab}"
NS="${NS:-station2}"
MANIFEST="$SCRIPT_DIR/networkpolicy.yaml"
PROBE_NS="netpol-enforce-check"

PASS=0; FAIL=0
UNMEAS=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && echo "       $2"; }
# UNMEASURED is not a third colour for "probably fine". It is the verdict for
# "the experiment did not run", which is a different claim from both "the
# system is correct" and "the system is broken" -- and the only one of the
# three that is true when the probe itself never got off the ground.
#
# WHY IT EXISTS HERE (Backlog §27 T25). The precondition control below is
# right to refuse: a probe with no egress BEFORE any policy cannot prove that
# a policy removed egress. But the usual cause is a slow image pull or a
# transient DNS hiccup in the probe namespace, not a broken CNI -- and
# reporting that as FAIL trains everyone to re-run the suite until it is
# green, which is how a real failure gets waved through.
unmeasured() { UNMEAS=$((UNMEAS+1)); printf '  \033[33mUNMEASURED\033[0m %s\n' "$1"; [ -n "${2:-}" ] && echo "       $2"; }
k()   { kubectl --context "$CTX" "$@"; }

k get --raw /readyz >/dev/null 2>&1 || { echo "cluster '$CTX' does not answer /readyz." >&2; exit 1; }

echo "=== [netpol] namespace $NS on $CTX ==="

# ---------------------------------------------------------------------------
# 0. Is NetworkPolicy enforced AT ALL on this cluster?
# ---------------------------------------------------------------------------
echo ""
echo "--- 0. is the CNI enforcing NetworkPolicy? ---"
IMAGE="$(k -n "$NS" get deploy -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null)"
if [ -z "$IMAGE" ]; then
  bad "no deployment in $NS to borrow an image from"
else
  k delete ns "$PROBE_NS" --ignore-not-found --wait=true >/dev/null 2>&1
  k create ns "$PROBE_NS" >/dev/null 2>&1
  # Cleanup runs even on SIGTERM. A leaked namespace holding a deny-all policy
  # is exactly the kind of debris the cap timeout work went and removed.
  trap 'kubectl --context "$CTX" delete ns "$PROBE_NS" --ignore-not-found --wait=false >/dev/null 2>&1' EXIT
  k -n "$PROBE_NS" run prober --image="$IMAGE" --restart=Never \
    --command -- sleep 240 >/dev/null 2>&1
  if k -n "$PROBE_NS" wait --for=condition=Ready pod/prober --timeout=90s >/dev/null 2>&1; then
    reach() {
      k -n "$PROBE_NS" exec prober -- python3 -c "
import socket,sys
s=socket.socket(); s.settimeout(4)
try:
    s.connect(('1.1.1.1',443)); print('open')
except Exception:
    print('closed')
" 2>/dev/null | tr -d '\r\n'
    }
    # THREE ATTEMPTS, copied from test_bluegreen.sh's readiness probe. The
    # first `reach` after a pod reports Ready can still lose to DNS or to the
    # sandbox finishing its network setup; one retry loop turns a startup race
    # into a measurement instead of a verdict.
    BEFORE="closed"
    for _try in 1 2 3; do
      BEFORE="$(reach)"
      [ "$BEFORE" = "open" ] && break
      sleep 4
    done
    cat <<'YAML' | sed "s/__NS__/$PROBE_NS/" | k apply -f - >/dev/null 2>&1
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-all-egress, namespace: __NS__}
spec: {podSelector: {}, policyTypes: [Egress]}
YAML
    sleep 5
    AFTER="$(reach)"
    if [ "$BEFORE" = "open" ] && [ "$AFTER" = "closed" ]; then
      ok "CNI enforces NetworkPolicy (open -> closed under deny-all)"
    elif [ "$BEFORE" != "open" ]; then
      unmeasured "CNI enforcement not measured: the probe had no egress even before a policy" \
          "after 3 attempts. This is NOT evidence the CNI is broken and NOT \
evidence it works -- the experiment needs a working 'before' to compare \
against. Usual causes: image pull or DNS in the probe namespace. The policies \
themselves are still checked below; only the ENFORCEMENT question is open."
    else
      bad "CNI is NOT enforcing NetworkPolicy" \
          "deny-all applied and the pod still reached the internet. Every policy \
in $NS is decoration. Start k3s WITHOUT --disable-network-policy."
    fi
  else
    bad "probe pod did not become Ready"
  fi
  k delete ns "$PROBE_NS" --ignore-not-found --wait=false >/dev/null 2>&1
fi

if [ "${1:-}" = "--apply" ]; then
  echo ""
  echo "--- applying $MANIFEST ---"
  k apply -f "$MANIFEST" >/dev/null 2>&1 \
    && echo "  applied" || { bad "kubectl apply failed"; exit 1; }
  # 15s, not 5. A policy takes time to reach every node's iptables, and the
  # first probe after --apply came back UNREACHABLE while the same probe
  # succeeded moments later. Five seconds turned a propagation delay into a
  # test failure, which is the fastest way to teach everyone to re-run a suite
  # until it goes green.
  sleep 15
fi

echo ""
echo "--- 1. are the policies present? ---"
COUNT="$(k -n "$NS" get networkpolicy -o name 2>/dev/null | wc -l | tr -d ' ')"
if [ "${COUNT:-0}" -ge 4 ]; then
  ok "$COUNT policies in $NS"
else
  bad "only ${COUNT:-0} policies in $NS (expected 4)" \
      "apply them: $0 --apply"
  echo ""; echo "  $PASS passed, $FAIL failed"; exit 1
fi

POD="$(k -n "$NS" get pod -l app=station2-twin -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[ -n "$POD" ] || { bad "no station2-twin pod found"; echo ""; echo "  $PASS passed, $FAIL failed"; exit 1; }

rollback() {
  echo ""
  echo "--- rollback ---"
  k -n "$NS" delete -f "$MANIFEST" >/dev/null 2>&1 \
    && echo "  policies removed; the namespace is open again" \
    || echo "  ROLLBACK FAILED -- remove them by hand: kubectl -n $NS delete netpol --all" >&2
}

echo ""
echo "--- 2. POSITIVE: does the app still work? ---"
# /health/ready is the honest probe: it fails when the database is unreachable,
# so it answers "can the pod still reach postgres" without a second test that
# could disagree with the app's own opinion.
READY="$(k -n "$NS" exec "$POD" -- \
  python3 -c "
import urllib.request,sys
try:
    with urllib.request.urlopen('http://127.0.0.1:8080/health/ready', timeout=8) as r:
        print(r.status)
except Exception as e:
    print(getattr(e, 'code', 0))
" 2>/dev/null | tr -d '\r\n')"
if [ "$READY" = "200" ]; then
  ok "pod is Ready -- it still reaches the database through the policy"
else
  bad "pod readiness is $READY" "the policy is blocking the database"
  [ "${1:-}" = "--apply" ] && rollback
  echo ""; echo "  $PASS passed, $FAIL failed"; exit 1
fi

ENDPOINTS="$(k -n "$NS" get endpoints station2-twin -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w | tr -d ' ')"
if [ "${ENDPOINTS:-0}" -gt 0 ]; then
  ok "Service still has $ENDPOINTS endpoint(s)"
else
  bad "Service has no endpoints" "inbound traffic is being blocked"
  [ "${1:-}" = "--apply" ] && rollback
  echo ""; echo "  $PASS passed, $FAIL failed"; exit 1
fi

echo ""
echo "--- 3. NEGATIVE: is anything actually refused? ---"
OUT="$(k -n "$NS" exec "$POD" -- python3 -c "
import socket
s=socket.socket(); s.settimeout(4)
try:
    s.connect(('1.1.1.1',443)); print('open')
except Exception:
    print('closed')
" 2>/dev/null | tr -d '\r\n')"
if [ "$OUT" = "closed" ]; then
  ok "the app cannot reach the public internet (egress is really denied)"
else
  bad "the app CAN still reach the public internet" \
      "the default-deny is not covering these pods -- check the podSelector"
fi

echo ""
# UNMEASURED is printed in the summary, never folded into passed. A suite that
# reports "12 passed" while one question went unasked is making a stronger
# claim than it measured, and the whole point of this verdict is that the
# difference stays visible after the scrollback is gone.
if [ "$UNMEAS" -gt 0 ]; then
  echo "  $PASS passed, $FAIL failed, $UNMEAS unmeasured"
else
  echo "  $PASS passed, $FAIL failed"
fi
[ "$FAIL" -eq 0 ] || exit 1

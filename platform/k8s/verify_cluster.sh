#!/usr/bin/env bash
# Prove the cluster works. Not that it is configured -- that it works.
#
# The old cluster was configured correctly and was unusable: a kubeconfig
# pointing at a dead port, a StorageClass nobody had ever bound a PVC against,
# and no registry at all. Every one of those reads fine in `get` output.
#
# So each check below performs the ACTION rather than inspecting the setting:
# a PVC is actually bound and actually written to, an image is actually pushed
# and actually pulled by a node. A check that only reads configuration would
# have passed on the cluster we deleted.
#
# TWO MODES, BECAUSE THEY ANSWER DIFFERENT QUESTIONS.
#
#   --quick   Is this capability ALIVE?  (~2s, no objects created)
#   (default) Does every feature WORK end-to-end?  (~60-90s, creates and
#             removes a namespace, a PVC and two pods)
#
# The split was forced by a real failure: registering the full suite as the AIS
# capability `verify` command made it a ZOMBIE, because that registry allows 60s
# and the conformance run exceeds it. Raising the registry's timeout would have
# been the wrong fix -- a liveness check that takes 90 seconds is not a liveness
# check.
#
# --quick is NOT a weakened check. Every one of its three assertions performs a
# real API round-trip, and all three are exactly what the deleted cluster failed:
# its API was unreachable, so `kubectl get nodes` would have caught it on any day
# of the 31 hours nobody noticed. What --quick omits is CONFORMANCE (does storage
# provision, does the registry serve nodes) -- questions worth asking after a
# rebuild or in CI, not every time something asks "is it up".
#
# Time-bounded: every object created is removed in a trap, including on failure.
set -uo pipefail

K3D="${K3D:-$HOME/.local/bin/k3d}"
CLUSTER="${CLUSTER:-devops-lab}"
CTX="k3d-$CLUSTER"
REGISTRY_PORT="${REGISTRY_PORT:-5111}"
NS="verify-$$"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; FAIL=$((FAIL+1)); }
k()    { kubectl --context "$CTX" "$@"; }

cleanup() {
  k delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
  docker rmi "localhost:$REGISTRY_PORT/verify-probe:v1" >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

if [ "$QUICK" = "1" ]; then
  echo "=== k8s liveness ($CLUSTER) ==="
else
  echo "=== k8s cluster verification ($CLUSTER) ==="
fi

# ── 1. reachable ────────────────────────────────────────────────────────────
# The old cluster failed HERE and nobody noticed for weeks, because nothing
# ever asked.
if k version -o json >/dev/null 2>&1; then
  ok "API server reachable at $(kubectl config view -o jsonpath="{.clusters[?(@.name=='$CTX')].cluster.server}")"
else
  bad "API server unreachable" "the kubeconfig context $CTX does not resolve"
  echo ""; echo "  $PASS passed, $FAIL failed"; exit 1
fi

READY=$(k get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
TOTAL=$(k get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
[ "$READY" = "$TOTAL" ] && [ "$TOTAL" -ge 3 ] \
  && ok "$READY/$TOTAL nodes Ready" \
  || bad "$READY/$TOTAL nodes Ready" "expected at least 3, all Ready"

# ── 2. agent memory ─────────────────────────────────────────────────────────
# The specific defect that made the old cluster useless: agents capped at
# 1.465 GB, sitting at 78-95% while completely idle, so a 1 GB Spark executor
# could never be scheduled. Asserted in bytes, not eyeballed.
MIN_KI=2500000
SMALL=$(k get nodes --no-headers -o custom-columns=N:.metadata.name,M:.status.capacity.memory 2>/dev/null \
        | awk -v min="$MIN_KI" '$1 ~ /agent/ { gsub(/Ki$/,"",$2); if ($2+0 < min) print $1"="$2"Ki" }')
[ -z "$SMALL" ] \
  && ok "every agent has >= $((MIN_KI/1024/1024)) GiB (a Spark executor fits)" \
  || bad "agent memory too small: $SMALL" "this is what made the previous cluster unusable"

if [ "$QUICK" = "1" ]; then
  echo ""
  [ "$FAIL" -gt 0 ] && { echo "  $PASS passed, $FAIL FAILED" >&2; exit 1; }
  echo "  $PASS passed, 0 failed (liveness only -- run without --quick for conformance)"
  exit 0
fi

# ── 3. StorageClass ACTUALLY BINDS ──────────────────────────────────────────
# `get storageclass` proves a name exists. Binding a PVC and writing a byte
# through it proves the provisioner runs.
k create ns "$NS" >/dev/null 2>&1
cat <<YAML | k apply -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: probe, namespace: $NS }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 64Mi } }
---
apiVersion: v1
kind: Pod
metadata: { name: probe, namespace: $NS }
spec:
  restartPolicy: Never
  containers:
    - name: w
      image: busybox:1.36
      command: ["sh","-c","echo written-by-verify > /data/probe.txt && cat /data/probe.txt"]
      volumeMounts: [{ name: v, mountPath: /data }]
  volumes:
    - name: v
      persistentVolumeClaim: { claimName: probe }
YAML

if k wait --for=condition=Ready pod/probe -n "$NS" --timeout=90s >/dev/null 2>&1 \
   || k wait --for=jsonpath='{.status.phase}'=Succeeded pod/probe -n "$NS" --timeout=90s >/dev/null 2>&1; then
  OUT=$(k logs pod/probe -n "$NS" 2>/dev/null | tr -d '[:space:]')
  PHASE=$(k get pvc probe -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$PHASE" = "Bound" ] && ok "PVC Bound (provisioner: $(k get sc -o jsonpath='{.items[0].provisioner}' 2>/dev/null))" \
                         || bad "PVC phase=$PHASE" "the StorageClass exists but does not provision"
  [ "$OUT" = "written-by-verify" ] && ok "wrote and read back through the volume" \
                                   || bad "volume write/read returned '$OUT'"
else
  bad "probe pod never became Ready/Succeeded" "$(k get pod probe -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].message}' 2>/dev/null)"
fi

# ── 4. REGISTRY ACTUALLY SERVES THE CLUSTER ─────────────────────────────────
# Push from the host, pull from a node. Checking only that the registry
# container is up would pass even when containerd has no mirror configured --
# which is the failure that makes exactly one node unable to pull.
if curl -sf --max-time 5 "http://localhost:$REGISTRY_PORT/v2/" >/dev/null 2>&1; then
  ok "registry answers /v2/ on :$REGISTRY_PORT"
  docker pull -q busybox:1.36 >/dev/null 2>&1
  docker tag busybox:1.36 "localhost:$REGISTRY_PORT/verify-probe:v1" >/dev/null 2>&1
  if docker push -q "localhost:$REGISTRY_PORT/verify-probe:v1" >/dev/null 2>&1; then
    ok "pushed an image to the registry from the host"
    cat <<YAML | k apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata: { name: pullprobe, namespace: $NS }
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: k3d-registry:$REGISTRY_PORT/verify-probe:v1
      command: ["sh","-c","echo pulled-from-registry"]
YAML
    if k wait --for=jsonpath='{.status.phase}'=Succeeded pod/pullprobe -n "$NS" --timeout=90s >/dev/null 2>&1; then
      ok "a NODE pulled that image by name (containerd mirror works)"
    else
      bad "node could not pull from the registry" \
          "$(k get pod pullprobe -n "$NS" -o jsonpath='{.status.containerStatuses[0].state.waiting.message}' 2>/dev/null)"
    fi
  else
    bad "docker push to localhost:$REGISTRY_PORT failed"
  fi
else
  bad "registry not answering on :$REGISTRY_PORT"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then echo "  $PASS passed, $FAIL FAILED" >&2; exit 1; fi
echo "  $PASS passed, 0 failed"

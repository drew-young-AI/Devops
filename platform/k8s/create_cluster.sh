#!/usr/bin/env bash
# Rebuild the k3d practice cluster, with the two things the old one lacked.
#
# WHY THE OLD CLUSTER WAS DELETED RATHER THAN RESIZED (2026-08-19).
#
# It had become a zombie: the k3d CLI was not installed, the API server had no
# published port and was unreachable, the kubeconfig pointed at a dead address,
# and it held 4.4 GB while running nothing for 31 hours. A cluster nobody can
# reach is not a cluster; it is a memory reservation with a name.
#
# WHAT THIS ONE FIXES.
#
#   1. AGENT MEMORY. The old agents were capped at 1.465 GB and sat at 78-95%
#      while IDLE. A Spark executor asks for ~1 GB, so the cluster physically
#      could not host the workload it existed to practise. Agents get 3 GB here.
#
#   2. A REGISTRY. There was none, so every image had to be side-loaded with
#      `k3d image import` -- which works and teaches nothing, because no real
#      cluster pulls that way. A local registry makes the image path the same
#      shape as production: build, push, reference by name.
#
# NOT SET UP HERE, ON PURPOSE: any workload. This script produces an empty,
# reachable cluster with working storage and a working registry, and stops.
# Deploying the pilot onto it is a separate step with its own verification --
# bundling them would make a failure ambiguous between substrate and workload.
set -euo pipefail

K3D="${K3D:-$HOME/.local/bin/k3d}"
CLUSTER="${CLUSTER:-devops-lab}"
REGISTRY="${REGISTRY:-k3d-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5111}"
AGENTS="${AGENTS:-2}"
SERVER_MEM="${SERVER_MEM:-2500m}"
AGENT_MEM="${AGENT_MEM:-3g}"
API_PORT="${API_PORT:-6551}"

command -v "$K3D" >/dev/null 2>&1 || { echo "k3d not found at $K3D" >&2; exit 1; }

echo "=== [k8s] rebuilding $CLUSTER ==="
"$K3D" version | head -2

if "$K3D" cluster list -o json 2>/dev/null | grep -q "\"$CLUSTER\""; then
  echo "  cluster $CLUSTER already exists -- delete it first if you mean to rebuild:"
  echo "    $K3D cluster delete $CLUSTER"
  exit 2
fi

# Registry first: the cluster is created with it already wired in, so no node
# ever starts with a containerd config that lacks the mirror. Adding a registry
# to a running cluster leaves existing nodes unable to pull from it, which shows
# up much later as one node failing image pulls the others succeed at.
if ! "$K3D" registry list 2>/dev/null | grep -q "$REGISTRY"; then
  echo ""
  echo "--- creating registry $REGISTRY on :$REGISTRY_PORT"
  "$K3D" registry create "${REGISTRY#k3d-}" --port "$REGISTRY_PORT"
fi

echo ""
echo "--- creating cluster: 1 server + $AGENTS agents"
# --api-port is EXPLICIT. The old cluster's API server had no published port,
# which is the single reason it became unreachable and then invisible.
"$K3D" cluster create "$CLUSTER" \
  --agents "$AGENTS" \
  --api-port "127.0.0.1:$API_PORT" \
  --servers-memory "$SERVER_MEM" \
  --agents-memory "$AGENT_MEM" \
  --registry-use "${REGISTRY}:${REGISTRY_PORT}" \
  --k3s-arg '--disable=traefik@server:*' \
  --wait

echo ""
echo "--- nodes"
kubectl --context "k3d-$CLUSTER" get nodes -o wide

echo ""
echo "=== done. Verify with: platform/k8s/verify_cluster.sh ==="

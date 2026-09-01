#!/usr/bin/env bash
# Bring up the production-like k3s cluster on the Ubuntu box, from the Mac.
#
# WHY k3s AND NOT MORE k3d.
#
# k3d runs Kubernetes nodes as Docker containers on a machine whose Docker
# daemon is itself a VM. Three layers of indirection sit between a pod and the
# kernel that schedules it, and every one of them is a difference from anything
# that would run for real. k3s here is a systemd service on bare metal: the
# kubelet talks to the host kernel, cgroup v2 limits are the host's, a reboot
# is a real reboot, and `systemctl stop k3s` is a real outage. Those are the
# behaviours the platform claims to handle and has never once been able to test.
#
# WHY ONE NODE AND NOT server+agent.
#
# There is one physical machine. A second "node" would be a second k3s process
# on the same kernel, sharing the same 7 GiB and the same disk -- it would not
# test scheduling across failure domains, because there is only one failure
# domain. It would only add a control-plane's worth of overhead and a way for
# the pilot to land somewhere surprising. The honest cost is stated in
# TRIAL.md: node-drain, pod anti-affinity across nodes, and node-failure
# eviction CANNOT be exercised here, and must not be claimed as tested.
#
# WHY TRAEFIK IS DISABLED.
#
# The k3d cluster has no ingress controller either. Keeping the two substrates
# identical except for the one variable under test (containers-in-a-VM vs
# systemd on metal) is what makes a difference in behaviour attributable.
# Ingress is a deliberate later step with its own verification, not a thing
# that arrives by default and is therefore never examined.
#
# NOT DONE HERE, ON PURPOSE: no workload, no registry, no image. This script
# produces an empty reachable cluster and stops. Bundling the pilot in would
# make any failure ambiguous between substrate and workload.
set -euo pipefail

HOST="${HOST:-ubu}"                     # ssh alias; see ~/.ssh/config
NODE_NAME="${NODE_NAME:-ubu}"
TLS_SAN="${TLS_SAN:-ubu.local}"
CONTEXT="${CONTEXT:-ubu}"
KUBECONFIG_OUT="${KUBECONFIG_OUT:-$HOME/.kube/config}"

# The sudo password is read from ~/.env into the environment and piped to
# `sudo -S` on stdin. It is never an argv element (ps is world-readable) and
# never written to a file. Passwordless sudo is deliberately NOT configured:
# loosening the box's auth posture is a bigger change than this task needs.
ENV_FILE="${ENV_FILE:-$HOME/.env}"
UBU_PASSWORD="$(grep -m1 '^UBU_PASSWORD=' "$ENV_FILE" | cut -d= -f2- | sed 's/^"//; s/"$//')"
[ -n "$UBU_PASSWORD" ] || { echo "UBU_PASSWORD not found in $ENV_FILE" >&2; exit 1; }

rsudo() {  # run one command under sudo on the remote host
  ssh "$HOST" "sudo -S -p '' $*" <<< "$UBU_PASSWORD"
}

echo "=== [k3s] bootstrapping $HOST ==="
ssh "$HOST" '. /etc/os-release; echo "  $PRETTY_NAME  $(uname -m)  $(nproc) cpu  $(free -g | awk "/Mem:/{print \$2}")GiB"'

if ssh "$HOST" 'systemctl is-active --quiet k3s' 2>/dev/null; then
  echo "  k3s already active -- this script is idempotent, re-checking only"
else
  echo ""
  echo "--- installing k3s (server, single node)"
  # --write-kubeconfig-mode 644: drew must read the kubeconfig without sudo,
  #   otherwise every later step needs a password and stops being automatable.
  # --tls-san: the Mac reaches this box by hostname, not by the IP baked into
  #   the default cert. Without it every kubectl call fails cert validation,
  #   and the usual "fix" is --insecure-skip-tls-verify, which turns a
  #   one-line config problem into a permanent security hole.
  ssh "$HOST" "sudo -S -p '' sh -c '
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_EXEC=\"server --disable traefik --node-name $NODE_NAME --tls-san $TLS_SAN --write-kubeconfig-mode 644\" \
      sh -
  '" <<< "$UBU_PASSWORD"
fi

echo ""
echo "--- waiting for node Ready"
for i in $(seq 1 30); do
  if ssh "$HOST" 'k3s kubectl get node --no-headers 2>/dev/null' | grep -q ' Ready '; then break; fi
  sleep 2
done
ssh "$HOST" 'k3s kubectl get node -o wide --no-headers'

echo ""
echo "--- merging kubeconfig into $KUBECONFIG_OUT as context '$CONTEXT'"
tmp="$(mktemp)"; trap 'rm -f "$tmp" "$tmp.merged"' EXIT
ssh "$HOST" 'cat /etc/rancher/k3s/k3s.yaml' \
  | sed "s#https://127.0.0.1:6443#https://${TLS_SAN}:6443#; s#^\( *-\{0,1\} *\)name: default\$#\1name: ${CONTEXT}#; s#cluster: default#cluster: ${CONTEXT}#; s#user: default#user: ${CONTEXT}#; s#current-context: default#current-context: ${CONTEXT}#" \
  > "$tmp"
mkdir -p "$(dirname "$KUBECONFIG_OUT")"
[ -f "$KUBECONFIG_OUT" ] && cp "$KUBECONFIG_OUT" "$KUBECONFIG_OUT.bak.$(date +%s)"
KUBECONFIG="$KUBECONFIG_OUT:$tmp" kubectl config view --flatten > "$tmp.merged"
mv "$tmp.merged" "$KUBECONFIG_OUT"
chmod 600 "$KUBECONFIG_OUT"

echo ""
echo "--- verifying FROM THE MAC (this is the check that matters)"
# Verifying by ssh-ing in and looking would prove only that the box can see
# itself. Every later step drives this cluster from the Mac, so the reachable
# path is the one that has to be green.
kubectl --context "$CONTEXT" get nodes -o wide
kubectl --context "$CONTEXT" get ns

echo ""
echo "=== [k3s] OK -- context '$CONTEXT' reachable from the Mac ==="

#!/usr/bin/env bash
# Every image a cluster is told to run must contain a build for that cluster's
# CPU architecture.
#
# WHY THIS SUITE EXISTS (2026-08-31).
#
# The platform gained a second cluster on a second machine, and the two
# machines do not share an instruction set: the Mac is arm64, the Ubuntu box
# is amd64. Every image built so far was built on the Mac and is arm64-only.
#
# The failure mode is silent at every step that a human watches:
#
#   docker save        -> succeeds
#   ctr images import  -> "saved", exit 0
#   ctr images ls      -> the image is listed, with a size
#   kubectl apply      -> accepted, Deployment created
#   ...only the kubelet finally says ErrImageNeverPull, and containerd's real
#   reason -- "no match for platform in manifest" -- is buried in a log line
#   nobody reads.
#
# That is this platform's oldest defect wearing new clothes: a thing that
# REGISTERS as present but cannot EXECUTE. `promtool check rules` reported
# SUCCESS on a rule that failed every evaluation cycle (ADR-0007); `tofu
# apply` reports "10 resources created" while creating nothing. Same shape.
#
# WHY ONLY OUR OWN IMAGES ARE CHECKED.
#
# Vendor images pulled from Docker Hub (rancher/*, postgres, busybox) publish
# multi-arch manifest lists as a matter of course, and checking them would mean
# authenticating to Docker Hub from CI for no observed risk. The images that
# have actually broken are the ones WE build, because our build host has one
# architecture and our clusters now have two. Those are checked.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="image-arch"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== images must carry a build for the architecture they are deployed to =="

# Registry hostnames as a cluster resolves them, mapped to how THIS machine
# reaches the same registry. Written once here rather than at each call site:
# a second copy is how the two drift.
registry_addr() {  # <image-ref> -> host:port reachable from this machine, or ""
  case "$1" in
    k3d-registry:5111/*) echo "127.0.0.1:5111" ;;
    ubu-registry:5111/*) echo "ubu.local:5111" ;;
    *) echo "" ;;               # vendor image; see header
  esac
}

# Returns one "os/arch" per line for an image reference, by asking the registry
# for the manifest rather than by trusting a local `docker inspect` -- the
# question is what the CLUSTER will find, and the cluster asks the registry.
image_platforms() {  # <image-ref>
  local ref="$1" addr repo tag body
  addr="$(registry_addr "$ref")"
  [ -n "$addr" ] || return 2
  repo="${ref#*/}"; tag="${repo##*:}"; repo="${repo%:*}"
  body="$(curl -s -m 8 "http://${addr}/v2/${repo}/manifests/${tag}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' 2>/dev/null)"
  [ -n "$body" ] || return 3
  printf '%s' "$body" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(4)
ms = d.get("manifests")
if ms is None:                       # single manifest, not an index
    print("single/unknown"); sys.exit(0)
for m in ms:
    p = m.get("platform", {})
    os_, arch = p.get("os", "?"), p.get("architecture", "?")
    if (os_, arch) == ("unknown", "unknown"):
        continue                     # buildx attestation, not a runnable image
    print(f"{os_}/{arch}")
'
}

# ---- 1. every reachable cluster runs images built for its own arch ---------
#
# A context with no own-built images reports VACUOUS, not PASS. An empty set
# satisfies "every image matches" trivially, and a green line that means
# "nothing was examined" is the failure this whole suite exists to prevent --
# it is the same shape as a dashboard watching a service that no longer runs.
for ctx in $(kubectl config get-contexts -o name 2>/dev/null); do
  kubectl --context "$ctx" --request-timeout=8s get nodes >/dev/null 2>&1 || {
    echo "  SKIP  context $ctx unreachable -- its images are UNVERIFIED"
    continue
  }
  node_arch="$(kubectl --context "$ctx" get nodes \
    -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null)"
  node_os="$(kubectl --context "$ctx" get nodes \
    -o jsonpath='{.items[0].status.nodeInfo.operatingSystem}' 2>/dev/null)"
  BAD=""; SEEN=0
  while read -r img; do
    [ -n "$img" ] || continue
    [ -n "$(registry_addr "$img")" ] || continue        # vendor image
    SEEN=$((SEEN + 1))
    plats="$(image_platforms "$img")" || { BAD="$BAD $img(unreadable)"; continue; }
    printf '%s\n' "$plats" | grep -qx "${node_os}/${node_arch}" \
      || BAD="$BAD $img(has:$(echo "$plats" | tr '\n' ',' | sed 's/,$//') want:${node_os}/${node_arch})"
  done < <(kubectl --context "$ctx" get deploy -A \
             -o jsonpath='{range .items[*]}{.spec.template.spec.containers[*].image}{"\n"}{end}' \
             2>/dev/null | tr ' ' '\n' | sort -u)
  if [ "$SEEN" -eq 0 ]; then
    echo "  VACUOUS  context $ctx (${node_os}/${node_arch}): no own-built image deployed -- nothing verified here"
  elif [ -z "$BAD" ]; then
    _pass "context $ctx (${node_os}/${node_arch}): all $SEEN own-built image(s) match the node arch"
  else
    _fail "context $ctx (${node_os}/${node_arch}): all $SEEN own-built image(s) match the node arch" \
          "mismatch:$BAD -- the pod will fail with ErrImageNeverPull / no match for platform"
  fi
done

# ---- the decision rule, isolated so it can be controlled ------------------
#
# The controls below feed SYNTHETIC platform lists rather than whatever the
# registry happens to hold today. Otherwise the negative control stops being a
# control the moment the multi-arch build lands: it would start passing for the
# wrong reason, and nobody would notice the suite had gone blind.
arch_supported() {  # <newline-separated platforms> <wanted os/arch>
  printf '%s\n' "$1" | grep -qx "$2"
}

if arch_supported "linux/arm64" "linux/amd64"; then
  _fail "catches: an arm64-only image offered to an amd64 node" "accepted it"
else
  _pass "catches: an arm64-only image offered to an amd64 node"
fi

if arch_supported "linux/arm64
linux/amd64" "linux/amd64"; then
  _pass "accepts: a multi-arch image offered to an amd64 node"
else
  _fail "accepts: a multi-arch image offered to an amd64 node" "rejected it"
fi

# Positive control on the rule itself: without this, a rule that rejected
# everything would satisfy the negative control above and look correct.
if arch_supported "linux/arm64" "linux/arm64"; then
  _pass "does not cry wolf: an arm64 image offered to an arm64 node"
else
  _fail "does not cry wolf: an arm64 image offered to an arm64 node" "rejected it"
fi

# ---- what the live registry actually holds, for the record ----------------
PROBE="k3d-registry:5111/station2-twin:v15"
if PLATS="$(image_platforms "$PROBE" 2>/dev/null)" && [ -n "$PLATS" ]; then
  echo "  INFO  $PROBE platforms: $(printf '%s' "$PLATS" | tr '\n' ',' | sed 's/,$//')"
else
  echo "  SKIP  local registry unreachable -- live platform list is UNVERIFIED"
fi

suite_summary

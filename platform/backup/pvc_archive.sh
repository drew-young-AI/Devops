#!/usr/bin/env bash
# Archive one Kubernetes PVC to a local file. Called by backup.sh.
#
# WHY A PVC CANNOT BE BACKED UP AS A DOCKER VOLUME.
#
# k3d writes PVC data through local-path-provisioner into the NODE's
# /var/lib/rancher/k3s/storage, and that path is backed by an ANONYMOUS docker
# volume (64-hex name). backup.sh's coverage gate classifies 64-hex volumes as
# "docker's own scratch, not state anybody chose to keep" -- so a database moved
# into the cluster would land in a volume the backup explicitly treats as
# disposable, and the run would still report PASS. Silently.
#
# Tarring that whole node volume is the wrong fix twice over: it mixes cluster
# state (rebuildable by create_cluster.sh) with irreplaceable PVC data, and it
# produces one opaque archive nobody can restore a single claim from. So the
# unit here is the PVC, one archive each.
#
# NODE AFFINITY IS NOT OPTIONAL.
#
# local-path volumes are ReadWriteOnce AND physically on one node's disk. A
# backup pod scheduled anywhere else does not get an empty volume -- it gets
# stuck Pending, or worse, provisions a NEW empty directory and tars nothing.
# An empty archive with a valid digest is the worst possible backup: it passes
# every integrity check a restore can make. The node is read off the PV and
# pinned.
#
# Usage:
#   pvc_archive.sh <namespace> <pvc> <out-file>
#
# Exit: 0 archive written, 1 could not archive (nothing partial is left behind)
set -uo pipefail

CTX="${K8S_CTX:-k3d-devops-lab}"
NS="${1:?usage: pvc_archive.sh <namespace> <pvc> <out-file>}"
PVC="${2:?usage: pvc_archive.sh <namespace> <pvc> <out-file>}"
OUT="${3:?usage: pvc_archive.sh <namespace> <pvc> <out-file>}"
IMAGE="${PVC_ARCHIVE_IMAGE:-alpine:3.20}"
POD="pvcbackup-$(echo "$PVC" | tr -cd 'a-z0-9-' | cut -c1-30)-$$"

k() { kubectl --context "$CTX" "$@"; }

die() { echo "  $*" >&2; rm -f "$OUT"; exit 1; }

PV="$(k -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.volumeName}' 2>/dev/null)"
[ -n "$PV" ] || die "PVC $NS/$PVC has no bound PV (is it still Pending?)"

# The node the data physically lives on. local-path records it in the PV's
# nodeAffinity; if it is absent the volume is not node-local and any node will
# do, so an empty NODE is not an error.
NODE="$(k get pv "$PV" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}' 2>/dev/null)"

SELECTOR=""
[ -n "$NODE" ] && SELECTOR=", \"nodeName\": \"$NODE\""

cleanup() { kubectl --context "$CTX" -n "$NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1; }
trap cleanup EXIT

# readOnly on the mount: a backup process must not be able to modify what it is
# backing up. Same rule the docker-volume path already follows with :ro.
cat <<JSON | k -n "$NS" apply -f - >/dev/null 2>&1 || die "could not create the backup pod"
{
  "apiVersion": "v1", "kind": "Pod",
  "metadata": {"name": "$POD", "labels": {"app": "pvc-backup"}},
  "spec": {
    "restartPolicy": "Never"$SELECTOR,
    "containers": [{
      "name": "tar", "image": "$IMAGE",
      "command": ["sh", "-c", "sleep 600"],
      "volumeMounts": [{"name": "data", "mountPath": "/src", "readOnly": true}]
    }],
    "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "$PVC", "readOnly": true}}]
  }
}
JSON

k -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=120s >/dev/null 2>&1 \
  || die "backup pod for $NS/$PVC never became Ready (node=$NODE)"

# tar to stdout, straight into the archive. No staging copy inside the pod:
# the node's disk is the same disk the PVC is on, and filling it during a
# backup would be a self-inflicted outage.
if ! k -n "$NS" exec "$POD" -- tar czf - -C /src . > "$OUT" 2>/dev/null; then
  die "tar failed for $NS/$PVC"
fi

# An empty tar.gz is ~20 bytes and passes every digest check a restore makes.
# It is the exact failure a mis-scheduled pod produces, so it is refused here
# rather than discovered during a restore.
SIZE="$(wc -c < "$OUT" | tr -d ' ')"
[ "${SIZE:-0}" -gt 100 ] || die "archive for $NS/$PVC is ${SIZE} bytes -- refusing to record an empty backup"

echo "$SIZE"

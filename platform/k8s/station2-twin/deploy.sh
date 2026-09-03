#!/usr/bin/env bash
# Deploy one colour. Does NOT switch traffic -- that is promote.sh.
#
# Separating them is the point. A deploy that also promotes gives you no moment
# to inspect the new version while it is running and reachable but not yet
# serving. That moment is the only difference between blue/green and a rolling
# update.
#
#   deploy.sh green v15-green [schema_version]
set -euo pipefail
COLOR="${1:?usage: deploy.sh <blue|green> <image-tag> [schema_version]}"
TAG="${2:?image tag required}"
SCHEMA="${3:-15}"
CTX="${CTX:-k3d-devops-lab}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$COLOR" in blue|green) ;; *) echo "colour must be blue or green" >&2; exit 2 ;; esac

# ── which registry, and pinned how ──────────────────────────────────────────
#
# Two clusters, two instruction sets, two image paths (ADR-0008). The template
# used to hardcode the k3d registry, which made every other cluster
# undeployable by construction.
#
# ADR-0008's second rule is "deploy pins a DIGEST, not a tag: a tag can point
# at the wrong architecture, a digest fails at deploy time". Until now that
# rule lived only in a document. It is enforced here, and only for the clusters
# it protects:
#
#   the local k3d lab   keeps its tag. There is exactly one architecture on
#                       this machine, the registry is on the same host, and a
#                       tag is what the blue/green flow rewrites on every
#                       deploy. A digest would buy nothing and cost the ability
#                       to redeploy the same colour under a new build.
#   anything else       must be a digest. That is where the two architectures
#                       actually meet, and where a tag resolving to the wrong
#                       one is silent until the kubelet gives up.
#
# The digest comes from .github/workflows/pilot-image.yml, which builds each
# architecture on a native runner and prints the manifest-list digest to pin.
if [ "$CTX" = "k3d-devops-lab" ]; then
  IMAGE="${IMAGE:-k3d-registry:5111/station2-twin:$TAG}"
else
  IMAGE="${IMAGE:-}"
  if [ -z "$IMAGE" ]; then
    echo "context '$CTX' is not the local lab: set IMAGE to a digest-pinned" >&2
    echo "reference, e.g. IMAGE=ghcr.io/drew-young-ai/station2-twin@sha256:..." >&2
    exit 2
  fi
  case "$IMAGE" in
    *@sha256:*) ;;
    *) echo "refusing to deploy '$IMAGE' to context '$CTX': it is a tag." >&2
       echo "A tag can resolve to the wrong architecture and the failure is" >&2
       echo "silent until the kubelet gives up (ADR-0008). Pin the digest." >&2
       exit 2 ;;
  esac
fi

kubectl --context "$CTX" apply -f "$HERE/base.yaml" >/dev/null

# The Deployment mounts VAULT_ROLE_ID / VAULT_SECRET_ID from a Secret and
# carries no database password. Syncing it here rather than as a separate
# manual step is deliberate: a pod whose Secret is missing fails readiness with
# "no AppRole configured", which reads like an application bug and is actually
# a missing prerequisite. Making the deploy own its prerequisite removes that
# whole category of misdiagnosis.
"$HERE/sync_vault_secret.sh" --context "$CTX"

# BOTH __IMAGE__ and __IMAGE_TAG__. The template uses the first for the image
# reference and the second inside APP_VERSION, which is the string the app
# serves at /version and therefore the string blue/green reads to decide which
# colour is live. Dropping the __IMAGE_TAG__ substitution when __IMAGE__ was
# introduced left every pod reporting `blue-__IMAGE_TAG__`, and the suite
# caught it on the next run because that value is load-bearing rather than
# decorative.
#
# `|` as the delimiter for __IMAGE__: a digest reference contains slashes.
sed -e "s/__COLOR__/$COLOR/g" \
    -e "s|__IMAGE__|$IMAGE|g" \
    -e "s/__IMAGE_TAG__/$TAG/g" \
    -e "s/__SCHEMA__/$SCHEMA/g" \
    "$HERE/deployment-template.yaml" | kubectl --context "$CTX" apply -f - >/dev/null

echo "=== deployed $COLOR (image $IMAGE, expects schema $SCHEMA) ==="
# --timeout is deliberately short. A colour that cannot become Ready in 90s is
# not "still starting", it is broken, and the whole value of this step is
# finding that out BEFORE any traffic is at stake.
if kubectl --context "$CTX" -n station2 rollout status "deploy/station2-twin-$COLOR" --timeout=90s 2>&1 | tail -1; then
  echo "  $COLOR is Ready and eligible for promotion"
  HEALTH=healthy
else
  echo "  $COLOR did NOT become Ready -- promotion will refuse it" >&2
  HEALTH=unhealthy
fi
kubectl --context "$CTX" -n station2 get pods -l "color=$COLOR" \
  -o custom-columns=POD:.metadata.name,READY:.status.containerStatuses[0].ready,STATUS:.status.phase --no-headers

# ── the deploy evidence contract ────────────────────────────────────────────
#
# WHY THIS IS HERE AND NOT A NEW FORMAT.
#
# docs/Value-Stream-Board.html reads evidence/<pilot>/deploy_develop_<sha>.json
# to decide whether anything has shipped. That contract was written only by
# platform/compose/deploy.sh, and the pilot's deploy path moved to Kubernetes
# (ADR-0010) without bringing it along -- so from 2026-09-02 the board showed
# 25 items stuck at "committed", 0 deploys, lead time "no data". Read
# literally, it said this platform had never shipped anything.
#
# That is the EMPTY-SET failure with its sign flipped: not a green light
# inferred from nothing, but a RED one -- and the red version is more
# convincing, because an empty pipeline and a blocked pipeline look identical.
#
# Same filename, same fields, on purpose. A Kubernetes-shaped variant would
# leave the board reading two contracts, and two contracts is two indexes --
# 「兩份索引是分岔問題」.
#
# `compose_project` keeps its name despite there being no compose project here.
# The key is the contract; renaming it would fork the schema for cosmetics, so
# it carries the Kubernetes workload identity instead, and `runtime` says which
# world the record came from for anyone reading the file directly.
SHA="$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
IMAGE_DIGEST="$(kubectl --context "$CTX" -n station2 get "deploy/station2-twin-$COLOR" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
EVIDENCE_DIR="$(cd "$HERE/../../.." && pwd)/evidence/station2-twin"
mkdir -p "$EVIDENCE_DIR"
EVIDENCE_FILE="$EVIDENCE_DIR/deploy_develop_${SHA}.json"

python3 - "$EVIDENCE_FILE" "$COLOR" "$SHA" "$IMAGE_DIGEST" "$HEALTH" "$CTX" "$TAG" <<'PY'
import json, pathlib, sys
from datetime import datetime, timezone
out, color, sha, image, health, ctx, tag = sys.argv[1:]
pathlib.Path(out).write_text(json.dumps({
    "environment": "develop",
    "compose_project": f"station2/station2-twin-{color}",
    "commit_sha": sha,
    "image_id": image or None,
    "image_digest": image or None,
    "deployed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "health_status": health,
    "env_file": None,
    # Not part of the contract the board reads -- added so a human opening the
    # file can tell a Kubernetes record from a compose one without inferring it
    # from the shape of compose_project.
    "runtime": "kubernetes",
    "kube_context": ctx,
    "color": color,
    "image_tag": tag,
}, indent=2) + "\n")
PY
echo "  wrote deploy evidence: evidence/station2-twin/deploy_develop_${SHA}.json ($HEALTH)"

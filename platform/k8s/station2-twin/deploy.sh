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

kubectl --context "$CTX" apply -f "$HERE/base.yaml" >/dev/null

# The Deployment mounts VAULT_ROLE_ID / VAULT_SECRET_ID from a Secret and
# carries no database password. Syncing it here rather than as a separate
# manual step is deliberate: a pod whose Secret is missing fails readiness with
# "no AppRole configured", which reads like an application bug and is actually
# a missing prerequisite. Making the deploy own its prerequisite removes that
# whole category of misdiagnosis.
"$HERE/sync_vault_secret.sh" --context "$CTX"

sed -e "s/__COLOR__/$COLOR/g" -e "s/__IMAGE_TAG__/$TAG/g" -e "s/__SCHEMA__/$SCHEMA/g" \
    "$HERE/deployment-template.yaml" | kubectl --context "$CTX" apply -f - >/dev/null

echo "=== deployed $COLOR (image $TAG, expects schema $SCHEMA) ==="
# --timeout is deliberately short. A colour that cannot become Ready in 90s is
# not "still starting", it is broken, and the whole value of this step is
# finding that out BEFORE any traffic is at stake.
if kubectl --context "$CTX" -n station2 rollout status "deploy/station2-twin-$COLOR" --timeout=90s 2>&1 | tail -1; then
  echo "  $COLOR is Ready and eligible for promotion"
else
  echo "  $COLOR did NOT become Ready -- promotion will refuse it" >&2
fi
kubectl --context "$CTX" -n station2 get pods -l "color=$COLOR" \
  -o custom-columns=POD:.metadata.name,READY:.status.containerStatuses[0].ready,STATUS:.status.phase --no-headers

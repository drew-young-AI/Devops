#!/usr/bin/env bash
# Switch traffic to a colour -- but only if that colour is actually serving.
#
# THE GATE IS THE WHOLE POINT.
#
# Promotion is a one-line Service patch. What makes it a deploy strategy rather
# than a foot-gun is everything checked BEFORE that line:
#
#   1. the Deployment exists
#   2. every replica reports Ready (readiness = schema matches AND db reachable)
#   3. the pods answer /health/ready with status "ready" RIGHT NOW, queried
#      directly -- not trusted from the Deployment's cached status
#   4. the schema version they report matches the database's actual version
#
# Check 3 exists because Deployment status is a cache. A pod that passed
# readiness a minute ago and has since lost its database still shows Ready in
# `rollout status` for up to failureThreshold*periodSeconds. Promoting on cached
# health is how a green that is already broken gets traffic.
#
# Check 4 exists because "ready" only proves the pod agrees with ITSELF. If green
# expects schema 16 and the database is at 15, green refuses readiness and never
# gets here -- but the reverse (green expects 15, database migrated to 16 since)
# is caught only by asking both.
set -euo pipefail
COLOR="${1:?usage: promote.sh <blue|green>}"
CTX="${CTX:-k3d-devops-lab}"
NS=station2
k() { kubectl --context "$CTX" -n "$NS" "$@"; }

case "$COLOR" in blue|green) ;; *) echo "colour must be blue or green" >&2; exit 2 ;; esac

CURRENT=$(k get svc station2-twin -o jsonpath='{.spec.selector.color}' 2>/dev/null || echo none)
echo "=== promote: $CURRENT -> $COLOR ==="

fail() { echo "  REFUSED: $1" >&2; echo "" >&2; echo "  Traffic stays on '$CURRENT'." >&2; exit 1; }

# 1. exists
k get "deploy/station2-twin-$COLOR" >/dev/null 2>&1 || fail "no deployment for colour '$COLOR'"

# 2. every replica Ready
DESIRED=$(k get "deploy/station2-twin-$COLOR" -o jsonpath='{.spec.replicas}')
READY=$(k get "deploy/station2-twin-$COLOR" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
READY=${READY:-0}
[ "$READY" = "$DESIRED" ] || fail "$READY/$DESIRED replicas Ready. A colour that is not serving cannot be promoted."

# readyReplicas ALONE IS NOT ENOUGH, and this test found out the hard way.
#
# During a stuck rollout the old ReplicaSet's pods are still Ready and still
# counted, so a green whose NEW pods can never start reports "2/2 Ready" from
# the previous, working generation. Observed exactly that: a green with
# EXPECTED_SCHEMA_VERSION=99 showed 2/2 while its new pod sat at Ready=false.
#
# updatedReplicas counts only pods from the CURRENT template, so it is the
# figure that answers "is the thing I just deployed serving", which is the
# actual question.
UPDATED=$(k get "deploy/station2-twin-$COLOR" -o jsonpath='{.status.updatedReplicas}' 2>/dev/null)
UPDATED=${UPDATED:-0}
[ "$UPDATED" = "$DESIRED" ] \
  || fail "$UPDATED/$DESIRED replicas are running the CURRENT template ($READY Ready, but some belong to the previous generation). The rollout has not completed."
echo "  [1/4] $READY/$DESIRED Ready, $UPDATED/$DESIRED on the current template"

# 3. ask the pods NOW, do not trust cached status
PODS=$(k get pods -l "color=$COLOR" -o jsonpath='{.items[*].metadata.name}')
[ -n "$PODS" ] || fail "no pods for colour '$COLOR'"
for pod in $PODS; do
  BODY=$(k exec "$pod" -- python -c \
    "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8080/health/ready',timeout=5).read().decode())" 2>/dev/null) \
    || fail "pod $pod did not answer /health/ready right now (cached Ready is not enough)"
  STATUS=$(printf '%s' "$BODY" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("status"))' 2>/dev/null)
  [ "$STATUS" = "ready" ] || fail "pod $pod reports status='$STATUS', not 'ready'"
done
echo "  [2/4] every pod answered /health/ready with status=ready just now"

# 4. the schema they expect is the schema that exists
POD_SCHEMA=$(k exec "$(echo "$PODS" | awk '{print $1}')" -- python -c \
  "import urllib.request,json;print(json.load(urllib.request.urlopen('http://127.0.0.1:8080/health/ready',timeout=5))['schema_version'])" 2>/dev/null)
DB_SCHEMA=$(docker exec station2-twin-db-1 psql -U twin -d twin -tAc \
  'SELECT MAX(version) FROM schema_migrations' 2>/dev/null | tr -d '[:space:]')
[ -n "$POD_SCHEMA" ] && [ "$POD_SCHEMA" = "$DB_SCHEMA" ] \
  || fail "schema mismatch: pods serve $POD_SCHEMA, database is at $DB_SCHEMA"
echo "  [3/4] pods and database agree on schema $POD_SCHEMA"

# The switch itself. One line, atomic, and reversible by running this script
# with the other colour.
k patch svc station2-twin -p "{\"spec\":{\"selector\":{\"app\":\"station2-twin\",\"color\":\"$COLOR\"}}}" >/dev/null
NOW=$(k get svc station2-twin -o jsonpath='{.spec.selector.color}')
[ "$NOW" = "$COLOR" ] || fail "patch applied but selector is '$NOW'"
echo "  [4/4] Service selector is now color=$COLOR"

# The metrics NodePort must move WITH the traffic Service, in the same step.
#
# Leaving it behind would point Prometheus at the colour that is no longer
# serving -- monitoring the wrong copy, which is precisely the defect this
# platform has now hit twice (station1-hello's retirement, and the Kubernetes
# copy going unscraped for days). It would also be the worst possible moment
# for it: right after a promote is when someone looks at the graph.
#
# Verified, not assumed: the selector is read back, and a mismatch is fatal.
if k get svc station2-twin-metrics >/dev/null 2>&1; then
  k patch svc station2-twin-metrics -p "{\"spec\":{\"selector\":{\"app\":\"station2-twin\",\"color\":\"$COLOR\"}}}" >/dev/null
  MNOW=$(k get svc station2-twin-metrics -o jsonpath='{.spec.selector.color}')
  [ "$MNOW" = "$COLOR" ] || fail "metrics service still points at '$MNOW' -- Prometheus would watch the idle colour"
  echo "        metrics Service moved with it (Prometheus now watches color=$COLOR)"
else
  # Not silent. A missing metrics service means the migrated copy is unscraped,
  # and that has to be said out loud rather than discovered weeks later.
  echo "  WARN  station2-twin-metrics does not exist -- the K8s copy is UNSCRAPED"
fi

# Endpoints are the proof. A selector that matches nothing yields an empty
# endpoint list and a Service that blackholes every request while looking
# correctly configured.
EP=$(k get endpoints station2-twin -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w | tr -d ' ')
[ "$EP" -gt 0 ] || fail "selector switched but endpoints are EMPTY -- the Service now blackholes traffic"
echo ""
echo "  promoted $CURRENT -> $COLOR ($EP endpoints serving)"

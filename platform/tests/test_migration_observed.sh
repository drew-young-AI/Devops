#!/usr/bin/env bash
# Anything the platform claims to have MIGRATED must be watched where it now
# runs -- not where it used to.
#
# WHY THIS SUITE EXISTS.
#
# This defect has now happened twice, in opposite directions:
#
#   2026-08-19  station1-hello was retired. Monitoring kept pointing at it.
#               station2-twin ran for days with no scrape target at all, and
#               the board was green the whole time because it was watching the
#               pilot that no longer mattered.
#               (pilots/README.md: "儀表板對著錯的服務顯示「一切正常」，
#                比沒有儀表板更糟")
#
#   2026-09-01  The board said the pilot had migrated to Kubernetes. The
#               Kubernetes copy sat on a ClusterIP while k3d published nothing
#               but the API port, so Prometheus could not reach it EVEN IN
#               PRINCIPLE. Two active targets; the migrated copy was neither.
#
# Both times every component worked. What was missing was anyone asserting that
# the set of things running equals the set of things watched. That assertion is
# this file.
#
# WHY IT CHECKS DEPLOYMENTS AGAINST TARGETS RATHER THAN COUNTING EITHER.
#
# "Prometheus has N targets" is satisfied by N targets pointing anywhere.
# "The cluster has N deployments" says nothing about who is looking. Only the
# JOIN between them can fail in the way that actually hurt.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="migration-observed"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== every deployed workload must be scraped where it now runs =="

PROM="${PROM_URL:-http://127.0.0.1:19090}"
CTX="${K8S_CTX:-k3d-devops-lab}"
SYSTEM_NS="kube-system|kube-public|kube-node-lease|default"

# The decision rule, isolated so the controls below can feed it synthetic input
# and stay deterministic whether or not a cluster happens to be up.
unwatched() {  # <newline-separated workloads> <newline-separated watched names>
  local workloads="$1" watched="$2" out=""
  while read -r w; do
    [ -n "$w" ] || continue
    printf '%s\n' "$watched" | grep -qx "$w" || out="$out $w"
  done <<< "$workloads"
  printf '%s' "$out"
}

# ---- controls first, so the rule is known to work before it is trusted ------
[ -z "$(unwatched "a
b" "a
b")" ] \
  && _pass "does not cry wolf: every workload watched reports nothing" \
  || _fail "does not cry wolf: every workload watched reports nothing" "reported something"

[ "$(unwatched "a
b" "a")" = " b" ] \
  && _pass "catches: a workload nothing scrapes" \
  || _fail "catches: a workload nothing scrapes" "did not name it"

# A workload set that is EMPTY must not read as success. An empty join is
# trivially satisfied, and "nothing was checked" is the state this whole suite
# exists to stop being reported as green.
[ -z "$(unwatched "" "a")" ] \
  && _pass "an empty workload set is not evidence of anything (handled below)" \
  || _fail "an empty workload set is not evidence of anything" "unexpected output"

# ---- the live join ---------------------------------------------------------
if ! curl -s -m 5 -o /dev/null "$PROM/-/ready" 2>/dev/null; then
  echo "  SKIP  Prometheus unreachable at $PROM -- coverage is UNVERIFIED"
elif ! kubectl --context "$CTX" --request-timeout=8s get --raw /readyz >/dev/null 2>&1; then
  echo "  SKIP  cluster '$CTX' unreachable -- coverage is UNVERIFIED"
else
  WORKLOADS="$(kubectl --context "$CTX" get deploy -A \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.labels.app}{"\n"}{end}' 2>/dev/null \
    | grep -vE "^($SYSTEM_NS)	" | cut -f2 | grep -v '^$' | sort -u)"

  WATCHED="$(curl -s -m 8 "$PROM/api/v1/targets?state=active" \
    | python3 -c 'import sys, json
try:
    ts = json.load(sys.stdin)["data"]["activeTargets"]
except Exception:
    sys.exit(1)
# Only targets that are actually UP count. A configured target that has never
# answered is a scrape config, not observation -- and reading it as coverage is
# the same mistake as reading a parsed rule as an evaluated one (ADR-0007).
for t in ts:
    if t.get("health") == "up" and t["labels"].get("environment") == "k8s":
        s = t["labels"].get("service")
        if s:
            print(s)' | sort -u)"

  if [ -z "$WORKLOADS" ]; then
    echo "  VACUOUS  no non-system deployment on '$CTX' -- nothing to verify here"
  else
    MISSING="$(unwatched "$WORKLOADS" "$WATCHED")"
    COUNT="$(printf '%s\n' "$WORKLOADS" | grep -c .)"
    if [ -z "$MISSING" ]; then
      _pass "all $COUNT deployed workload(s) on '$CTX' are scraped with environment=k8s"
    else
      _fail "all $COUNT deployed workload(s) on '$CTX' are scraped with environment=k8s" \
            "unscraped:$MISSING -- it can fail without anyone being told"
    fi
  fi

  # The metrics Service must follow the colour that serves traffic. If it lags,
  # Prometheus watches the idle colour and the graph is about a build that is
  # not taking requests -- worst precisely after a promote, when someone looks.
  LIVE="$(kubectl --context "$CTX" -n station2 get svc station2-twin \
            -o jsonpath='{.spec.selector.color}' 2>/dev/null)"
  METRICS="$(kubectl --context "$CTX" -n station2 get svc station2-twin-metrics \
            -o jsonpath='{.spec.selector.color}' 2>/dev/null)"
  if [ -z "$LIVE" ] || [ -z "$METRICS" ]; then
    echo "  SKIP  station2 services not both present -- colour agreement UNVERIFIED"
  elif [ "$LIVE" = "$METRICS" ]; then
    _pass "the metrics Service follows the serving colour (both '$LIVE')"
  else
    _fail "the metrics Service follows the serving colour" \
          "traffic goes to '$LIVE' while Prometheus watches '$METRICS'"
  fi

  # The two copies must not diverge on IDENTITY.
  #
  # WHY (2026-09-01). They did, for two weeks. The Compose copy has reported
  # `credentials.mode = vault` since 2026-08-19 -- a dynamic user with a lease
  # that expires. The K8s copy, the one intended to become production, reported
  # `mode = static` and ran on `PGPASSWORD: twin-bootstrap` baked into its
  # Deployment. Nothing compared them, so nothing said the copy being promoted
  # had the weaker credential model.
  #
  # Comparing MODE rather than username is the point: the usernames are
  # supposed to differ (separate leases), the mode is not. Asserting equality
  # on the thing that must match, while the things that must differ are free to
  # differ, is what makes this a real check instead of a tautology.
  #
  # Both are read from the running services, not from manifests -- a manifest
  # says what was requested, `/health/ready` says what the process actually got.
  DEV_MODE="$(curl -s -m 5 http://127.0.0.1:18090/health/ready 2>/dev/null \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["credentials"]["mode"])
except Exception: pass' 2>/dev/null)"
  K8S_MODE="$(curl -s -m 5 http://127.0.0.1:18091/health/ready 2>/dev/null \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["credentials"]["mode"])
except Exception: pass' 2>/dev/null)"
  if [ -z "$DEV_MODE" ] || [ -z "$K8S_MODE" ]; then
    echo "  SKIP  one copy did not answer /health/ready -- credential parity UNVERIFIED"
  elif [ "$DEV_MODE" = "$K8S_MODE" ]; then
    _pass "both copies use the same credential model (both '$DEV_MODE')"
  else
    _fail "both copies use the same credential model" \
          "develop='$DEV_MODE' but k8s='$K8S_MODE' -- the copy heading for production is the weaker one"
  fi

  # And it must be the STRONG model, not merely the same one. Two copies that
  # both fell back to a static password would satisfy the check above while
  # being exactly the state it exists to prevent.
  if [ -n "$K8S_MODE" ]; then
    if [ "$K8S_MODE" = "vault" ]; then
      _pass "the k8s copy holds a dynamic, revocable credential"
    else
      _fail "the k8s copy holds a dynamic, revocable credential" \
            "mode='$K8S_MODE' -- a shared password with no expiry and no revocation path"
    fi
  fi
fi

suite_summary

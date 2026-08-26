#!/usr/bin/env bash
# Runs every platform test suite. This is the gate to run before and after
# touching anything in platform/.
#
#   platform/tests/run_all.sh
#
# THREE TIERS, BECAUSE THE SUITE GREW OUT OF ITS OWN HEADER.
#
# This file used to claim "no Docker daemon, no running Prometheus, no network".
# That stopped being true when test_data_contract_live.sh and test_no_lookahead.sh
# were added -- both need Docker and a live postgres. The header kept saying
# otherwise for five days. Fixed here rather than left as another comment that
# describes a system nobody has re-read.
#
#   TIER 1  no dependencies    static analysis, contracts, config parsing
#   TIER 2  Docker + platform   the live database; ABSENCE IS A FAILURE, because
#                               the database is part of the platform and a
#                               data-contract suite that passes with no data
#                               would have reported success throughout the
#                               3h55m credential outage on 2026-08-19
#   TIER 3  k3d cluster         the Kubernetes practice substrate; absence is a
#                               SKIP, because the Compose platform runs without
#                               it -- but a LOUD skip, counted and named in the
#                               summary line, never silently folded into "passed"
#
# Exit 0 only if every suite that RAN passed. Skips are reported, never hidden:
# the headline always states how many, so the summary cannot be misread as
# "everything ran".

set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SUITES=(
  test_static.sh
  test_deploy_contract.sh
  test_check_health.sh
  test_scheduler.sh
  test_ingress.sh
  test_llm_review.sh
  test_evidence_contract.sh
  # Data contracts against the LIVE database. Deliberately last, and deliberately
  # a hard failure rather than a skip when postgres is absent: a data-contract
  # suite that passes with no data would have reported success throughout the
  # 3h55m credential outage on 2026-08-19.
  test_data_contract_live.sh
  # The MLOps half of the same idea: a leak does not fail, it flatters. This
  # rebuilds the feature set over a truncated series and requires the past not
  # to change. Verified by injecting two deliberate leaks; both were caught.
  test_no_lookahead.sh
)

# TIER 3. Kept in a separate list because it needs a substrate the rest of the
# platform does not, and because it is minutes rather than seconds.
K8S_SUITES=(
  ../k8s/station2-twin/test_bluegreen.sh
  # Runs AFTER blue/green, deliberately. It asserts the network policy is
  # enforced, and blue/green is the thing most likely to be broken BY that
  # policy -- so the ordering means a policy that breaks deployment shows up as
  # a blue/green failure with its own message, not as a confusing netpol pass.
  ../k8s/station2-twin/verify_networkpolicy.sh
  # Needs the cluster, because three of its four states are about what the
  # gate does when PVCs exist -- and a suite that can only test the empty case
  # is testing the one case that was never broken.
  test_backup_coverage.sh
)
K8S_CTX="${K8S_CTX:-k3d-devops-lab}"

FAILED_SUITES=()
START="$(date +%s)"

for suite in "${SUITES[@]}"; do
  echo ""
  if ! bash "$SUITE_DIR/$suite"; then
    FAILED_SUITES+=("$suite")
  fi
done

# TIER 3: run only when the cluster answers. `kubectl get --raw /readyz` is a
# real API round-trip, not a config read -- the deleted cluster of 2026-08-19
# had a perfectly valid kubeconfig pointing at a dead port.
SKIPPED_SUITES=()
for suite in "${K8S_SUITES[@]}"; do
  echo ""
  if kubectl --context "$K8S_CTX" get --raw /readyz >/dev/null 2>&1; then
    if ! bash "$SUITE_DIR/$suite"; then
      FAILED_SUITES+=("$(basename "$suite")")
    fi
  else
    echo "=== $(basename "$suite") ==="
    echo "  SKIPPED: cluster '$K8S_CTX' does not answer /readyz."
    echo "           Start it with platform/k8s/create_cluster.sh, or accept"
    echo "           that blue/green went untested in this run."
    SKIPPED_SUITES+=("$(basename "$suite")")
  fi
done

echo ""
echo "========================================"
if [ "${#FAILED_SUITES[@]}" -eq 0 ]; then
  if [ "${#SKIPPED_SUITES[@]}" -eq 0 ]; then
    echo "ALL SUITES PASSED  ($(( $(date +%s) - START ))s)"
  else
    # The skip count is in the HEADLINE, not a footnote. A summary that reads
    # "ALL SUITES PASSED" while a suite never ran is the failure this whole
    # platform keeps rediscovering.
    echo "PASSED, ${#SKIPPED_SUITES[@]} SKIPPED  ($(( $(date +%s) - START ))s)"
    for suite in "${SKIPPED_SUITES[@]}"; do echo "  ~ $suite (not run)"; done
  fi
  exit 0
fi
echo "FAILED SUITES ($(( $(date +%s) - START ))s):"
for suite in "${FAILED_SUITES[@]}"; do
  echo "  - $suite"
done
exit 1

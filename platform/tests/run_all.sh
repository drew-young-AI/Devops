#!/usr/bin/env bash
# Runs every platform test suite. This is the gate to run before and after
# touching anything in platform/.
#
#   platform/tests/run_all.sh
#
# Requires: bash, system python3 (+ PyYAML), git, nc. No Docker daemon, no
# running Prometheus, no MLX endpoint, no network -- on purpose, so it stays
# runnable in CI and fast enough that it actually gets run.
#
# Exit 0 only if every suite passes.

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

FAILED_SUITES=()
START="$(date +%s)"

for suite in "${SUITES[@]}"; do
  echo ""
  if ! bash "$SUITE_DIR/$suite"; then
    FAILED_SUITES+=("$suite")
  fi
done

echo ""
echo "========================================"
if [ "${#FAILED_SUITES[@]}" -eq 0 ]; then
  echo "ALL SUITES PASSED  ($(( $(date +%s) - START ))s)"
  exit 0
fi
echo "FAILED SUITES ($(( $(date +%s) - START ))s):"
for suite in "${FAILED_SUITES[@]}"; do
  echo "  - $suite"
done
exit 1

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
  # The reviewer-facing report. Its coverage guard is the reason this is
  # here: a node added to dag.py and not to LINES disappears from the
  # report, and a missing stage reads exactly like a healthy one.
  test_stage_report.sh
  # Decision records. The rule under test is that every measured claim carries
  # a rerun command pointing at a file that still exists -- the same anti-zombie
  # rule the AIS capability registry uses for `verify`.
  test_decisions.sh
  # Data contracts against the LIVE database. Deliberately last, and deliberately
  # a hard failure rather than a skip when postgres is absent: a data-contract
  # suite that passes with no data would have reported success throughout the
  # 3h55m credential outage on 2026-08-19.
  # Which listeners the LAN can reach. Tier 2 because it needs the containers
  # actually running -- a compose file that SAYS 127.0.0.1 proves nothing about
  # what is bound right now.
  test_network_exposure.sh
  # The analytical mirror is 400x faster than the database it copies, which is
  # exactly why a stale one is dangerous: speed buys trust. Every assertion in
  # that suite is about it refusing to answer when it is not current.
  test_analytics_mirror.sh
  # An alert rule against a metric nobody produces parses fine, passes promtool,
  # and can never fire -- so the thing it claims to watch reads as permanently
  # healthy. That suite joins the rules against the exporter's actual output.
  test_dataops_metrics.sh
  # The dashboards themselves. Until 2026-08-29 nothing read them, and every
  # panel of the reviewer-facing board was querying a datasource uid that does
  # not exist -- valid JSON, valid PromQL, existing metrics, empty panels.
  test_dashboards.sh
  # The README is the central index, which makes its rot invisible: a dead link
  # in an index reads exactly like a link to something that is fine.
  test_readme_index.sh
  # Images must carry a build for the architecture of the cluster they are sent
  # to. Added 2026-08-31, after an arm64-only image imported cleanly onto the
  # amd64 box and only failed at the kubelet.
  test_image_arch.sh
  # The health probe writes one snapshot every 15 minutes and nobody reads
  # them. ADR-0006 measured that pile and prescribed aggregation rather than a
  # retention policy; this suite guards the aggregation, including its refusal
  # to summarise an empty directory into a clean bill of health.
  test_health_rollup.sh
  # A DAST PASS covers only what the configured profile can reach. The ZAP
  # baseline is a GET spider, so it never touches the pilot's one write
  # endpoint -- 4 of 10 routes when measured. This suite guards the reporter
  # that makes that number visible, including its refusal to report coverage
  # for a dispatcher it can no longer parse.
  test_dast_coverage.sh
  # Write-time log redaction. Backlog §6 calls it "a mitigation, not a
  # guarantee" and makes finishing it a hard prerequisite before real CYCH
  # data arrives -- but nothing asserted it redacted anything at all, and the
  # same three rules are declared twice, once per log stream. Hermetic: the
  # rules are read out of config.alloy and applied to synthetic values only.
  test_redaction.sh
  # The pilot's AppRole must be DELIVERED, not assumed to be in the operator's
  # shell. `.gitignore` reserved the drop-off file weeks ago and nothing wrote
  # it, so a restart without the variables exported silently downgraded the
  # develop copy to the static database password. Hermetic: synthetic AppRole
  # material in a sandbox, no real secret read or written.
  test_approle_env.sh
  # The eight-plate report has to open with no network, because the room where
  # it gets presented may not have any. Hermetic: asserts zero external
  # references and that the generated page still carries the source's diagrams;
  # it cannot prove they RENDER, and says so.
  test_offline_report.sh
)

# TIER 2. Needs Docker AND a live postgres holding the pilot's data. Separated
# from tier 1 on 2026-08-31 for a reason worth stating precisely, because the
# obvious reading of this change is that a rule was weakened.
#
# The rule "absence of the database is a FAILURE, not a skip" is correct on a
# machine that is SUPPOSED to have the database. It is what would have caught
# the 3h55m credential outage of 2026-08-19. It is meaningless on a cloud
# runner that has never had a database and never will: there the assertion
# cannot fail for a real reason, only for a structural one.
#
# And an assertion that is structurally guaranteed to be red does not stay a
# useful assertion -- it trains people to ignore the channel it reports on.
# That is not hypothetical here: 13 of the last 20 GitHub Actions runs were
# red, the most recent green one was weeks back, and nobody noticed for at
# least six days, because "CI is red" had stopped carrying information.
#
# So the tier is chosen BY THE CALLER and never auto-detected. A runner that
# has the platform runs tier 2 and a missing database is still a hard failure.
# A hermetic runner declares PLATFORM_TIERS=1 and the summary says loudly which
# tiers did not run. What is forbidden is the middle option -- silently
# downgrading a missing database to a skip -- because that is indistinguishable
# from the outage it exists to catch.
DB_SUITES=(
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
  # The join between "what is deployed" and "what is watched". Needs both the
  # cluster and Prometheus, because neither side alone can show the failure:
  # a workload nobody scrapes looks healthy from the cluster and absent from
  # the metrics, and both readings are individually unalarming.
  test_migration_observed.sh
)
K8S_CTX="${K8S_CTX:-k3d-devops-lab}"

# Default is every tier, so a developer who types run_all.sh with no arguments
# gets the strictest run. Weakening it takes a deliberate, visible declaration.
PLATFORM_TIERS="${PLATFORM_TIERS:-1,2,3}"
tier_enabled() { case ",$PLATFORM_TIERS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

FAILED_SUITES=()
NOT_RUN_TIERS=()
START="$(date +%s)"

for suite in "${SUITES[@]}"; do
  echo ""
  if ! bash "$SUITE_DIR/$suite"; then
    FAILED_SUITES+=("$suite")
  fi
done

if tier_enabled 2; then
  for suite in "${DB_SUITES[@]}"; do
    echo ""
    if ! bash "$SUITE_DIR/$suite"; then
      FAILED_SUITES+=("$suite")
    fi
  done
else
  NOT_RUN_TIERS+=("tier 2 (live database): ${DB_SUITES[*]}")
fi

# TIER 3: run only when the cluster answers. `kubectl get --raw /readyz` is a
# real API round-trip, not a config read -- the deleted cluster of 2026-08-19
# had a perfectly valid kubeconfig pointing at a dead port.
SKIPPED_SUITES=()
if ! tier_enabled 3; then
  NOT_RUN_TIERS+=("tier 3 (kubernetes): ${K8S_SUITES[*]##*/}")
  K8S_SUITES=()
fi
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
# Tiers the CALLER switched off are named before any verdict, so a green run on
# a hermetic runner can never be quoted as "the platform passed".
if [ "${#NOT_RUN_TIERS[@]}" -gt 0 ]; then
  echo "TIERS NOT RUN (PLATFORM_TIERS=$PLATFORM_TIERS):"
  for t in "${NOT_RUN_TIERS[@]}"; do echo "  ! $t"; done
  echo "  -> this run says nothing about them."
  echo "----------------------------------------"
fi
if [ "${#FAILED_SUITES[@]}" -eq 0 ]; then
  if [ "${#SKIPPED_SUITES[@]}" -eq 0 ] && [ "${#NOT_RUN_TIERS[@]}" -eq 0 ]; then
    echo "ALL SUITES PASSED  ($(( $(date +%s) - START ))s)"
  else
    # The skip count is in the HEADLINE, not a footnote. A summary that reads
    # "ALL SUITES PASSED" while a suite never ran is the failure this whole
    # platform keeps rediscovering.
    echo "PASSED tiers [$PLATFORM_TIERS], ${#SKIPPED_SUITES[@]} skipped, ${#NOT_RUN_TIERS[@]} tier(s) not run  ($(( $(date +%s) - START ))s)"
    for suite in "${SKIPPED_SUITES[@]}"; do echo "  ~ $suite (not run)"; done
  fi
  exit 0
fi
echo "FAILED SUITES ($(( $(date +%s) - START ))s):"
for suite in "${FAILED_SUITES[@]}"; do
  echo "  - $suite"
done
exit 1

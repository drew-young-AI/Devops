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
  # The suite's own footprint. make_sandbox copied platform/backup/archives
  # into every sandbox and the cleanup never ran (the registry was an array
  # appended inside a command substitution -- a subshell), so 124 sandboxes
  # and 421GB accumulated in $TMPDIR over three days. The volume was at 89%
  # and the disk-full outage of 2026-09-03 falls inside that window: the
  # test suite was the thing filling the disk it runs on.
  test_sandbox_hygiene.sh
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
  # The same join for the model layer, added 2026-09-08 after a measurement:
  # Prometheus held 99 metric names, of which devops_* had 20, dataops_* had
  # 15, and anything about a model had ZERO. The mlops row on the board was
  # five green lamps over nothing measured -- which is invisible precisely
  # because the lamps were green.
  test_mlops_metrics.sh
  test_gha_status.sh
  test_runbook.sh
  # Three board nodes added 2026-09-10 for surfaces that had a script and no
  # node: certificate expiry (nothing checked it, anywhere), host disk (the
  # number that stopped the platform once), and rotation COVERAGE (the sweep
  # prints PASS whether it checked three secrets or none). All three were
  # green the day they were added, so every assertion has a control that
  # makes it red -- including a deliberately expired certificate fixture.
  test_foundation_nodes.sh
  # The closure check. Not a test of a behaviour -- an enumeration of every
  # service and scheduled job, refusing unless each is mapped to a node or
  # written down as deliberately unmeasured. This is what stops the guard
  # set from being a list of past failures that only grows when somebody
  # happens to look.
  test_coverage_closure.sh
  # The mlops half: a schema that says "many models" while the code had one,
  # hardcoded, with its name retyped as a literal in three places. This suite
  # asserts a SECOND family is registered and runnable, and that an
  # unregistered name is refused with the list rather than silently
  # defaulted -- a default would file one algorithm's name against another
  # algorithm's numbers. Needs the pilot container, not the pilot database.
  test_model_registry.sh
  # How often each source is PUBLISHED, with provenance. §20 of the backlog
  # carried a table of "actual update frequency" written from impression,
  # and one of its five rows was wrong by two orders of magnitude. An
  # estimate and a measurement are indistinguishable once both are numbers
  # in a table, so the table records where each number came from and a row
  # without provenance fails.
  test_source_frequency.sh
  # Host disk. Added 2026-09-03, the day the volume filled and took the whole
  # platform down -- 14 alert rules, 91 capabilities, 777 green assertions,
  # and not one of them measured free space. The suite's real content is the
  # mutation check: it proves the new rules can go RED, which is the only
  # thing promtool SUCCESS does not tell you.
  test_host_capacity.sh
  # The same freshness question, asked generically. The disk suite above
  # originally carried a bespoke staleness rule for its own .prom file;
  # node-exporter already publishes node_textfile_mtime_seconds for all six,
  # and five of them had no guard at all. This suite is mostly a four-way
  # cross-check between the thresholds, the expression, jobs.conf and the
  # files that actually exist -- a NEW exporter with no rule is the gap an
  # alert cannot see, because an unwatched exporter reads as a healthy one.
  test_exporter_freshness.sh
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
  # README.md is declared to be the single index; nothing checked it. An audit
  # on 2026-09-02 found five documents nothing linked to, one of which was a
  # second, stale copy of the capability index. Walks the real link graph.
  test_doc_graph.sh
  # "We do not need ELK" rests entirely on Loki already occupying that slot,
  # and nothing checked that Loki was receiving anything. It was -- but the
  # same look found station2-twin declaring `data_class: platform`, which is
  # not a class, and which therefore fell through to the tenant with the wider
  # audience and the longer retention without erroring. The controls are
  # hermetic (metrics bodies from a file, class values from the environment);
  # the live half SKIPs loudly when Loki is not reachable, because on a
  # machine without the observability stack its absence is not a defect.
  test_loki_coverage.sh
  # Reachability is not currency. The document that did the most damage here
  # was reachable, prominently linked, and wrong -- a hand-curated status page
  # that said data governance and process visualisation were "almost empty"
  # nine days after both were built. This suite asks the complementary
  # question: is this rendered page generated, or is somebody promising to keep
  # it true by hand? Either is allowed; being neither is not.
  test_doc_freshness.sh
  # Documents being reachable is not the same as capabilities being findable.
  # First run found 9 of 89 scripts that no reachable document named -- four of
  # them things a human is supposed to RUN. Every one was called by other code,
  # which is the point: being called is not being discoverable, and the next
  # person who cannot find one writes a second one.
  test_capability_graph.sh
  # Reachability prevents one route to duplicate work -- you cannot find the
  # existing thing, so you build a second. It does nothing about the route that
  # actually happened: BOTH copies documented, BOTH reachable, drifted apart,
  # each shown to the same reader as current. Eight diagrams existed twice, one
  # set on the board and one in the deck.
  test_duplicate_check.sh
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

# ── WHICH SUITES, AND WHAT THEY COST ────────────────────────────────────────
#
# Two knobs, and they are deliberately different shapes.
#
#   PLATFORM_TIERS   which DEPENDENCY LEVELS may run (1,2,3). Already existed.
#   PLATFORM_SUITES  an extended-regex over suite basenames, for iterating on
#                    one area without paying for the whole run.
#
# Both are reported in the headline when set, for the same reason the tier
# list already is: a green line from a filtered run must never be quotable as
# "the platform passed". That sentence is the failure this repo keeps
# rediscovering, and a filter is a much easier way to reach it than a tier.
#
# WHY TIMING IS RECORDED AT ALL.
#
# "The suite takes about eight minutes" was the only thing anyone knew about
# its cost -- a total, with no idea which of the 30 suites owned it. That makes
# every optimisation a guess, and it makes the opposite mistake invisible too:
# a suite that silently grew from 4s to 90s never shows up as anything except
# a slightly longer wait. So each suite is timed, the numbers land in
# evidence/tests/suite_timing.json, and the five most expensive are printed
# with their share of the total.
#
# A FILE, NOT AN ARRAY. lib.sh already carries this scar: a registry appended
# inside a command substitution is appended in a subshell and lost with it,
# which is how 421GB of sandboxes accumulated while the cleanup code "existed".
# Nothing here runs run_suite in a subshell today. That is exactly the
# assumption that was true last time too.
PLATFORM_SUITES="${PLATFORM_SUITES:-}"
# lib.sh is not sourced here (this file is a runner, not a suite), so the repo
# root is derived rather than inherited.
RA_REPO_ROOT="$(cd "$SUITE_DIR/../.." && pwd)"
# `name.XXXXXX`, not a bare prefix: GNU mktemp refuses a template with fewer
# than three X and prints nothing, so TIMING_FILE was EMPTY on Linux and
# every write went to a path that is the empty string. The repo documents
# this idiom in four other suites; these call sites had not followed it.
TIMING_FILE="$(mktemp -t suite_timing.XXXXXX)"
trap 'rm -f "$TIMING_FILE"' EXIT

suite_selected() {
  [ -z "$PLATFORM_SUITES" ] && return 0
  echo "$1" | grep -qE "$PLATFORM_SUITES"
}

FILTERED_OUT=0
run_suite() {
  local suite="$1" tier="$2" base t0 secs rc
  base="$(basename "$suite")"
  if ! suite_selected "$base"; then
    FILTERED_OUT=$((FILTERED_OUT + 1))
    return 0
  fi
  echo ""
  t0="$(date +%s)"
  bash "$SUITE_DIR/$suite"
  rc=$?
  secs=$(( $(date +%s) - t0 ))
  printf '%s|%s|%s|%s\n' "$base" "$tier" "$secs" "$rc" >> "$TIMING_FILE"
  return $rc
}

# Default is every tier, so a developer who types run_all.sh with no arguments
# gets the strictest run. Weakening it takes a deliberate, visible declaration.
PLATFORM_TIERS="${PLATFORM_TIERS:-1,2,3}"
tier_enabled() { case ",$PLATFORM_TIERS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

FAILED_SUITES=()
NOT_RUN_TIERS=()
START="$(date +%s)"

for suite in "${SUITES[@]}"; do
  run_suite "$suite" 1 || FAILED_SUITES+=("$suite")
done

if tier_enabled 2; then
  for suite in "${DB_SUITES[@]}"; do
    run_suite "$suite" 2 || FAILED_SUITES+=("$suite")
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
for suite in ${K8S_SUITES+"${K8S_SUITES[@]}"}; do
  if kubectl --context "$K8S_CTX" get --raw /readyz >/dev/null 2>&1; then
    run_suite "$suite" 3 || FAILED_SUITES+=("$(basename "$suite")")
  elif suite_selected "$(basename "$suite")"; then
    echo ""
    echo "=== $(basename "$suite") ==="
    echo "  SKIPPED: cluster '$K8S_CTX' does not answer /readyz."
    echo "           Start it with platform/k8s/create_cluster.sh, or accept"
    echo "           that blue/green went untested in this run."
    SKIPPED_SUITES+=("$(basename "$suite")")
  fi
done

TOTAL=$(( $(date +%s) - START ))

# The cost record. Written before the verdict so it exists even on a red run --
# a slow suite is most interesting on the run where something also broke.
COST_REPORT="$(TIMING_FILE="$TIMING_FILE" TOTAL="$TOTAL" \
  OUT="$RA_REPO_ROOT/evidence/tests/suite_timing.json" \
  PLATFORM_TIERS="$PLATFORM_TIERS" PLATFORM_SUITES="$PLATFORM_SUITES" \
  python3 "$SUITE_DIR/suite_timing.py" 2>/dev/null)"

echo ""
echo "========================================"
if [ -n "$COST_REPORT" ]; then
  echo "$COST_REPORT"
  echo "----------------------------------------"
fi
# Tiers the CALLER switched off are named before any verdict, so a green run on
# a hermetic runner can never be quoted as "the platform passed".
if [ "${#NOT_RUN_TIERS[@]}" -gt 0 ]; then
  echo "TIERS NOT RUN (PLATFORM_TIERS=$PLATFORM_TIERS):"
  # ${A+"${A[@]}"} -- macOS ships bash 3.2, where expanding an EMPTY array
  # under `set -u` is an unbound-variable error. lib.sh already uses this form
  # for the same reason; this file did not, and the branch that reaches an
  # empty SKIPPED_SUITES was simply never taken until the suite filter made it
  # reachable.
  for t in ${NOT_RUN_TIERS+"${NOT_RUN_TIERS[@]}"}; do echo "  ! $t"; done
  echo "  -> this run says nothing about them."
  echo "----------------------------------------"
fi
if [ "$FILTERED_OUT" -gt 0 ]; then
  echo "FILTERED (PLATFORM_SUITES=$PLATFORM_SUITES): $FILTERED_OUT suite(s) did not run."
  echo "  -> this is a partial run. It cannot be quoted as a platform verdict."
  echo "----------------------------------------"
fi
if [ "${#FAILED_SUITES[@]}" -eq 0 ]; then
  if [ "${#SKIPPED_SUITES[@]}" -eq 0 ] && [ "${#NOT_RUN_TIERS[@]}" -eq 0 ] \
     && [ "$FILTERED_OUT" -eq 0 ]; then
    echo "ALL SUITES PASSED  (${TOTAL}s)"
  else
    # The skip count is in the HEADLINE, not a footnote. A summary that reads
    # "ALL SUITES PASSED" while a suite never ran is the failure this whole
    # platform keeps rediscovering.
    echo "PASSED tiers [$PLATFORM_TIERS], ${#SKIPPED_SUITES[@]} skipped, ${#NOT_RUN_TIERS[@]} tier(s) not run, $FILTERED_OUT filtered  (${TOTAL}s)"
    for suite in ${SKIPPED_SUITES+"${SKIPPED_SUITES[@]}"}; do echo "  ~ $suite (not run)"; done
  fi
  exit 0
fi
echo "FAILED SUITES (${TOTAL}s):"
for suite in ${FAILED_SUITES+"${FAILED_SUITES[@]}"}; do
  echo "  - $suite"
done
exit 1

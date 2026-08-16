#!/usr/bin/env bash
# Deterministic "is the platform healthy right now" check.
#
# This is the interface a scheduled agent (or cron, or a human) calls to get
# ONE reproducible answer instead of re-interpreting a Grafana dashboard by
# eye. The thresholds are not here -- they live in
# prometheus/alerts/*.yml, in version control. This script only reports what
# those rules currently say.
#
# Exit codes (the actual contract -- an agent should branch on these):
#   0  HEALTHY   monitoring is working AND no alerts are active
#   1  DEGRADED  monitoring is working AND the worst active alert is
#                warning/info
#   2  CRITICAL  monitoring is working AND a critical alert is active
#   3  UNKNOWN   monitoring itself is broken -- health cannot be determined
#
# Exit 3 exists because it is the failure mode that silently defeats the
# entire point of alerting: a dead Prometheus reports zero active alerts,
# which is byte-identical to "everything is fine". So this script verifies
# the observability stack is actually alive and actually wired to
# Alertmanager BEFORE it is willing to interpret an empty alert list as
# good news. "No alerts" from a broken monitor is not health, it is silence.
#
# Usage:
#   check_health.sh [--json] [--no-evidence]
#
# Env overrides:
#   PROMETHEUS_URL    default http://127.0.0.1:19090
#   ALERTMANAGER_URL  default http://127.0.0.1:19093

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

export PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:19090}"
export ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://127.0.0.1:19093}"
export CHECK_JSON=0
export CHECK_EVIDENCE=1

for arg in "$@"; do
  case "$arg" in
    --json) CHECK_JSON=1 ;;
    --no-evidence) CHECK_EVIDENCE=0 ;;
    *) echo "Usage: $0 [--json] [--no-evidence]" >&2; exit 3 ;;
  esac
done

export EVIDENCE_DIR="$REPO_ROOT/evidence/observability"
python3 "$SCRIPT_DIR/check_health.py"

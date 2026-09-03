#!/usr/bin/env bash
# Daily ingest: pull every weekly surveillance feed and upsert it.
#
# WHY THIS EXISTS AT ALL (2026-09-03).
#
# It did not, until today. The loaders were written on 2026-08-20 and run by
# hand that day; jobs.conf then carried nineteen jobs, none of which fetched
# any data. Every downstream stage stayed green on top of that: the mirror
# refreshed, dataops computed metrics, retrain retrained weekly -- all of them
# correctly processing a dataset that had stopped moving fourteen days earlier.
# The one thing that noticed was DataSourceStale, and only because its
# threshold is 14 days; it went pending at 00:41 today, for the first time.
#
# WHY DAILY, WHEN THE SOURCE IS WEEKLY.
#
# jobs.conf picks cadence from how fast the watched thing changes, which argues
# for weekly. The reason it is daily anyway: CDC does not announce WHICH day it
# publishes. A weekly poll landing on the wrong weekday adds up to 7 days of
# avoidable lag on top of the source's own ~2-week publication lag, and there
# is no signal to align it to. A daily run costs 5 minutes, writes nothing when
# the upstream has not moved (the upsert is idempotent), and removes that
# guesswork entirely.
#
# WHY NOT --sources all.
#
# `all` adds cdc-tb-town and cdc-tb-caremag. Neither feeds the forecast, and
# caremag alone is 4.1M stock rows re-read daily to learn nothing -- annual and
# near-annual sources do not belong on a daily schedule. They stay a manual
# load; DataSourceStale watches them at 14 days and MissingSource at 45, which
# is the correct instrument for a source that genuinely updates that rarely.
#
# THE PASSWORD IS NEVER AN ARGUMENT.
#
# Same rule as every other entry point here: it goes into the environment, and
# ingest/run.sh forwards it as -e. Arguments are visible in `ps` to every user
# on this machine.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PGPASSWORD="${PGPASSWORD:-twin-bootstrap}"

echo "=== [dataops] ingest $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
"$ROOT/pilots/station2-twin/ingest/run.sh" load_dimensional.py \
    --sources "${INGEST_SOURCES:-nhi_all,rods_all}"
rc=$?

# A fetch failure is a REAL failure and exits non-zero: unlike the forecast
# gate, there is no correct outcome in which the data does not arrive. But the
# alert that matters is still DataSourceStale, not this exit code -- one failed
# run is a bad afternoon, and fourteen days of them is the outage.
[ "$rc" -eq 0 ] || echo "FAILED: ingest rc=$rc" >&2
exit "$rc"

#!/usr/bin/env bash
# The sources the daily ingest deliberately leaves out -- fetched weekly.
#
# WHY THIS EXISTS.
#
# ingest.sh runs `--sources nhi_all,rods_all` daily and documented the omission
# like this: annual and near-annual sources "stay a manual load; DataSourceStale
# watches them at 14 days and MissingSource at 45, which is the correct
# instrument for a source that genuinely updates that rarely."
#
# That reasoning is self-defeating and the numbers said so. A source that is
# loaded BY HAND and updates yearly will exceed 14 days as a matter of course,
# so the "correct instrument" was guaranteed to sit red forever. Measured
# 2026-09-03, after the daily ingest had been running for a day:
#
#   moi-admin-geography          15.35 d      <- red
#   cdc-tb-caremag               15.28 d      <- red
#   cdc-tb-town                  14.94 d      <- red
#   moi-ris-village-population   14.71 d      <- red
#   moi-ris-village-education    14.71 d      <- red
#   every other source            0.25 d
#
# docs/Backlog.md §20 proposed fixing this by giving each source its own
# threshold derived from the publisher's cadence. That would have been the
# wrong fix: `dataops_source_age_seconds` is time since WE fetched, not since
# the upstream published, so a per-source threshold would have raised the bar
# until a true statement -- "nothing has fetched this in a fortnight" -- stopped
# being said. The five were not mis-thresholded. They were unfetched.
#
# The cost of one permanently-red member is not the noise. It is that
# DataSourceStale was the ONLY thing that noticed the 14-day outage on
# 2026-09-03 (ADR-0013), and a class with a permanent red in it is a class
# people learn to filter.
#
# WHY WEEKLY.
#
# From pilots/station2-twin/ingest/source_frequency.json, which is fetched from
# the publishers' own catalogues rather than estimated:
#
#   cdc-tb-town                  declared year
#   moi-ris-village-population   structural: the API is addressed per ROC year
#   moi-ris-village-education    structural: same
#   cdc-tb-caremag               declared day
#   moi-admin-geography          unknown (NLSC is a snapshot API, no cadence)
#
# Weekly keeps every one of them inside the existing 14-day threshold with a
# full missed run to spare, and costs a seventh of what daily would: caremag is
# 4.1M stock rows re-read to learn nothing on most days, which is the real
# reason it was left off the daily job. The 7-day lag on caremag is accepted
# deliberately -- it feeds no forecast, and being a week behind on a series
# nothing consumes is cheaper than reading 4.1M rows 365 times a year.
#
# ROC 115 IS FETCHED EVEN THOUGH IT DOES NOT EXIST YET.
#
# Measured: ODRP019/115 returns HTTP 200 with responseCode OD-0102-S and zero
# rows, and load_registry.py turns a non-OD-0101-S code into a skip rather than
# a failure. So asking for 114-115 costs one wasted request per run and starts
# collecting 115 the week it appears, with nothing to remember to change.
#
# THE PASSWORD IS NEVER AN ARGUMENT. Same rule as ingest.sh: it goes in the
# environment, because arguments are visible in `ps` to every user here.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PGPASSWORD="${PGPASSWORD:-twin-bootstrap}"
RUN="$ROOT/pilots/station2-twin/ingest/run.sh"

echo "=== [dataops] slow ingest $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
rc=0

# Each loader is run separately and its result recorded separately: they fetch
# from three different publishers, and one being down should not be reported as
# all three failing.
step() {  # <label> <script> [args...]
  local label="$1"; shift
  echo "--- $label"
  "$RUN" "$@"
  local this=$?
  [ "$this" -ne 0 ] && { echo "--- $label FAILED rc=$this"; rc=1; }
  return 0
}

step "dimensional: tb, caremag" load_dimensional.py --sources tb,caremag
step "registry: village population and education" \
     load_registry.py --datasets pop,edu --years 114-115
step "geography: NLSC administrative areas" load_geography.py --refresh

echo "=== [dataops] slow ingest done rc=$rc ==="
exit $rc

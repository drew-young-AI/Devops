#!/usr/bin/env bash
# Data contracts that only the live database can answer.
#
# The static half lives in pilots/station2-twin/tests/test_data_contract.py and
# runs on every commit in milliseconds. This half asks questions about 6.1
# million rows, which no amount of reading source can settle.
#
# DELIBERATELY FAILS RATHER THAN SKIPS WHEN THE DATABASE IS ABSENT.
#
# The obvious design -- skip when postgres is unreachable -- produces a suite
# that reports success on a platform with no data at all. A test that skips
# under exactly the conditions it exists to detect is indistinguishable from a
# test that was never written. This is a PLATFORM test; the platform includes
# its database, and its absence is a finding.
#
# psql runs in a pinned container, matching platform/db/migrate.sh: no host
# postgresql-client dependency, and no "whatever brew installed" version skew.
set -uo pipefail

PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-15432}"
PGDATABASE="${PGDATABASE:-twin}"
PGUSER="${PGUSER:-twin}"
PGPASSWORD="${PGPASSWORD:-twin-bootstrap}"
PSQL_IMAGE="${PSQL_IMAGE:-postgres:16-alpine}"

q() {
  docker run --rm -i -e PGPASSWORD="$PGPASSWORD" --network host "$PSQL_IMAGE" \
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
      -v ON_ERROR_STOP=1 -qtAX -c "$1" 2>&1
}

PASS=0; FAIL=0
check() {
  local name="$1" expected="$2" sql="$3"
  local got; got="$(q "$sql" | tr -d '[:space:]')"
  if [ "$got" = "$expected" ]; then
    printf '  PASS  %s\n' "$name"; PASS=$((PASS+1))
  else
    printf '  FAIL  %s\n         expected %s, got %s\n' "$name" "$expected" "$got"
    FAIL=$((FAIL+1))
  fi
}

echo "=== data contracts (live) ==="

if ! q 'SELECT 1' >/dev/null 2>&1; then
  echo "  FAIL  database unreachable at $PGHOST:$PGPORT/$PGDATABASE" >&2
  echo "" >&2
  echo "This is a failure, not a skip. A data-contract suite that passes with" >&2
  echo "no database would have reported success throughout the 3h55m outage" >&2
  echo "on 2026-08-19." >&2
  exit 1
fi

# ── lineage ──────────────────────────────────────────────────────────────────
# Migration 009 enforces this with a CHECK, so a violation should be impossible.
# Asserted anyway: the CHECK can be dropped, and "a constraint protects us" is
# the class of claim this platform has been wrong about before.
check "every ingest_run's source rows are accounted for" "0" \
  "SELECT count(*) FROM ingest_runs
    WHERE rows_in_file <> source_rows_accepted + rows_rejected + duplicate_rows"

check "no ingest_run reports output without accepting input" "0" \
  "SELECT count(*) FROM ingest_runs
    WHERE output_rows_written > 0 AND source_rows_accepted = 0
      AND synthesized_rows = 0"

# ── referential integrity beyond the foreign keys ────────────────────────────
check "every fact geo_code resolves to a real area" "0" \
  "SELECT count(*) FROM surveillance_fact f
    LEFT JOIN geo_area g ON g.geo_code = f.geo_code WHERE g.geo_code IS NULL"

check "every demographic geo_code resolves to a real area" "0" \
  "SELECT count(*) FROM demographic_fact d
    LEFT JOIN geo_area g ON g.geo_code = d.geo_code WHERE g.geo_code IS NULL"

check "every township has a county parent" "0" \
  "SELECT count(*) FROM geo_area t
    WHERE t.geo_level = 'township'
      AND (t.parent_code IS NULL
           OR NOT EXISTS (SELECT 1 FROM geo_area c
                          WHERE c.geo_code = t.parent_code
                            AND c.geo_level = 'county'))"

# ── the modelling contract migration 012 exists to hold ──────────────────────
# A metric used by several diseases is correct (nhi_visits, by design). A metric
# whose NAME repeats the single disease that uses it is the duplication creeping
# back. Checked in data because a feed can be added without touching METRICS.
check "no metric name repeats its only disease" "0" \
  "SELECT count(*) FROM (
     SELECT m.code AS metric, min(d.code) AS disease
     FROM surveillance_fact f
     JOIN metric m USING (metric_id) JOIN disease d USING (disease_id)
     GROUP BY m.code HAVING count(DISTINCT d.disease_id) = 1
   ) s WHERE s.metric LIKE s.disease || '\\_%' ESCAPE '\\'"

# ── stock vs flow ────────────────────────────────────────────────────────────
check "every metric declares a measure_type" "0" \
  "SELECT count(*) FROM metric WHERE measure_type IS NULL OR measure_type = ''"

check "population and TB caseload are typed as stock" "0" \
  "SELECT count(*) FROM metric
    WHERE code IN ('population','households','household_heads',
                   'tb_under_management','tb_confirmed_under_management',
                   'tb_mdr_under_management')
      AND measure_type <> 'stock'"

# ── missing is not zero ──────────────────────────────────────────────────────
# COVID-19 starts in 2021 while its siblings start in 2016. If the gap were ever
# padded, the padding would show up as a run of exact zeros across every county
# and age band for the missing years -- which is not what real reporting looks
# like.
check "COVID-19 has no fabricated pre-2021 rows" "0" \
  "SELECT count(*) FROM surveillance_fact f
     JOIN data_source ds USING (source_id)
     JOIN time_period tp USING (period_id)
    WHERE ds.code = 'cdc-nhi-covid' AND tp.epi_year < 2021"

check "no fact row has a NULL value standing in for absence" "0" \
  "SELECT count(*) FROM surveillance_fact WHERE value IS NULL"

# ── denominators ─────────────────────────────────────────────────────────────
check "no feed claims a denominator it did not load" "0" \
  "SELECT count(*) FROM (
     SELECT ds.code, ds.has_denominator,
            count(f.denominator) AS with_denom, count(*) AS total
     FROM data_source ds JOIN surveillance_fact f USING (source_id)
     GROUP BY 1,2
   ) s WHERE s.has_denominator AND s.with_denom = 0"

# A numerator larger than its own denominator is arithmetically impossible for a
# rate. Found on this suite's FIRST run: 34 rows, every one of them
# cdc-nhi-covid -- e.g. 2022W13 基隆市 13~15 住院, 5 COVID admissions against 1
# total admission.
#
# VERIFIED AS A SOURCE DEFECT, NOT A LOADER DEFECT: the raw CSV at
# od.cdc.gov.tw/eic/NHI_COVID-19.csv contains exactly the same 34 rows with the
# same values. The loader is faithful.
#
# The split is 33 住院 and 1 門診 (2022W40 連江縣 3~6, 27 against 24). The first
# version of this check asserted "all 34 are inpatient", which was wrong, and
# the check caught it on its own first re-run -- which is the argument for
# asserting an exact number instead of a comfortable inequality.
#
# The cause is NOT diagnosed and is not guessed at here. The plausible reading --
# that the denominator counts admissions while the COVID numerator counts claims,
# so transfers and re-billing inflate it -- is a hypothesis, and it does not
# explain the outpatient row at all. This goes on the list to confirm with
# 疾管署 alongside the epi-week definition.
#
# Asserted as an exact known count rather than relaxed to "some are allowed":
#   count drops  -> the source fixed it, and we should notice
#   count rises  -> something changed, and we should notice
# The affected years are closed, so new publications must not add to it.
check "denominator violations confined to the known COVID defect" "34" \
  "SELECT count(*) FROM surveillance_fact f JOIN data_source ds USING (source_id)
    WHERE f.denominator IS NOT NULL AND f.denominator > 0 AND f.value > f.denominator
      AND ds.code = 'cdc-nhi-covid'"

check "no OTHER feed has a numerator exceeding its denominator" "0" \
  "SELECT count(*) FROM surveillance_fact f JOIN data_source ds USING (source_id)
    WHERE f.denominator IS NOT NULL AND f.denominator > 0 AND f.value > f.denominator
      AND ds.code <> 'cdc-nhi-covid'"

# ── the rollup the TB rate depends on ────────────────────────────────────────
check "geo_population covers county, township and village" "3" \
  "SELECT count(DISTINCT geo_level) FROM geo_population"

# LEAVE PROOF IT RAN.
#
# Until 2026-08-25 this suite wrote nothing. Every other gate on this platform
# drops an evidence file, and the status board reads those files -- so the
# DataOps contract node could only ever show "???" no matter how many times the
# suite passed. A check whose result nobody can see afterwards is a check that
# is, from the board's point of view, not running.
#
# Written BEFORE the exit, so a failing run leaves evidence too. Evidence that
# only appears on success is how a red gate becomes invisible.
# This suite does not source lib.sh, so it has no REPO_ROOT. Derived here
# rather than assumed from the caller's cwd -- run_all.sh and a bare
# invocation start from different directories.
EVIDENCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/evidence/data"
mkdir -p "$EVIDENCE_DIR"
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
python3 - "$EVIDENCE_DIR/contract_summary_${STAMP}.json" "$PASS" "$FAIL" "$STAMP" <<'PY'
import json, pathlib, sys
out, passed, failed, stamp = sys.argv[1:]
pathlib.Path(out).write_text(json.dumps({
    "suite": "data_contract_live",
    "generated_at": stamp,
    "assertions_passed": int(passed),
    "assertions_failed": int(failed),
    # The key the status board reads. PASS/FAIL rather than a count, because
    # "27 passed" says nothing about whether any FAILED.
    "gate_result": "PASS" if int(failed) == 0 else "FAIL",
}, indent=2) + "\n")
PY

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "  $PASS passed, $FAIL FAILED" >&2
  exit 1
fi
echo "  $PASS passed, 0 failed"

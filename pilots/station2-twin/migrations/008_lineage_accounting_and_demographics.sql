-- 008: make lineage arithmetic checkable, and give the platform a denominator.
--
-- EXPAND PHASE. Nothing is dropped here. `ingest_runs.rows_accepted` stays,
-- deprecated but present, because 003 -> 007 already taught this platform what
-- happens when the expand phase drops its own rollback target.
--
-- ─────────────────────────────────────────────────────────────────────────
-- PART A -- WHY ingest_runs COULD NOT BE CHECKED
--
-- The table was populated and honest, but `rows_accepted` carried three
-- different units depending on which loader wrote the row:
--
--   cdc-rods-ili     109,907 in ->   109,907 accepted   source rows
--   moi-geography      8,054 in ->     8,059 accepted   dimension rows, +5 synthesised
--   cdc-tb-caremag 1,549,649 in -> 4,085,772 accepted   FACT rows, 3 metrics per source row
--
-- So `in_file = accepted + rejected` failed on 3 of 14 rows, for two entirely
-- legitimate reasons, and nothing in the table said which. A lineage record you
-- cannot write an assertion over is the same class of artefact as a comment
-- describing a mechanism: it reads as provenance and proves nothing.
--
-- THE EVIDENCE THAT MAKES THE POINT. Runs 7 and 8 are the same source file
-- (sha 68ceb3b783fc) before and after the duplicate-vs-conflict fix:
--
--   id 7   duplicates_in_source=187725                 rejected=0   output 4,085,772
--   id 8   duplicates_in_source=187724   conflicts=1   rejected=1   output 4,085,772
--
-- Identical output. The defect -- one row whose key matched another with a
-- DIFFERENT value, silently dropped as a duplicate -- moved exactly one count
-- from `duplicate` to `rejected`, and it is recorded only inside a free-text
-- `note`. Structured columns turn that into a diff a test can fail on.
--
-- After this migration the identity holds on every row and becomes an assertion:
--
--   rows_in_file = source_rows_accepted + rows_rejected + duplicate_rows
--
-- and output volume is separated from source volume, because a feed that fans
-- one source row into three metrics is not "accepting more rows than it read".
-- ─────────────────────────────────────────────────────────────────────────

ALTER TABLE ingest_runs
    ADD COLUMN IF NOT EXISTS source_rows_accepted INTEGER,
    ADD COLUMN IF NOT EXISTS duplicate_rows       INTEGER,
    ADD COLUMN IF NOT EXISTS synthesized_rows     INTEGER,
    ADD COLUMN IF NOT EXISTS output_rows_written  INTEGER;

COMMENT ON COLUMN ingest_runs.rows_in_file IS
    'Data rows present in the fetched artifact, before any filtering. NOT the '
    'number that survived: exclusions are counted in rows_rejected.';
COMMENT ON COLUMN ingest_runs.source_rows_accepted IS
    'Source rows that passed validation and contributed at least one output row.';
COMMENT ON COLUMN ingest_runs.duplicate_rows IS
    'Source rows dropped because an identical (key, value) was already seen. '
    'A row whose key matched but whose value DIFFERED is a conflict, not a '
    'duplicate, and is counted in rows_rejected.';
COMMENT ON COLUMN ingest_runs.synthesized_rows IS
    'Rows this loader created that were not in the source at all (e.g. the 5 '
    'derived 新竹市/嘉義市 district codes). Counted in output, never in source.';
COMMENT ON COLUMN ingest_runs.output_rows_written IS
    'Rows written to the target table. Differs from source_rows_accepted '
    'whenever one source row fans out into several metrics.';
COMMENT ON COLUMN ingest_runs.rows_accepted IS
    'DEPRECATED (008): unit varied by loader -- source rows, dimension rows or '
    'fact rows. Replaced by source_rows_accepted + output_rows_written. Kept '
    'for the contract phase; do not write to it in new code.';

-- Backfill. Every value below is derived from evidence recorded at load time
-- (the `note` column and the reference snapshot), not from an assumption.

-- Single-metric feeds: one source row in, one fact row out, no synthesis.
UPDATE ingest_runs SET
    source_rows_accepted = rows_accepted,
    duplicate_rows       = 0,
    synthesized_rows     = 0,
    output_rows_written  = rows_accepted
WHERE source IN ('cdc-rods', 'cdc-rods-ili', 'cdc-nhi-ili', 'cdc-tb-town');

-- Geography. The snapshot moi_admin_20260818.csv holds 8,258 data rows; 204 are
-- villages with an empty name (NLSC publishes them) and are excluded, which is
-- a rejection with a reason, not a smaller file. 5 derived district codes are
-- synthesised for 新竹市/嘉義市, which is why output exceeds input.
UPDATE ingest_runs SET
    rows_in_file         = 8258,
    source_rows_accepted = 8054,
    rows_rejected        = 204,
    duplicate_rows       = 0,
    synthesized_rows     = 5,
    output_rows_written  = 8059
WHERE source = 'moi-admin-geography';

-- CareMag run 7: before the duplicate-vs-conflict fix. The conflicting row was
-- counted as a duplicate, which is precisely the defect.
UPDATE ingest_runs SET
    source_rows_accepted = 1361924,
    duplicate_rows       = 187725,
    synthesized_rows     = 0,
    output_rows_written  = 4085772
WHERE source = 'cdc-tb-caremag' AND rows_rejected = 0;

-- CareMag run 8: after the fix. Same file, same output count, one row moved
-- from `duplicate` to `rejected`.
UPDATE ingest_runs SET
    source_rows_accepted = 1361924,
    duplicate_rows       = 187724,
    synthesized_rows     = 0,
    output_rows_written  = 4085772
WHERE source = 'cdc-tb-caremag' AND rows_rejected = 1;

-- NOT NULL and the accounting CHECK are deliberately NOT here. They belong to
-- 009, after the loaders are taught to write these columns. Applying them now
-- would break the very loaders whose output this table records: they INSERT
-- without the new columns, so a NOT NULL with no default rejects the write, and
-- the failure would surface as "ingestion broken" rather than "migration ran
-- too early". Expand, migrate the writers, then contract -- the same sequence
-- 003 -> 007 already paid for once.

-- ─────────────────────────────────────────────────────────────────────────
-- PART B -- THE DENOMINATOR
--
-- Every non-ILI feed on this platform is a count with no population base:
--
--   cdc-tb-town     denominator populated on      0 / 7,360 rows
--   cdc-tb-caremag  denominator populated on      0 / 4,085,772 rows
--   geo_area        has no population column at all
--
-- So township-level TB is reachable but a township-level RATE is not: 大甲區 3
-- cases against 西屯區 12 cases says nothing without knowing how many people
-- live in each. That is a missing denominator, not a missing granularity --
-- the granularity has been there since 006.
--
-- 內政部戶政司 publishes both at VILLAGE level under the same 11-digit codes
-- already loaded in geo_area (verified: ODRP019 district_code 65000010001 =
-- 新北市板橋區留侯里 = geo_area.geo_code 65000010001, exact match, no crosswalk).
--
-- WHY A SEPARATE TABLE. surveillance_fact.disease_id is NOT NULL and it should
-- stay that way -- population is not an observation of a disease. This table
-- mirrors its design exactly (same metric/geo/time dimensions, same NOT NULL
-- 'all' default for breakdown columns) so the two join without translation.
-- ─────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS demographic_fact (
    id             BIGSERIAL PRIMARY KEY,
    source_id      SMALLINT  NOT NULL REFERENCES data_source(source_id),
    metric_id      SMALLINT  NOT NULL REFERENCES metric(metric_id),
    geo_code       TEXT      NOT NULL REFERENCES geo_area(geo_code),
    period_id      BIGINT    NOT NULL REFERENCES time_period(period_id),
    -- Breakdown columns follow surveillance_fact's convention: NOT NULL with an
    -- explicit 'all' rather than NULL, so a total and an unknown never collide.
    sex            TEXT      NOT NULL DEFAULT 'all',
    household_type TEXT      NOT NULL DEFAULT 'all',
    edu_level      TEXT      NOT NULL DEFAULT 'all',
    value          BIGINT    NOT NULL CHECK (value >= 0),
    ingested_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT demographic_fact_natural UNIQUE
        (source_id, metric_id, geo_code, period_id, sex, household_type, edu_level)
);

CREATE INDEX IF NOT EXISTS demographic_geo_metric_time_idx
    ON demographic_fact (geo_code, metric_id, period_id);
CREATE INDEX IF NOT EXISTS demographic_source_idx
    ON demographic_fact (source_id, ingested_at DESC);

-- Population and households are LEVELS at a point in time, exactly like
-- 管理中個案數. measure_type carries that, so a query that sums population
-- across years has to first read the column telling it not to.
INSERT INTO metric (code, name_zh, measure_type, unit, notes) VALUES
    ('population', '人口數', 'stock', '人',
     '戶籍登記人口；某一時點的存量，不可沿時間加總'),
    ('households', '戶數', 'stock', '戶',
     '戶籍登記戶數；存量'),
    ('household_heads', '戶長人數', 'stock', '人',
     '依教育程度分的戶長數；存量。戶長是家戶代表，不是全人口，'
     '不可當作教育程度的人口分布')
ON CONFLICT (code) DO NOTHING;

-- Rate view. Rates are DERIVED, never stored: surveillance_fact.value is
-- INTEGER, and a stored rate would go stale the moment either side reloads.
-- Population is rolled up from village to whatever level the fact sits at.
CREATE OR REPLACE VIEW geo_population AS
WITH village AS (
    SELECT d.geo_code, d.period_id, d.value
    FROM demographic_fact d
    JOIN metric m ON m.metric_id = d.metric_id
    WHERE m.code = 'population'
      AND d.sex = 'all' AND d.household_type = 'all' AND d.edu_level = 'all'
)
SELECT g.geo_code, g.geo_level, v.period_id, SUM(v.value)::BIGINT AS population
FROM village v
JOIN geo_area src ON src.geo_code = v.geo_code
-- A village rolls up to itself, its township and its county. No level is
-- special-cased, so adding a level later needs no change here.
JOIN geo_area g ON g.geo_code IN (
        src.geo_code,
        src.parent_code,
        (SELECT parent_code FROM geo_area WHERE geo_code = src.parent_code))
GROUP BY g.geo_code, g.geo_level, v.period_id;

COMMENT ON VIEW geo_population IS
    'Population at every geographic level, rolled up from the village facts. '
    'Derived on read: storing a rolled-up total would go stale silently the '
    'next time either the boundary set or the population reload changes.';

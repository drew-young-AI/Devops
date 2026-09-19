-- 004: granularity-agnostic dimensional model.
--
-- EXPAND PHASE. New tables only; surveillance_observations (003) is untouched
-- and still serves the running colour. It becomes a source-specific landing
-- table feeding surveillance_fact, and is dropped only in a later CONTRACT
-- migration once nothing reads it.
--
-- WHY NOT JUST ADD township AND village COLUMNS.
--
-- The obvious move -- widen surveillance_observations with township, village
-- and a date -- fails on contact with the actual open data. Verified by
-- downloading every candidate:
--
--   RODS  (7 diseases)      county  x epi_week   2007-2026   no denominator
--   NHI   (8 diseases)      county  x epi_week   2016-2026   HAS denominator
--   TB    tb_town_inc_num   TOWNSHIP x YEAR      2005-2024   no denominator
--   NS1   ns1hosp           POINT (lat/long)     static registry
--
-- No dataset is fine in BOTH dimensions. Township data is annual; weekly data
-- is county-level. Widening the table would mean the township columns are
-- NULL for 99% of rows and the date column is NULL for all of them, which is
-- a wide sparse table pretending to be a model.
--
-- So granularity is DATA, not schema. geo_level and time_level say what a row
-- actually resolves to, and a village x day feed lands in the same table with
-- no migration at all.
--
-- MISSING IS NOT ZERO.
--
-- The absence of a row means "not reported". A row with value = 0 means
-- "reported, and it was zero". Collapsing them would make a reporting outage
-- look like an absence of disease -- the same failure this platform keeps
-- guarding against, in the data layer. Nothing here defaults a missing
-- observation to 0, and the fact table has no DEFAULT on `value`.

-- ── 地理維度：自我參照的階層 ──────────────────────────────────
--
-- parent_code lets a query roll township up to county without a join table
-- per level, and lets a village-level feed slot underneath an existing
-- township with no schema change.
CREATE TABLE IF NOT EXISTS geo_area (
    geo_code    TEXT PRIMARY KEY,
    geo_level   TEXT NOT NULL
                CHECK (geo_level IN ('country', 'county', 'township', 'village')),
    name        TEXT NOT NULL,
    parent_code TEXT REFERENCES geo_area(geo_code),
    -- Point geometry when the row IS a point (a clinic), NULL otherwise.
    -- Kept as plain numerics rather than PostGIS: the pilot needs to record
    -- coordinates, not do spatial joins, and adding an extension for two
    -- columns is a dependency this does not earn yet.
    latitude    DOUBLE PRECISION,
    longitude   DOUBLE PRECISION
);

CREATE INDEX IF NOT EXISTS geo_area_parent_idx ON geo_area (parent_code);
CREATE INDEX IF NOT EXISTS geo_area_level_idx  ON geo_area (geo_level);

-- ── 時間維度 ────────────────────────────────────────────────
--
-- One row per (time_level, period). epi_week rows carry epi_year/epi_week and
-- a NULL cal_date, because the calendar mapping is NOT established -- see
-- docs/Spark-Design.md: the data's 53-week years (2009, 2014, 2020, 2025)
-- match none of six standard conventions, and project rules forbid guessing a
-- mapping. cal_date stays NULL until CDC confirms the definition; a day-level
-- feed populates it directly and needs no conversion.
CREATE TABLE IF NOT EXISTS time_period (
    period_id   BIGSERIAL PRIMARY KEY,
    time_level  TEXT NOT NULL CHECK (time_level IN ('day', 'epi_week', 'year')),
    epi_year    SMALLINT,
    epi_week    SMALLINT CHECK (epi_week BETWEEN 1 AND 53),
    cal_date    DATE,
    -- Monotonic ordering across levels, so lag/lead window functions work
    -- without needing a calendar date. Assigned by the loader.
    seq         INTEGER NOT NULL,
    CONSTRAINT time_period_natural UNIQUE (time_level, epi_year, epi_week, cal_date)
);

CREATE INDEX IF NOT EXISTS time_period_seq_idx ON time_period (time_level, seq);

-- ── 疾病維度 ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS disease (
    disease_id  SMALLSERIAL PRIMARY KEY,
    code        TEXT NOT NULL UNIQUE,
    name_zh     TEXT NOT NULL,
    name_en     TEXT
);

-- ── 資料來源維度 ────────────────────────────────────────────
--
-- Carries the granularity CONTRACT of the feed. A consumer that joins two
-- sources can check here whether they are comparable, instead of discovering
-- at analysis time that one is annual and the other weekly.
CREATE TABLE IF NOT EXISTS data_source (
    source_id       SMALLSERIAL PRIMARY KEY,
    code            TEXT NOT NULL UNIQUE,
    name            TEXT NOT NULL,
    url             TEXT,
    spatial_level   TEXT NOT NULL
                    CHECK (spatial_level IN ('country','county','township','village','point')),
    temporal_level  TEXT NOT NULL CHECK (temporal_level IN ('day','epi_week','year','static')),
    has_denominator BOOLEAN NOT NULL DEFAULT FALSE,
    -- Synthetic feeds must be impossible to mistake for real ones.
    is_synthetic    BOOLEAN NOT NULL DEFAULT FALSE,
    notes           TEXT
);

-- ── 事實表 ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS surveillance_fact (
    id           BIGSERIAL PRIMARY KEY,
    source_id    SMALLINT NOT NULL REFERENCES data_source(source_id),
    disease_id   SMALLINT NOT NULL REFERENCES disease(disease_id),
    geo_code     TEXT     NOT NULL REFERENCES geo_area(geo_code),
    period_id    BIGINT   NOT NULL REFERENCES time_period(period_id),
    -- Age bands differ between sources (RODS has 5, NHI has 9, with
    -- incompatible cut points), so the band is stored verbatim as the source
    -- gives it. Harmonising at load time would destroy resolution
    -- irreversibly; it belongs downstream where it can be re-run.
    age_band     TEXT     NOT NULL DEFAULT 'all',
    visit_type   TEXT     NOT NULL DEFAULT 'all',
    -- No DEFAULT. A missing observation must be an absent row, never a zero.
    value        INTEGER  NOT NULL CHECK (value >= 0),
    -- NULL when the source publishes no denominator. NOT 0 -- dividing by a
    -- zero denominator and dividing by an unknown one are different errors.
    denominator  INTEGER  CHECK (denominator IS NULL OR denominator >= 0),
    ingested_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT surveillance_fact_natural UNIQUE
        (source_id, disease_id, geo_code, period_id, age_band, visit_type)
);

-- The forecasting query: one area, one disease, ordered in time.
CREATE INDEX IF NOT EXISTS fact_geo_time_idx
    ON surveillance_fact (geo_code, disease_id, period_id);
-- Cross-area comparison within a period (the outbreak scan).
CREATE INDEX IF NOT EXISTS fact_period_idx
    ON surveillance_fact (disease_id, period_id);
-- Source-scoped reload / audit.
CREATE INDEX IF NOT EXISTS fact_source_idx
    ON surveillance_fact (source_id, ingested_at DESC);

-- ── 便利檢視 ────────────────────────────────────────────────
--
-- Rate is computed here rather than stored: the denominator can be restated
-- upstream, and a stored rate would silently disagree with its own inputs
-- after a correction. NULLIF guards division by a genuine zero denominator.
CREATE OR REPLACE VIEW surveillance_rate AS
SELECT f.id, s.code AS source, d.code AS disease,
       g.geo_code, g.name AS area, g.geo_level,
       t.time_level, t.epi_year, t.epi_week, t.cal_date, t.seq,
       f.age_band, f.visit_type, f.value, f.denominator,
       CASE WHEN f.denominator IS NULL THEN NULL
            ELSE f.value::double precision / NULLIF(f.denominator, 0)
       END AS rate
FROM surveillance_fact f
JOIN data_source s ON s.source_id = f.source_id
JOIN disease     d ON d.disease_id = f.disease_id
JOIN geo_area    g ON g.geo_code = f.geo_code
JOIN time_period t ON t.period_id = f.period_id;

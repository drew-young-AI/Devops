-- CONTRACT-PHASE: this migration drops surveillance_fact's natural key and
-- truncates the fact and geography tables. Justified because (a) station2-twin
-- is the only reader and it is a pilot, (b) every affected row is derived data
-- rebuildable from the source CSVs by ingest/load_dimensional.py, and (c) the
-- old key is not merely inconvenient, it is WRONG -- see DEFECT 3 below. A
-- constraint that forbids correct data cannot be left in place while a second
-- colour serves, because the second colour would also be unable to write.
--
-- 006: adopt official MOI geography codes, and record what a number MEANS.
--
-- WHY THIS EXISTS. The pilot asked for the finest granularity in the data.
-- Re-surveying data.cdc.gov.tw (73 datasets, package_show on every one) found
-- one that is finer in BOTH dimensions than anything loaded so far:
--
--   tbdata001 / CareMag*  結核病每日縣市鄉鎮(區)管理中個案
--   TOWNSHIP x DAY, 2016-01-01 .. present, ~1.55M source rows
--
-- Loading it broke three assumptions at once.
--
-- ── DEFECT 3 -- THE FACT KEY ASSUMED ONE MEASUREMENT PER ROW ────────────────
--
-- The old key was
--   (source_id, disease_id, geo_code, period_id, age_band, visit_type)
-- which asserts: one (source, disease, place, time, age, visit type) yields at
-- most ONE number. That held only by accident -- every feed loaded so far
-- published a single count per row. The TB daily feed publishes three
-- different measurements per row (cases under management, confirmed cases,
-- MDR cases), so the second and third would have UPSERTed over the first.
--
-- Note the failure mode: no error, no constraint violation, a table that still
-- looks well-formed, and two thirds of the data gone. The same shape as every
-- other defect this pilot has found. `metric_id` joins the key.
--
-- ── STOCK IS NOT FLOW ───────────────────────────────────────────────────────
--
-- 管理中個案數 is a STOCK: how many people are under treatment on that date.
-- 就診人次 and 新案發生數 are FLOWS: events counted over an interval.
--
-- Summing a flow over time is meaningful (a year's visits). Summing a stock
-- over time is nonsense -- it counts the same patient once per day they remain
-- ill, and for TB that is 6-9 months, so a naive yearly SUM overstates by
-- roughly 200x. Nothing in the old schema recorded which kind a column was, so
-- nothing could stop that query from being written. `metric.measure_type`
-- makes the distinction a property of the data instead of tribal knowledge.
--
-- ── GEOGRAPHY NEEDS AN AUTHORITY, NOT A CONVENTION ──────────────────────────
--
-- Migration 005 fixed my invented `tw-台中市` county codes by resolving county
-- NAMES against the official codes that RODS/NHI happen to carry. That worked
-- for counties and left townships keyed as `66000-大甲區` -- still a derived
-- key, still mine, and still unable to join anything outside this database.
--
-- The authority is 內政部國土測繪中心 (api.nlsc.gov.tw), which publishes the
-- full three-level hierarchy: 22 counties, 368 townships, ~7,700 villages,
-- with the same 5-digit county codes RODS/NHI use. geo_area is now keyed on
-- those codes at every level.
--
-- VILLAGES ARE LOADED EVEN THOUGH NO FEED IS VILLAGE-LEVEL. The dimension
-- describes the country, not the feeds that happen to exist today; a village
-- feed lands with no schema change and no dimension backfill. This is the
-- claim migration 004 made about granularity, made good.

-- ── 名稱對照：來源怎麼寫，官方是誰 ──────────────────────────────────────────
--
-- Two CDC feeds from the same agency disagree about the same 368 townships.
-- Measured, not assumed:
--
--   中　區 vs 中區          ideographic space U+3000 padding (5 townships)
--   北  區 vs 北區          two ASCII spaces -- BOTH spellings in ONE feed
--   太麻里 vs 太麻里鄉      names truncated to 3 characters
--   員林鎮 vs 員林市        2015-08-08 改制, one feed never updated
--   金寧鎮 vs 金寧鄉        wrong administrative type in the source
--   舊中縣/豐原市           an entity abolished in 2010, one row, 2021-08-23
--
-- Fuzzy matching would resolve most of these and silently invent the rest.
-- Instead every non-exact mapping is DECLARED in ingest/crosswalk/geo_alias.csv
-- with a rule and a citable reason, loaded here, and applied by exact lookup.
-- A source name with no alias and no exact match is REJECTED, never guessed.
-- That is the project rule (数據對應必須有明確 evidence) expressed as a table.
CREATE TABLE IF NOT EXISTS geo_alias (
    source_code TEXT NOT NULL,
    -- The county name as the FEED writes it. '' for county-level aliases, so
    -- the primary key stays NOT NULL.
    raw_parent  TEXT NOT NULL DEFAULT '',
    raw_name    TEXT NOT NULL,
    geo_code    TEXT NOT NULL REFERENCES geo_area(geo_code),
    rule        TEXT NOT NULL CHECK (rule IN (
                    'whitespace',   -- padding only; normalisation is mechanical
                    'truncated',    -- source cut the name short; unique prefix
                    'renamed',      -- administrative rename, with a date
                    'wrong_type',   -- 鄉/鎮/市/區 wrong in the source
                    'historical')), -- entity no longer exists
    evidence    TEXT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (source_code, raw_parent, raw_name)
);

-- ── 度量維度 ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS metric (
    metric_id    SMALLSERIAL PRIMARY KEY,
    code         TEXT NOT NULL UNIQUE,
    name_zh      TEXT NOT NULL,
    -- flow  events counted over an interval    -- SUM over time is valid
    -- stock a level measured at an instant     -- SUM over time is nonsense
    -- rate  already a ratio                    -- neither sums nor averages
    measure_type TEXT NOT NULL CHECK (measure_type IN ('flow', 'stock', 'rate')),
    unit         TEXT NOT NULL,
    notes        TEXT
);

-- ── geo_area 記下代碼是誰發的 ───────────────────────────────────────────────
--
-- Without this, a future feed carrying some other code system produces rows
-- indistinguishable from official ones -- which is exactly how `tw-台中市`
-- survived long enough to break every roll-up in migration 005.
ALTER TABLE geo_area ADD COLUMN IF NOT EXISTS code_system TEXT NOT NULL DEFAULT 'moi';
ALTER TABLE geo_area DROP CONSTRAINT IF EXISTS geo_area_code_system_chk;
ALTER TABLE geo_area ADD CONSTRAINT geo_area_code_system_chk
    CHECK (code_system IN ('moi', 'derived'));

-- ── 事實表：加入度量，換掉錯的鍵 ────────────────────────────────────────────
--
-- Truncate rather than backfill. Every row is derived, the geography key
-- system is changing underneath it, and a backfill would have to invent a
-- metric for rows whose meaning was never recorded -- inventing the very thing
-- this migration exists to stop.
TRUNCATE surveillance_fact, geo_alias, geo_area RESTART IDENTITY CASCADE;

ALTER TABLE surveillance_fact
    ADD COLUMN IF NOT EXISTS metric_id SMALLINT NOT NULL REFERENCES metric(metric_id);

ALTER TABLE surveillance_fact DROP CONSTRAINT IF EXISTS surveillance_fact_natural;
ALTER TABLE surveillance_fact
    ADD CONSTRAINT surveillance_fact_natural
    UNIQUE NULLS NOT DISTINCT
    (source_id, disease_id, metric_id, geo_code, period_id, age_band, visit_type);

-- The forecasting query now selects a metric explicitly. An index that ignores
-- metric_id would scan three measurements to return one.
DROP INDEX IF EXISTS fact_geo_time_idx;
CREATE INDEX IF NOT EXISTS fact_geo_metric_time_idx
    ON surveillance_fact (geo_code, disease_id, metric_id, period_id);

-- ── 檢視：把度量語意帶出來 ──────────────────────────────────────────────────
--
-- measure_type is exposed so a consumer cannot sum a stock over time without
-- first reading the column that says not to.
--
-- DROP then CREATE, not CREATE OR REPLACE: replacing a view can only append
-- columns, and this one inserts metric/measure_type/unit in the middle.
-- Postgres refuses with "cannot change name of view column", which is the
-- correct refusal -- a positional consumer would silently start reading the
-- wrong column.
DROP VIEW IF EXISTS surveillance_rate;
CREATE VIEW surveillance_rate AS
SELECT f.id, s.code AS source, d.code AS disease,
       m.code AS metric, m.measure_type, m.unit,
       g.geo_code, g.name AS area, g.geo_level, g.parent_code,
       t.time_level, t.epi_year, t.epi_week, t.cal_date, t.seq,
       f.age_band, f.visit_type, f.value, f.denominator,
       CASE WHEN f.denominator IS NULL THEN NULL
            ELSE f.value::double precision / NULLIF(f.denominator, 0)
       END AS rate
FROM surveillance_fact f
JOIN data_source s ON s.source_id  = f.source_id
JOIN disease     d ON d.disease_id = f.disease_id
JOIN metric      m ON m.metric_id  = f.metric_id
JOIN geo_area    g ON g.geo_code   = f.geo_code
JOIN time_period t ON t.period_id  = f.period_id;

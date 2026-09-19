-- 003: public health surveillance -- the real workload.
--
-- EXPAND PHASE. Adds tables only; `observations` (the placeholder asset table
-- from 001) is left untouched and still readable by the running colour. Its
-- removal is a later CONTRACT migration, once no live code reads it. Doing
-- both in one step is exactly what the migration gate refuses, and the reason
-- is visible here: during the switch, the old colour is still serving.
--
-- SHAPE COMES FROM THE SOURCE, NOT FROM A GUESS.
--
-- Columns mirror Taiwan CDC's RODS extract verbatim
-- (od.cdc.gov.tw/eic/RODS_Influenza_like_illness.csv):
--   年 / 週 / 年齡別 / 縣市 / 類流感急診就診人次 / 縣市別代碼
-- 109,907 rows, 2007-W01 .. 2026-W32, 22 counties. Nothing is derived or
-- reinterpreted at ingest; transformation happens downstream where it can be
-- re-run, not at the boundary where it would be unrecoverable.

CREATE TABLE IF NOT EXISTS surveillance_observations (
    id           BIGSERIAL PRIMARY KEY,
    -- Which feed this came from. A twin that mixes sources without recording
    -- which is which cannot answer "why did the baseline move" later.
    source       TEXT    NOT NULL,
    disease      TEXT    NOT NULL,
    -- Both the code and the name. The code is the stable join key; the name
    -- is what a human reads in a report. Storing only the name would make
    -- every future rename a silent data migration.
    county_code  TEXT    NOT NULL,
    county       TEXT    NOT NULL,
    age_group    TEXT    NOT NULL,
    epi_year     SMALLINT NOT NULL,
    epi_week     SMALLINT NOT NULL,
    visits       INTEGER NOT NULL CHECK (visits >= 0),
    ingested_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- THE IDEMPOTENCY CONTRACT.
    --
    -- The CDC publishes a full history file every week, not a delta. Without
    -- this constraint, a second run silently doubles every count -- and the
    -- corruption is invisible, because the table still looks well-formed and
    -- the numbers are merely wrong. Re-running a pipeline must be safe; that
    -- is what makes it a pipeline rather than a one-off.
    CONSTRAINT surveillance_natural_key
        UNIQUE (source, disease, county_code, age_group, epi_year, epi_week)
);

-- The query the twin actually makes: one county, one disease, ordered in time.
CREATE INDEX IF NOT EXISTS surveillance_county_time_idx
    ON surveillance_observations (county_code, disease, epi_year, epi_week);

-- Same-week-across-years, which is how the seasonal baseline is computed.
CREATE INDEX IF NOT EXISTS surveillance_week_idx
    ON surveillance_observations (disease, epi_week, county_code);


-- Provenance. Every ingest leaves a record of WHERE the bytes came from and
-- WHAT they hashed to.
--
-- Without this, "the numbers changed" has no answer: you cannot tell a
-- genuine epidemiological shift from the source publishing a correction, and
-- you cannot reproduce last month's model input. The content digest is what
-- makes the difference between a data pipeline and a script that overwrites
-- a table.
CREATE TABLE IF NOT EXISTS ingest_runs (
    id              BIGSERIAL PRIMARY KEY,
    source          TEXT        NOT NULL,
    source_url      TEXT        NOT NULL,
    fetched_at      TIMESTAMPTZ NOT NULL,
    content_sha256  TEXT        NOT NULL,
    content_bytes   BIGINT      NOT NULL,
    rows_in_file    INTEGER     NOT NULL,
    rows_accepted   INTEGER     NOT NULL,
    rows_rejected   INTEGER     NOT NULL,
    rows_inserted   INTEGER     NOT NULL,
    rows_updated    INTEGER     NOT NULL,
    -- ok | rejected | failed. Rejected rows are counted, never silently
    -- dropped: a feed that starts emitting garbage must show up as a number
    -- going up, not as a quietly shorter table.
    status          TEXT        NOT NULL,
    note            TEXT
);

CREATE INDEX IF NOT EXISTS ingest_runs_source_time_idx
    ON ingest_runs (source, fetched_at DESC);

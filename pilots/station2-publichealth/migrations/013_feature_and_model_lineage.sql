-- 013: extend lineage past the fact table, into features and models.
--
-- THE GAP THIS CLOSES.
--
-- Provenance currently stops dead at surveillance_fact. ingest_runs records
-- source -> fact in checkable detail, and then nothing. A model trained
-- tomorrow could not answer which rows it saw, which code produced its
-- features, or whether the number it reports beat doing nothing at all.
--
-- That is the DataOps/MLOps discontinuity in one sentence: the data has an
-- audit trail and the model has a print statement.
--
--   source -> fact       ingest_runs        (008/009, identity CHECKed)
--   fact   -> feature    feature_set        (here)
--   feature-> model      model_run          (here)
--
-- ─────────────────────────────────────────────────────────────────────────
-- WHY FEATURES ARE COLUMNS AND NOT A jsonb BLOB.
--
-- A jsonb feature vector is the same key-value soup the star schema exists to
-- avoid: nothing can constrain it, nothing can index it usefully, and two
-- feature sets that differ can look identical. Explicit columns mean changing
-- the feature set requires a migration -- which is correct, because in a
-- forecasting system a changed feature set IS a schema change for the model,
-- and it should be reviewed like one. Feature drift that arrives silently is
-- the MLOps equivalent of a loader that stops loading a column.
--
-- WHAT IS DELIBERATELY *NOT* STORED HERE: seasonal_index.
--
-- The design document lists it as a feature: the historical median %ILI for
-- that epi-week. It is NOT a column in this table, on purpose. Computing it
-- over the whole series and then using it to predict part of that series is
-- the classic leak -- the backtest score comes out beautiful and the model
-- collapses in production. It must be recomputed inside each fold from that
-- fold's TRAINING window only, so it cannot be precomputed and cannot be
-- stored. Storing it would bake the leak into the schema.
--
-- Every column that IS here is strictly backward-looking from its own row, so
-- precomputing is safe. That property is asserted, not asserted-in-a-comment:
-- see the no-lookahead test, which rebuilds features over a truncated series
-- and requires the retained rows to be byte-identical.
-- ─────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS feature_set (
    feature_set_id  BIGSERIAL PRIMARY KEY,
    name            TEXT        NOT NULL,
    -- sha256 of the generating script. Two feature sets with the same name and
    -- different code are a different thing wearing the same label; this is what
    -- makes "rebuild and compare" meaningful.
    code_sha256     TEXT        NOT NULL,
    -- What the series IS. A feature set is always about one place, one disease
    -- and one visit type -- mixing them silently is an ecological fallacy
    -- waiting to be averaged.
    geo_code        TEXT        NOT NULL REFERENCES geo_area(geo_code),
    disease_id      SMALLINT    NOT NULL REFERENCES disease(disease_id),
    visit_type      TEXT        NOT NULL,
    target          TEXT        NOT NULL,
    n_rows          INTEGER     NOT NULL CHECK (n_rows >= 0),
    seq_min         INTEGER     NOT NULL,
    seq_max         INTEGER     NOT NULL,
    params          JSONB       NOT NULL DEFAULT '{}'::jsonb,
    built_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT feature_set_span CHECK (seq_max >= seq_min),
    CONSTRAINT feature_set_natural UNIQUE
        (name, code_sha256, geo_code, disease_id, visit_type, seq_min, seq_max)
);

CREATE TABLE IF NOT EXISTS feature_row (
    feature_set_id      BIGINT   NOT NULL REFERENCES feature_set(feature_set_id)
                                 ON DELETE CASCADE,
    seq                 INTEGER  NOT NULL,
    epi_year            SMALLINT NOT NULL,
    epi_week            SMALLINT NOT NULL,

    -- Target: %ILI as a fraction, not a count. The denominator drifts (visits
    -- rise at new year, fall in a pandemic), so a raw count confuses "more
    -- people are ill" with "more people went to a doctor".
    y                   DOUBLE PRECISION,
    y_next_1            DOUBLE PRECISION,   -- label for the t+1 horizon
    y_next_2            DOUBLE PRECISION,   -- label for the t+2 horizon

    -- All strictly backward-looking from this row.
    lag_1               DOUBLE PRECISION,
    lag_2               DOUBLE PRECISION,
    lag_3               DOUBLE PRECISION,
    lag_4               DOUBLE PRECISION,
    delta_1             DOUBLE PRECISION,   -- lag_1 - lag_2, recent slope
    same_week_last_year DOUBLE PRECISION,
    week_of_year        SMALLINT,
    denominator_lag_1   BIGINT,             -- care-seeking behaviour proxy
    covid_lag_1         DOUBLE PRECISION,   -- cross-disease interference
    entero_lag_1        DOUBLE PRECISION,
    age_share_0_6_lag_1 DOUBLE PRECISION,   -- school-cluster early signal

    PRIMARY KEY (feature_set_id, seq)
);

CREATE INDEX IF NOT EXISTS feature_row_seq_idx ON feature_row (feature_set_id, seq);

-- ─────────────────────────────────────────────────────────────────────────
-- MODEL RUNS.
--
-- split_strategy is stored as DATA, not chosen in code and forgotten, because
-- the whole point is to keep both answers side by side. A random split on a
-- time series leaks the future into training and produces a flattering score
-- that means nothing. The design document asks for that mistake to be made
-- once, deliberately, and recorded next to the honest number -- it is the most
-- common error in applied forecasting and the hardest to see from the result.
--
-- beats_baselines is GENERATED, not a boolean someone sets. A model is only
-- interesting if it beats both doing nothing (persistence) and last year
-- (seasonal naive). Letting a human write `true` into that column is how a
-- model with a worse MAE than persistence ends up in a slide deck.
-- ─────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS model_run (
    model_run_id    BIGSERIAL PRIMARY KEY,
    feature_set_id  BIGINT      NOT NULL REFERENCES feature_set(feature_set_id),
    algorithm       TEXT        NOT NULL,
    hyperparams     JSONB       NOT NULL DEFAULT '{}'::jsonb,
    seed            INTEGER     NOT NULL,
    split_strategy  TEXT        NOT NULL
                    CHECK (split_strategy IN ('rolling_origin', 'random')),
    horizon_weeks   SMALLINT    NOT NULL CHECK (horizon_weeks IN (1, 2)),
    n_train         INTEGER     NOT NULL,
    n_test          INTEGER     NOT NULL,

    mae                 DOUBLE PRECISION NOT NULL,
    mape                DOUBLE PRECISION,
    direction_accuracy  DOUBLE PRECISION,

    -- The two naive baselines, on the SAME folds. Stored per run rather than
    -- computed once, because a baseline evaluated on different folds is not a
    -- comparison, and that mismatch is invisible in a single reported number.
    baseline_persistence_mae DOUBLE PRECISION NOT NULL,
    baseline_seasonal_mae    DOUBLE PRECISION,

    beats_baselines BOOLEAN GENERATED ALWAYS AS (
        mae < baseline_persistence_mae
        AND (baseline_seasonal_mae IS NULL OR mae < baseline_seasonal_mae)
    ) STORED,

    code_sha256     TEXT        NOT NULL,
    notes           TEXT,
    trained_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS model_run_feature_idx
    ON model_run (feature_set_id, horizon_weeks, split_strategy);

COMMENT ON COLUMN model_run.split_strategy IS
    'rolling_origin is the honest evaluation. random is kept so the inflated '
    'score from a random split on a time series can be shown next to it; it is '
    'never a valid result on its own.';
COMMENT ON COLUMN model_run.beats_baselines IS
    'GENERATED. A model that does not beat persistence AND seasonal-naive on '
    'the same folds is not a model, and nobody gets to type true here.';

-- Everything above must be reachable by the Vault-issued credentials, and the
-- ALTER DEFAULT PRIVILEGES from migration 010 handles that automatically for
-- tables created by this role -- which is exactly the failure 010 was written
-- for, now exercised by a migration that adds three tables at once.

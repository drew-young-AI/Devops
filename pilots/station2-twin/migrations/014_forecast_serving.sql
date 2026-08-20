-- 014: publish forecasts, and refuse to publish a model that lost.
--
-- THE GAP THIS CLOSES.
--
-- model_run records four evaluations and nothing can consume them. The service
-- has no forecast endpoint; the numbers exist only in a table nobody reads. The
-- MLOps→DevOps half of the loop is open: a model that is trained, evaluated and
-- never served is a research artefact, not a system.
--
-- WHY FORECASTS ARE STORED AND NOT COMPUTED ON REQUEST.
--
-- The obvious design is to load the fitted model in the API process and predict
-- per request. Rejected for two specific reasons:
--
--   1. It would put a pickled estimator in the serving path. Unpickling is
--      arbitrary code execution, the API is the most exposed component here,
--      and the pickle would additionally break on any scikit-learn upgrade --
--      silently producing different numbers rather than an error.
--   2. It would put numpy and scikit-learn in the API image, roughly tripling
--      it and widening the attack surface of the one container that answers
--      network requests, for a series that changes once a week.
--
-- So the batch container computes, this table holds the answer, and the API
-- only ever does a SELECT. The serving process never deserialises anything.
--
-- THE GATE.
--
-- A forecast row can only reference a model_run whose beats_baselines is true.
-- That is enforced by a TRIGGER, not by the publisher script being careful:
--
--   * beats_baselines is itself a GENERATED column, so it cannot be set by hand
--   * the trigger means a second publisher, written later by someone who never
--     read the first, still cannot publish a losing model
--
-- This is the same shape as the readiness schema gate. That gate turned "code
-- and schema disagree" from an incident into a deploy that never takes traffic.
-- This one turns "the model is worse than assuming next week equals this week"
-- from a slide into an INSERT that fails.
--
-- It has teeth right now, which is the point: of the four recorded runs, three
-- have beats_baselines = false. The h=1 model CANNOT be published, and that is
-- the system working, not a blocker to route around.

CREATE TABLE IF NOT EXISTS forecast (
    forecast_id   BIGSERIAL PRIMARY KEY,
    model_run_id  BIGINT      NOT NULL REFERENCES model_run(model_run_id),
    geo_code      TEXT        NOT NULL REFERENCES geo_area(geo_code),
    disease_id    SMALLINT    NOT NULL REFERENCES disease(disease_id),
    visit_type    TEXT        NOT NULL,

    -- The week being forecast, labelled the way the SOURCE labels it. No
    -- calendar date: the epi-week convention is still unconfirmed with 疾管署,
    -- and inventing a date here would be the platform asserting something it
    -- does not know, in the one artefact a clinician would actually read.
    target_epi_year SMALLINT  NOT NULL,
    target_epi_week SMALLINT  NOT NULL CHECK (target_epi_week BETWEEN 1 AND 53),
    horizon_weeks   SMALLINT  NOT NULL CHECK (horizon_weeks IN (1, 2)),

    -- What the forecast was made FROM. Without this a stale forecast is
    -- indistinguishable from a current one.
    origin_epi_year SMALLINT  NOT NULL,
    origin_epi_week SMALLINT  NOT NULL,
    observed_at_origin DOUBLE PRECISION,

    predicted_value DOUBLE PRECISION NOT NULL CHECK (predicted_value >= 0),

    -- Carried onto the row so a consumer reading one forecast can see how the
    -- model scored WITHOUT a join it might forget to write. Duplication is
    -- deliberate and safe: the trigger copies it from model_run at insert time,
    -- so it cannot drift.
    baseline_persistence_mae DOUBLE PRECISION NOT NULL,
    backtest_mae             DOUBLE PRECISION NOT NULL,

    generated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT forecast_natural UNIQUE
        (geo_code, disease_id, visit_type, target_epi_year, target_epi_week,
         horizon_weeks)
);

CREATE INDEX IF NOT EXISTS forecast_lookup_idx
    ON forecast (geo_code, disease_id, visit_type, generated_at DESC);

CREATE OR REPLACE FUNCTION forecast_requires_a_winning_model()
RETURNS TRIGGER AS $$
DECLARE
    mr RECORD;
BEGIN
    SELECT beats_baselines, split_strategy, mae, baseline_persistence_mae,
           horizon_weeks
      INTO mr
      FROM model_run WHERE model_run_id = NEW.model_run_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'model_run % does not exist', NEW.model_run_id;
    END IF;

    -- A random split is not an evaluation. It is kept in model_run only so the
    -- inflated number can sit beside the honest one; publishing from it would
    -- be publishing the leak.
    IF mr.split_strategy <> 'rolling_origin' THEN
        RAISE EXCEPTION
            'model_run % used split_strategy=%, which is not a valid '
            'evaluation. Only rolling_origin may be published.',
            NEW.model_run_id, mr.split_strategy;
    END IF;

    IF NOT mr.beats_baselines THEN
        RAISE EXCEPTION
            'model_run % does not beat its baselines (MAE % vs persistence %), '
            'so it must not be served. A model worse than assuming next week '
            'equals this week is not a model.',
            NEW.model_run_id, mr.mae, mr.baseline_persistence_mae;
    END IF;

    IF mr.horizon_weeks <> NEW.horizon_weeks THEN
        RAISE EXCEPTION
            'horizon mismatch: forecast says t+%, model_run % was evaluated at '
            't+%. Serving a horizon the model was never scored at is worse than '
            'serving nothing.',
            NEW.horizon_weeks, NEW.model_run_id, mr.horizon_weeks;
    END IF;

    -- Copied, not trusted to the caller: a publisher that passed its own
    -- numbers could report a score the model never achieved.
    NEW.backtest_mae := mr.mae;
    NEW.baseline_persistence_mae := mr.baseline_persistence_mae;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS forecast_gate ON forecast;
CREATE TRIGGER forecast_gate
    BEFORE INSERT OR UPDATE ON forecast
    FOR EACH ROW EXECUTE FUNCTION forecast_requires_a_winning_model();

COMMENT ON TABLE forecast IS
    'Precomputed forecasts. The API only SELECTs from here -- it never loads a '
    'model, so no estimator is ever deserialised in the serving path. The '
    'forecast_gate trigger refuses any row whose model_run lost to its '
    'baselines or was evaluated on a random split.';

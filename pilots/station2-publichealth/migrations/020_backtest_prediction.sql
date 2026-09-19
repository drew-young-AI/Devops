-- 020: the per-origin predictions a rolling-origin backtest already computes
-- and then threw away.
--
-- WHAT WAS MISSING AND WHY IT MATTERS (2026-09-19).
--
-- `model_run` stores one row per backtest: MAE, direction accuracy, whether it
-- beat the baselines. That answers "is this model better than the naive one, on
-- average, over the whole history". It cannot answer the question a public
-- health reader actually asks:
--
--     "Take the week before the 2026 wave started. What would this model have
--      told us, and what actually happened?"
--
-- `run_rolling()` computes exactly that for every origin week -- prediction,
-- actual, persistence baseline -- and then reduces it all to four numbers and
-- drops the rest on the floor. Recomputing it on demand is not an option worth
-- taking either: it needs the training loop, which is minutes, not a dashboard
-- refresh.
--
-- So the grid is precomputed and stored. A dashboard then filters it by origin
-- with a template variable, which is a query, not an execution -- Grafana has
-- no write path and is not being given one.
--
-- THE RULE THIS TABLE EXISTS UNDER. Every origin is stored, never a subset.
-- Storing "the interesting ones" is how a backtest becomes a slide: a reader
-- who can pick the origin can pick the origin that flatters the model, and
-- nothing in the data would show that a choice was made. The dashboard built
-- on this table must draw the whole distribution and highlight the selection
-- inside it.

CREATE TABLE IF NOT EXISTS backtest_prediction (
    backtest_prediction_id  bigserial PRIMARY KEY,
    model_run_id            bigint      NOT NULL
                                REFERENCES model_run(model_run_id) ON DELETE CASCADE,

    -- The week the forecast is MADE FROM. Everything the model saw is at or
    -- before this week; that is the guarantee rolling-origin exists to give.
    origin_epi_year         smallint    NOT NULL,
    origin_epi_week         smallint    NOT NULL,
    -- The week the forecast is ABOUT. Derived, stored, because a reader
    -- filtering by "which week are we predicting" should not have to redo
    -- epi-week arithmetic, which is exactly the arithmetic that has its own
    -- crosswalk table (migration 019) because it is not obvious.
    target_epi_year         smallint    NOT NULL,
    target_epi_week         smallint    NOT NULL,
    horizon_weeks           smallint    NOT NULL CHECK (horizon_weeks > 0),

    predicted_value         double precision NOT NULL,
    -- The truth. NOT NULL: a rolling-origin fold only exists when the label is
    -- known, so a row without an actual is a row that should not have been
    -- written. Future-dated forecasts live in `forecast`, not here.
    actual_value            double precision NOT NULL,
    -- "Next week is the same as this week". The whole gate is a comparison
    -- against this number, so it is stored beside the prediction rather than
    -- recomputed by whoever reads the table.
    persistence_value       double precision NOT NULL,
    -- Same week last year. NULL when the training fold had never seen that
    -- week -- filling it would invent information the fold did not have.
    seasonal_value          double precision,

    created_at              timestamptz NOT NULL DEFAULT now(),

    -- One prediction per (run, origin, horizon). A second row for the same
    -- fold means the writer ran twice and the reader would silently average
    -- two identical runs into a "sample" of two.
    CONSTRAINT backtest_prediction_fold UNIQUE
        (model_run_id, origin_epi_year, origin_epi_week, horizon_weeks)
);

-- The dashboard's access pattern: "this run, ordered by origin".
CREATE INDEX IF NOT EXISTS backtest_prediction_run_origin_idx
    ON backtest_prediction (model_run_id, origin_epi_year, origin_epi_week);

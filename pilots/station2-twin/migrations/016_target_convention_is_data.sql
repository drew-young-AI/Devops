-- 016: the target convention stops being prose.
--
-- WHAT WAS WRONG.
--
-- backtest.py can model the LEVEL (y_next) or the CHANGE (y_next - y). Which
-- one a run used decided what its MAE means and what a refit has to reproduce
-- -- and it was recorded only inside `notes`, in English, at the end of a
-- sentence: "target = level" / "target = change from last observed week".
--
-- publish_forecast.py refits from scratch before publishing. It never read
-- notes. It assumed the change convention, unconditionally. Today every
-- publishable run happens to be a change run, so no published number is wrong
-- -- but model_run 3 is a level run, and the moment a level run had won its
-- horizon the publisher would have refit it as a change model and published a
-- forecast that no evaluation in the database covered. Nothing would have
-- looked unusual: the forecast row would carry a real model_run_id and a real
-- backtest MAE, both belonging to a model that was never the one that ran.
--
-- WHAT THIS DOES.
--
-- Moves the convention into hyperparams, where the publisher already looks,
-- and makes its absence impossible rather than merely discouraged.
--
--   1. backfill every existing row from the text it was recorded in
--   2. CHECK the key exists, so a future writer cannot omit it
--
-- Note on the backfill: it derives from `notes` because that is where the fact
-- genuinely is. That is a one-time read of prose, done here under review, and
-- not a parser anything keeps running -- which is the difference between a
-- migration and a dependency on prose.

UPDATE model_run
   SET hyperparams = hyperparams || jsonb_build_object(
         'predict_delta',
         CASE WHEN notes LIKE '%target = change%' THEN true ELSE false END)
 WHERE NOT (hyperparams ? 'predict_delta');

-- random-split runs never used the change convention (run_random_split fits
-- the level regardless), and the CASE above already lands them on false --
-- their notes carry the DELIBERATE LEAK text, not a target marker. Asserted
-- rather than assumed:
DO $$
DECLARE bad INTEGER;
BEGIN
    SELECT count(*) INTO bad FROM model_run
     WHERE split_strategy = 'random'
       AND (hyperparams ->> 'predict_delta')::boolean IS DISTINCT FROM false;
    IF bad > 0 THEN
        RAISE EXCEPTION 'backfill put predict_delta=true on % random-split '
                        'run(s); random splits fit the level', bad;
    END IF;
END $$;

-- The teeth. Not a NOT NULL on a new column (that would be a contract-phase
-- change against a shared blob); a CHECK on the JSONB, which is satisfied by
-- every row after the backfill above and refuses every future row that omits
-- it. The only writer of model_run is the batch container, which is not
-- blue/green, so there is no older colour to break.
ALTER TABLE model_run
    ADD CONSTRAINT model_run_declares_target_convention
    CHECK (hyperparams ? 'predict_delta');

COMMENT ON COLUMN model_run.hyperparams IS
    'Constructor arguments for the registered algorithm, plus the run '
    'configuration that changes what the score MEANS: min_train and '
    'predict_delta. A refit that does not reproduce both is not a refit of '
    'this run. predict_delta is enforced present by CHECK.';

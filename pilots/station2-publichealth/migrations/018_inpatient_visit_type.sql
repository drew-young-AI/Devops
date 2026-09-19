-- 018: the other visit type, added because 017 was written before the data
-- was checked.
--
-- 017 added `er_lag_1` on the reasoning that emergency attendance leads
-- outpatient attendance for the same wave. That reasoning still holds, and it
-- is incomplete: measured after 017 was applied,
--
--   influenza_like_illness   住院 / 急診 / 門診
--   influenza                住院 / 門診          <- no emergency series at all
--   acute_uri                住院 / 門診
--   other_pneumonia          住院 / 門診
--   covid19                  住院 / 急診 / 門診
--
-- so the moment the target disease became a parameter -- which is the whole
-- point of this round -- `er_lag_1` became 100% NULL for four of the five
-- diseases that could be a target. A column that is always NULL for most of
-- its intended uses is not a feature, it is a column.
--
-- 住院 (inpatient) is the other half of the same dimension and exists for
-- every disease here. It is not a substitute for 急診: emergency is a TIMING
-- signal (people arrive earlier), inpatient is a SEVERITY signal (people are
-- admitted). Both are visit type, and a model given both can tell "more cases"
-- from "worse cases", which a single outpatient rate cannot.
--
-- WHY A SECOND MIGRATION AND NOT AN EDIT TO 017.
-- 017 is applied and its checksum is recorded. Editing an applied migration
-- makes the recorded history disagree with the file, which is the one thing a
-- migration table exists to prevent. The correction is a new migration and the
-- reason for it belongs in the record -- including that it was written before
-- the data was checked.

ALTER TABLE feature_row
    ADD COLUMN IF NOT EXISTS inpatient_lag_1 DOUBLE PRECISION;

COMMENT ON COLUMN feature_row.inpatient_lag_1 IS
  'Same disease/geo at the inpatient visit type, lag 1. A severity signal, where er_lag_1 is a timing signal.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_name = 'feature_row'
                     AND column_name = 'inpatient_lag_1') THEN
        RAISE EXCEPTION 'migration 018 did not create inpatient_lag_1';
    END IF;
END $$;

-- 017: the three dimensions the schema already had and the features did not.
--
-- WHAT WAS ALREADY TRUE BEFORE THIS MIGRATION.
--
-- `feature_set` has carried geo_code, disease_id and visit_type since 013.
-- The schema has therefore always said "many feature sets, across
-- geographies, diseases and visit types". `build_features.py` built exactly
-- one: 台中市 / 門診 / influenza_like_illness, with two other diseases as
-- covariates. That is this repo's own catalogued shape -- 登記為可擴充，
-- 但只實作了一種 -- one level above the model registry, which had the same
-- shape and was fixed on 2026-09-08.
--
-- The warehouse holds 6.53M surveillance facts across 14 diseases, 22-368
-- geographies and up to 3 visit types. The modelling table holds ~556 rows
-- built from one slice of that. Every "why not a bigger model" conversation
-- has ended at the 556, and the 556 is a consequence of the slice, not of the
-- data.
--
-- WHAT THIS ADDS, AND WHY EACH ONE IS A DIMENSION AND NOT JUST A COLUMN.
--
--   er_lag_1        the SAME disease and geography at the emergency-department
--                   visit type. VISIT TYPE as signal: ER attendance moves
--                   before outpatient attendance for the same wave, so this is
--                   the one feature here with a mechanical reason to lead.
--   national_lag_1  the same disease and visit type aggregated over EVERY
--                   geography. GEOGRAPHY as context: an epidemic arriving
--                   nationally is visible before it is visible in one city.
--   geo_share_lag_1 this geography's rate divided by the national rate.
--                   GEOGRAPHY as position: whether this city runs hot or cold
--                   relative to the country, which a level feature cannot say.
--   uri_lag_1       acute upper-respiratory infection, same geo and visit type.
--   pneumonia_lag_1 other pneumonia, same geo and visit type.
--                   DISEASE as co-signal, extending the covid/entero pair that
--                   013 already established.
--
-- ALL NULLABLE, NO BACKFILL, NO DEFAULT. Additive columns only: an existing
-- feature_set keeps every row it had and reads NULL for the new columns, and
-- the model already treats NULL as NaN by design (imputing a mean would invent
-- data; imputing 0 would place a fabricated trough in a series whose troughs
-- are the signal). Nothing in the app reads feature_row, so this is an
-- EXPAND-only step with no contract phase to schedule.
--
-- Two of the five are only available from 2016 (acute_uri and other_pneumonia
-- start then; covid_lag_1 already has this shape and is populated for 268 of
-- 556 weeks). A feature that is absent for early folds is not a defect here --
-- it is the honest state of the source, and the estimators are NaN-aware.

ALTER TABLE feature_row
    ADD COLUMN IF NOT EXISTS er_lag_1        DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS national_lag_1  DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS geo_share_lag_1 DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS uri_lag_1       DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS pneumonia_lag_1 DOUBLE PRECISION;

-- The covariate list is now a PARAMETER of the feature set, not a constant in
-- the builder, because the target disease is now a parameter too and a
-- covariate must never include the target. Recording it makes a feature set
-- self-describing: "which columns were meant to be populated" is otherwise
-- indistinguishable from "which columns happened to be NULL".
COMMENT ON COLUMN feature_row.er_lag_1 IS
  'Same disease/geo at the emergency visit type, lag 1. NULL when that visit type does not exist for the disease.';
COMMENT ON COLUMN feature_row.national_lag_1 IS
  'Same disease/visit type summed over all geographies, lag 1.';
COMMENT ON COLUMN feature_row.geo_share_lag_1 IS
  'This geography rate / national rate at lag 1. NULL when the national rate is 0 or missing.';

DO $$
DECLARE missing text;
BEGIN
    SELECT string_agg(c, ', ') INTO missing
    FROM unnest(ARRAY['er_lag_1', 'national_lag_1', 'geo_share_lag_1',
                      'uri_lag_1', 'pneumonia_lag_1']) AS c
    WHERE NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'feature_row' AND column_name = c);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'migration 017 did not create: %', missing;
    END IF;
END $$;

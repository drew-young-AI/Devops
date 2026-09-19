-- CONTRACT-PHASE: station2-twin is the only reader, it is a pilot, and every
-- row affected is derived data reloadable from the source CSVs in ~60s. No
-- live colour depends on the old shape because the old shape is wrong.
--
-- 005: fix two dimension-key defects found by loading real data.
--
-- DEFECT 1 -- NULL IN A UNIQUE CONSTRAINT NEVER MATCHES.
--
--   UNIQUE (time_level, epi_year, epi_week, cal_date)
--
-- Week-level rows carry cal_date = NULL, because the calendar mapping is not
-- established (see docs/Spark-Design.md). In SQL, NULL is not equal to NULL,
-- so this constraint never fired: every ON CONFLICT missed and every insert
-- created a NEW period row. time_period reached 110,931 rows where ~1,050
-- were expected, and (2026, W32) existed 108 times.
--
-- The damage then propagated: surveillance_fact's natural key includes
-- period_id, so facts pointing at different duplicate periods did not
-- conflict either, and RODS loaded 219,814 rows from a 109,907-row source --
-- exactly double, silently, with no error at any layer.
--
-- This is the same shape as everything else this platform keeps finding: the
-- check was present, looked correct, and did nothing. PostgreSQL 15 added
-- NULLS NOT DISTINCT for precisely this case.
--
-- DEFECT 2 -- I INVENTED A SECOND COUNTY CODE SYSTEM.
--
-- RODS and NHI carry the official 縣市別代碼 (66000 = 台中市). The TB feed has
-- no code column, so the loader minted `tw-台中市`. Result: every county
-- existed twice under two key systems, 44 rows for 22 counties, and township
-- data could not roll up to the weekly county series at all -- which was the
-- entire point of the geographic hierarchy.
--
-- The fix is in the loader (resolve the name against the official codes, and
-- REJECT a name that does not resolve rather than invent a key). This
-- migration only clears the bad rows so the reload lands clean.

-- Derived data. Truncating is correct here and cheaper than de-duplicating
-- something that should never have existed; CASCADE follows the FKs rather
-- than requiring a hand-ordered delete.
TRUNCATE surveillance_fact, time_period, geo_area RESTART IDENTITY CASCADE;

ALTER TABLE time_period DROP CONSTRAINT IF EXISTS time_period_natural;

-- NULLS NOT DISTINCT: two rows with the same (level, year, week) and both
-- cal_date NULL are now genuinely equal, so ON CONFLICT fires and the period
-- is created once.
ALTER TABLE time_period
    ADD CONSTRAINT time_period_natural
    UNIQUE NULLS NOT DISTINCT (time_level, epi_year, epi_week, cal_date);

-- Same hazard, same fix: age_band and visit_type are NOT NULL with defaults
-- today, but denominator-bearing feeds could later add a nullable dimension
-- to this key. Making the intent explicit now costs nothing.
ALTER TABLE surveillance_fact DROP CONSTRAINT IF EXISTS surveillance_fact_natural;
ALTER TABLE surveillance_fact
    ADD CONSTRAINT surveillance_fact_natural
    UNIQUE NULLS NOT DISTINCT
    (source_id, disease_id, geo_code, period_id, age_band, visit_type);

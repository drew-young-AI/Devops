-- 019: the day-to-epidemiological-week crosswalk, in its OWN table.
--
-- WHY NOT ON time_period, WHICH IS WHERE IT WAS FIRST PUT (2026-09-13).
--
-- `time_period` already carries epi_year and epi_week, and filling them in on
-- the `day` rows looked like the obvious way to make daily and weekly facts
-- joinable. It is not, because those two columns are part of the row's
-- identity:
--
--   time_period_natural  UNIQUE NULLS NOT DISTINCT
--                        (time_level, epi_year, epi_week, cal_date)
--
-- A day row's natural key is (day, NULL, NULL, <date>). Writing a week label
-- into it changes that key, so `load_dimensional.py`'s
-- `INSERT ... ON CONFLICT (time_level, epi_year, epi_week, cal_date)` no longer
-- matched the existing row and inserted a second one. One ingest run took day
-- periods from 3,885 to 7,777 and day facts from 4.1M to 8.2M, and the next
-- run of the labelling job then failed on the unique constraint it had itself
-- made unsatisfiable. Measured, rolled back, and the job removed.
--
-- The mapping is reference data about the CALENDAR, not an attribute of a
-- period row. Here it cannot collide with anything's identity, and the join
-- daily -> weekly is time_period.cal_date -> epi_calendar.cal_date ->
-- (epi_year, epi_week).
--
-- SOURCE: 疾管署 publish the crosswalk themselves --
--   https://nidss.cdc.gov.tw/config/DIM_CAL.csv
-- It is NOT derivable by arithmetic. Their own FAQ says week 1 is the week
-- containing 1/4 with weeks running Sunday..Saturday; that rule reproduces
-- their table from 2010 onward and contradicts it for 2007-2009, where weeks
-- were truncated at the calendar boundary (2009 week 01 is Jan 1-3, three
-- days, and week 02 starts Jan 4). Six weeks in the file are not seven days
-- long. A computed implementation would be silently wrong for three years.

CREATE TABLE IF NOT EXISTS epi_calendar (
    cal_date  date     PRIMARY KEY,
    epi_year  smallint NOT NULL,
    epi_week  smallint NOT NULL CHECK (epi_week BETWEEN 1 AND 53),
    -- Which snapshot of DIM_CAL.csv this row came from. The file is extended
    -- every year; without provenance a stale calendar is indistinguishable
    -- from a current one.
    source    text     NOT NULL DEFAULT 'nidss.cdc.gov.tw/config/DIM_CAL.csv'
);

CREATE INDEX IF NOT EXISTS epi_calendar_year_week
    ON epi_calendar (epi_year, epi_week);

COMMENT ON TABLE epi_calendar IS
  '疾管署日↔流行病學週對照表。查表，不可用算式推導：2007-2009 的週被截在跨年處，'
  '任何「週日起算、第1週含1/4」的算式都會把那三年整年平移。';

-- CONTRACT-PHASE: renames one metric code and updates the application with it.
--
-- 015: finish what 012 started, for the RODS family.
--
-- Migration 012 fixed this for NHI: `ili_visits` became `nhi_visits`, because
-- the fact table already carries disease_id and encoding the disease twice
-- permits rows nothing can reject (metric=covid_visits AND disease=enterovirus).
--
-- RODS had the identical defect and was deliberately LEFT ALONE, recorded in
-- docs/Backlog.md §8. The reason was specific: the application reads
-- `ili_ed_visits` in surveillance.py's MODELS registry, so this is an
-- application change, not a data change, and doing it silently as part of a
-- data migration would have been the half-done version.
--
-- It is done now, together with the application, in one commit.
--
-- WHY THE RENAME IS SAFE, RESTATED FOR THIS CASE.
--
--   * metric_id is unchanged. This is an UPDATE of one dimension row; not one
--     of the 109,907 RODS fact rows moves or is rewritten.
--   * The ONE application reference is updated in the same commit
--     (app/surveillance.py MODELS -> "rods_ed_visits").
--   * blue/green has no target pilot, so no second colour serves the old name.
--
-- WHAT THIS UNBLOCKS: the six unloaded RODS feeds (acute diarrhea,
-- conjunctivitis, COVID-19, enterovirus, hand-foot-mouth, herpangina). They were
-- held back rather than loaded into a shape known to be wrong -- loading first
-- and renaming after would have meant rewriting seven feeds' worth of rows.

UPDATE metric
SET code    = 'rods_ed_visits',
    name_zh = '急診就診人次',
    notes   = 'RODS 急診症候群監測；期間內的事件計數，可沿時間加總。'
              '疾病由 disease_id 表示，不重複編碼在 metric 裡 —— 與 nhi_visits '
              '同一個道理，見 migration 012。RODS 無分母。'
WHERE code = 'ili_ed_visits';

DO $$
DECLARE n INT;
BEGIN
    SELECT count(*) INTO n FROM metric WHERE code = 'rods_ed_visits';
    IF n <> 1 THEN
        RAISE EXCEPTION 'expected exactly 1 rods_ed_visits metric after rename, '
                        'found %. The ili_ed_visits row was not where this '
                        'migration expected it.', n;
    END IF;
END $$;

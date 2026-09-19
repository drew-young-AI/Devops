-- CONTRACT-PHASE: renames one metric code. Justified below.
--
-- 011: stop encoding the disease in the metric name.
--
-- THE MODELLING ERROR THIS FIXES, BEFORE IT GETS MULTIPLIED BY TEN.
--
-- The NHI family publishes eleven diseases with a byte-identical schema --
-- verified, not assumed: every file is 187,908 rows with columns
--
--     年 週 就診類別 年齡別 縣市 <疾病>健保就診人次 健保就診總人次 縣市別代碼
--
-- The obvious way to load the other ten is to mint `covid_visits`,
-- `entero_visits`, `varicella_visits` and so on alongside the existing
-- `ili_visits`. That is wrong, and the fact table says why: it already carries
-- disease_id. The measurement is the same in all eleven files -- a count of
-- 健保 visits in a (county, epi-week, age band, visit type) cell. Only the
-- DISEASE differs, and the disease is a dimension.
--
-- Encoding it twice would permit rows the schema cannot reject:
--
--     metric = covid_visits  AND  disease = enterovirus
--
-- Nothing in the constraints forbids that, so it would sit in the table looking
-- like data. Two columns that must agree, with nothing enforcing agreement, is
-- the same defect shape as `rows_accepted` carrying three different units.
--
-- WHY A RENAME IS SAFE HERE, WHICH IS NOT USUALLY TRUE.
--
--   * metric_id is unchanged. This is an UPDATE of one row in the `metric`
--     dimension; not one of the 187,908 fact rows moves or is rewritten.
--   * Nothing reads the code. grep across the repository finds `ili_visits`
--     only in the loader that writes it. The application reads `ili_ed_visits`
--     (the RODS metric), which this migration does not touch.
--   * blue/green has no target pilot (docs/Backlog.md §2), so there is no second
--     colour serving against the old name.
--
-- NOT DONE HERE, ON PURPOSE: the same over-specification exists in
-- `ili_ed_visits` for the RODS family (seven diseases, same shape). It is left
-- alone because the application DOES read that code, so changing it is an
-- application change, not a data change. Recorded rather than silently
-- half-done -- see docs/Backlog.md.

UPDATE metric
SET code    = 'nhi_visits',
    name_zh = '健保就診人次',
    notes   = '健保門診/住院就診人次；期間內的事件計數，可沿時間加總。'
              '疾病由 disease_id 表示，不重複編碼在 metric 裡 —— NHI 家族 11 種'
              '疾病的檔案結構完全相同（皆 187,908 列），差異只在疾病。'
WHERE code = 'ili_visits';

-- Assert the rename actually happened. A migration that silently matched zero
-- rows would leave the loader writing to a metric code that no longer exists,
-- and the failure would surface later as an unexplained empty feed.
DO $$
DECLARE n INT;
BEGIN
    SELECT count(*) INTO n FROM metric WHERE code = 'nhi_visits';
    IF n <> 1 THEN
        RAISE EXCEPTION 'expected exactly 1 nhi_visits metric after rename, '
                        'found %. The ili_visits row was not where this '
                        'migration expected it.', n;
    END IF;
END $$;

-- CONTRACT-PHASE: no live colour depends on the old shape.
--
-- Why this is safe now and was not safe in 008. The columns this migration
-- makes NOT NULL were added nullable by 008, and BOTH writers have since been
-- taught to populate them:
--
--   ingest/load_dimensional.py   source_rows_accepted = in_file - rejected - dup
--   ingest/load_geography.py     source_rows_accepted = len(rows), synthesized = 5
--
-- Nothing else writes to ingest_runs -- verified by grep, not assumed: those are
-- the only two INSERT sites in the repository. The application never writes this
-- table; it is an ingestion ledger, so there is no second colour serving traffic
-- against the old shape. blue/green currently has no target pilot at all
-- (docs/Backlog.md §2), which is the other half of why this is safe today.
--
-- WHAT THE CONSTRAINT BUYS.
--
-- Before 008 the numbers could not be checked, so a loader that miscounted
-- produced a plausible row and nobody found out. The specific incident: CareMag
-- runs 7 and 8 are the same source file, and the duplicate-vs-conflict defect
-- moved exactly one row between two categories while leaving every total
-- identical. A count-based check could not see it. An identity can:
--
--   rows_in_file = source_rows_accepted + rows_rejected + duplicate_rows
--
-- Every source row must land in exactly one bucket. A loader that invents,
-- loses or double-counts a row now fails its INSERT at the point of the
-- mistake, instead of leaving a reconciliation for someone six months later.

ALTER TABLE ingest_runs
    ALTER COLUMN duplicate_rows   SET DEFAULT 0,
    ALTER COLUMN synthesized_rows SET DEFAULT 0;

-- Belt and braces: 008 backfilled every existing row, but a run inserted during
-- the expand window (between 008 and this file) would have NULLs. Fail loudly
-- rather than silently coercing -- a NULL here means a loader ran with the old
-- code and its accounting is genuinely unknown, which is not the same as zero.
DO $$
DECLARE n INT;
BEGIN
    SELECT count(*) INTO n FROM ingest_runs
    WHERE source_rows_accepted IS NULL OR output_rows_written IS NULL;
    IF n > 0 THEN
        RAISE EXCEPTION
            'ingest_runs has % row(s) written during the 008 expand window with '
            'no accounting. Backfill them from their note column before applying '
            '009 -- do not default them to 0, which would assert a count nobody '
            'measured.', n;
    END IF;
END $$;

ALTER TABLE ingest_runs
    ALTER COLUMN source_rows_accepted SET NOT NULL,
    ALTER COLUMN duplicate_rows       SET NOT NULL,
    ALTER COLUMN synthesized_rows     SET NOT NULL,
    ALTER COLUMN output_rows_written  SET NOT NULL;

ALTER TABLE ingest_runs
    ADD CONSTRAINT ingest_runs_source_accounting
    CHECK (rows_in_file = source_rows_accepted + rows_rejected + duplicate_rows);

ALTER TABLE ingest_runs
    ADD CONSTRAINT ingest_runs_output_nonneg
    CHECK (output_rows_written >= 0
       AND synthesized_rows >= 0
       AND source_rows_accepted >= 0
       AND duplicate_rows >= 0);

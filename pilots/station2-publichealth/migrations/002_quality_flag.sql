-- 002: per-observation quality flag.
--
-- EXPAND PHASE, deliberately. The column is nullable with a default, so code
-- that predates this migration keeps working unchanged -- which is the whole
-- requirement during a blue/green switch, where the old colour is still
-- serving from the same database while the new one starts.
--
-- The matching CONTRACT phase (NOT NULL, drop the default, remove old
-- writers) is a separate migration that may only run once no live colour
-- depends on the column being absent. Doing both at once is the standard way
-- to make a rollback impossible.
ALTER TABLE observations
    ADD COLUMN IF NOT EXISTS quality TEXT DEFAULT 'unverified';

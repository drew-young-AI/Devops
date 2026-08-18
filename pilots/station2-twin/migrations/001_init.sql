-- 001: observations -- the core twin state table.
--
-- asset_id is TEXT, not an FK to an assets table: a digital twin ingests
-- readings for assets that may not be registered yet, and rejecting an
-- observation because the asset row is missing loses data that cannot be
-- re-collected. Referential integrity is the wrong trade here.
CREATE TABLE IF NOT EXISTS observations (
    id          BIGSERIAL PRIMARY KEY,
    asset_id    TEXT             NOT NULL,
    metric      TEXT             NOT NULL,
    value       DOUBLE PRECISION NOT NULL,
    observed_at TIMESTAMPTZ      NOT NULL DEFAULT now()
);

-- The only query pattern that matters: latest-N for one asset, newest first.
CREATE INDEX IF NOT EXISTS observations_asset_time_idx
    ON observations (asset_id, observed_at DESC);

#!/usr/bin/env python3
"""Which epi-week the drift comparison uses, and how far behind the data it is.

Extracted from the test so the settle rule has exactly one implementation that
can be inspected on its own. It answers the question the defect of 2026-08-29
turned on: the drift query stepped back a fixed `- 100` -- one whole YEAR --
from the latest week, so with data running to 2026w32 it compared 2025w32
against 2024w32. It produced plausible numbers throughout and was structurally
blind to the only year a fault could have been introduced in.

Prints NEWEST, SETTLED and the lag between them.
"""
import os
import sys

import duckdb

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MIRROR = os.path.join(ROOT, "platform/analytics/mirror")

NEWEST_SQL = """
SELECT MAX(CAST(p.epi_year AS INT) * 100 + CAST(p.epi_week AS INT))
FROM fact f JOIN period p ON p.period_id = f.period_id
WHERE p.epi_year IS NOT NULL AND p.epi_week IS NOT NULL
"""

# The settle rule itself: the most recent week whose geographic coverage is at
# least the median of the 12 weeks before it. Data-driven rather than a
# constant, so it steps back on its own if the source ever starts publishing
# partial weeks -- and does not step back a year when it does not.
SETTLED_SQL = """
WITH cov AS (
  SELECT f.disease_id,
         CAST(p.epi_year AS INT) * 100 + CAST(p.epi_week AS INT) AS yw,
         COUNT(DISTINCT f.geo_code) AS geos
  FROM fact f JOIN period p ON p.period_id = f.period_id
  WHERE p.epi_year IS NOT NULL AND p.epi_week IS NOT NULL
  GROUP BY 1, 2
),
cm AS (
  SELECT c.disease_id, c.yw, c.geos, MEDIAN(x.geos) AS med
  FROM cov c JOIN cov x
    ON x.disease_id = c.disease_id AND x.yw < c.yw AND x.yw >= c.yw - 12
  GROUP BY 1, 2, 3
)
SELECT MAX(yw) FROM cm WHERE geos >= med
"""


def main():
    if not os.path.exists(os.path.join(MIRROR, "fact.parquet")):
        sys.exit("no mirror; run platform/analytics/run.sh refresh")
    d = duckdb.connect()
    for alias in ("fact", "period"):
        d.execute(f"CREATE VIEW {alias} AS SELECT * FROM "
                  f"'{os.path.join(MIRROR, alias + '.parquet')}'")
    newest, = d.execute(NEWEST_SQL).fetchone()
    settled, = d.execute(SETTLED_SQL).fetchone()
    # Week numbers, so this is only meaningful inside one year -- which is the
    # point: a lag that crosses a year boundary is the bug, not a rounding issue.
    lag = newest - settled
    print(f"NEWEST={newest} SETTLED={settled} LAG={lag}")
    print(f"LAG_OK={lag <= 4}")


if __name__ == "__main__":
    main()

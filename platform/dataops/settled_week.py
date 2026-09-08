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

# The settle rule itself is NOT defined here. It lives in
# pipeline_metrics.SETTLE_CTE, which is the query production actually
# evaluates. This file used to carry a second copy of it under a
# docstring claiming there was exactly one implementation -- and on
# 2026-09-08 the year-boundary fix landed in the producer while this copy
# kept the broken form, so the suite would have kept certifying a query
# nothing ran. Importing is what makes the docstring true.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pipeline_metrics import SETTLE_CTE            # noqa: E402

SETTLED_SQL = f"WITH {SETTLE_CTE} SELECT MAX(ymax) FROM latest"


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

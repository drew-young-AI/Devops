#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Give every daily period its CDC epidemiological week, from CDC's own table.

WHY A TABLE AND NOT A RULE (2026-09-11).

The obvious implementation is arithmetic: weeks run Sunday to Saturday, week 1
is the one containing January 4, so `(date - week1_start) // 7 + 1`. That rule
is what 疾管署 themselves publish:

    「週別計算方式係以週日為當週第一天，週六為當週結束日，
      每年第1週為包含1月4日之那一週。」
    -- https://nidss.cdc.gov.tw/Home/FAQContent

IT DISAGREES WITH THEIR OWN DATA. Reproduced against
`https://nidss.cdc.gov.tw/config/DIM_CAL.csv` (7,305 rows, 2007-01-01 to
2026-12-31): the rule matches the table exactly from 2010 onward, and
contradicts it for 2007-2009, where the weeks were truncated at the calendar
boundary instead. Six weeks in the file are not seven days long:

    2007 w01  6 days     2008 w01  5 days     2009 w01  3 days (Jan 1-3)
    2007 w53  2 days     2008 w53  4 days     2026 w52  5 days (file ends)

2009 week 02 starts on January 4, so the published rule is wrong about the
published data for that year. Our own database already agreed with the TABLE
rather than the rule -- it holds 2009 week 53 across six RODS feeds, which no
Sunday-start rule produces -- so the 53rd week was never a loader defect.

An implementation that computed the week would therefore be silently wrong for
three years, and wrong in the way that is hardest to see: the query returns
rows, the numbers look plausible, and nothing raises. Same lesson as the SQL
contract one layer out -- derive from the source, never restate it. Here the
source publishes a lookup, so the rule is precisely the thing that must not be
written down.

WHAT THIS FILLS, AND WHAT IT DELIBERATELY DOES NOT.

`time_period` already has `epi_year` and `epi_week`; they are NULL on `day`
rows. This fills those two columns and touches nothing else -- no migration,
and `cal_date` is not overloaded. A week row's identity stays (year, week) and
a day row's stays its date; the JOIN KEY between daily and weekly facts is
(epi_year, epi_week), which is what this makes possible.

It does NOT put a date on `epi_week` rows. A week is an interval, and writing
one date into a column that means "this day" on every other row would give one
column two meanings -- the failure `platform/docs/xref.py` calls COLLIDING.

Usage:
  load_epiweek_calendar.py            report what would change, write nothing
  load_epiweek_calendar.py --apply    fill the columns
  load_epiweek_calendar.py --clear    set them back to NULL (this is reversible)
"""

import csv
import datetime
import hashlib
import io
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CROSSWALK = os.path.join(HERE, "reference", "cdc_dim_cal_20260911.csv")
SOURCE_URL = "https://nidss.cdc.gov.tw/config/DIM_CAL.csv"
CONTAINER = os.environ.get("TWIN_DB_CONTAINER", "station2-twin-db-1")

# A crosswalk that parsed to almost nothing is a broken read, not a small
# calendar. Same refusal as every other enumeration in this repository.
MIN_ROWS = int(os.environ.get("EPIWEEK_MIN_ROWS", "3000"))


def _repo_root():
    return os.path.abspath(os.path.join(HERE, "..", "..", ".."))


def _now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def psql(sql, timeout=60):
    p = subprocess.run(
        ["docker", "exec", CONTAINER, "psql", "-U", "twin", "-d", "twin",
         "-qtAX", "-c", sql],
        capture_output=True, text=True, timeout=timeout)
    if p.returncode != 0:
        raise SystemExit("psql failed: " + " ".join(p.stderr.split())[:200])
    return p.stdout.strip()


def load_crosswalk(path=None):
    """date (YYYY-MM-DD) -> (epi_year, epi_week), from the vendored snapshot."""
    path = path or CROSSWALK
    if not os.path.exists(path):
        raise SystemExit("crosswalk missing: %s (source: %s)" % (path, SOURCE_URL))
    raw = open(path, "rb").read().decode("utf-8-sig")
    out = {}
    for r in csv.DictReader(io.StringIO(raw)):
        ymd = (r.get("CAL_YMD") or "").strip()
        if len(ymd) != 8 or not ymd.isdigit():
            continue
        out["%s-%s-%s" % (ymd[:4], ymd[4:6], ymd[6:])] = (
            int(r["CAL_YEAR"]), int(r["CAL_WEEK"]))
    if len(out) < MIN_ROWS:
        raise SystemExit(
            "REFUSING: crosswalk parsed to %d rows, floor is %d. A short read "
            "would silently leave most days unlabelled and report success."
            % (len(out), MIN_ROWS))
    return out


def main(argv):
    apply_ = "--apply" in argv
    clear = "--clear" in argv

    if clear:
        psql("UPDATE time_period SET epi_year = NULL, epi_week = NULL "
             "WHERE time_level = 'day';")
        print("cleared epi_year/epi_week on day rows")
        return 0

    cal = load_crosswalk()
    days = [d for d in psql(
        "SELECT to_char(cal_date,'YYYY-MM-DD') FROM time_period "
        "WHERE time_level='day' ORDER BY cal_date;").splitlines() if d]
    if not days:
        raise SystemExit("REFUSING: no day periods found -- nothing to label")

    hit = [d for d in days if d in cal]
    miss = [d for d in days if d not in cal]
    print("crosswalk  %d days  %s .. %s" % (len(cal), min(cal), max(cal)))
    print("day rows   %d       %s .. %s" % (len(days), days[0], days[-1]))
    print("labelled   %d" % len(hit))
    print("unlabelled %d%s" % (len(miss), ("  first: " + miss[0]) if miss else ""))

    if not apply_:
        print("\n(dry run -- pass --apply to write)")
        return 0

    # One statement per (year, week), not per day: 3,885 day rows collapse to
    # ~560 groups, and a per-row round trip through `docker exec` would take
    # minutes for no benefit.
    groups = {}
    for d in hit:
        groups.setdefault(cal[d], []).append(d)
    for (y, w), dates in sorted(groups.items()):
        lit = ",".join("'%s'" % d for d in dates)
        psql("UPDATE time_period SET epi_year=%d, epi_week=%d "
             "WHERE time_level='day' AND cal_date IN (%s);" % (y, w, lit))

    filled = psql("SELECT count(*) FROM time_period "
                  "WHERE time_level='day' AND epi_week IS NOT NULL;")
    print("\nwrote %s day rows" % filled)
    if int(filled) != len(hit):
        raise SystemExit("post-condition failed: wrote %s, expected %d"
                         % (filled, len(hit)))

    # The crosswalk is a SNAPSHOT and it ends. `probe_epiweek` has to be able
    # to see that horizon, and it cannot: it reads the database, and "the
    # calendar runs out in December" is a property of the file. So the horizon
    # is written where a probe can read it -- same shape as every other
    # evidence artefact here.
    joinable = psql(
        "SELECT count(*) FROM (SELECT DISTINCT epi_year, epi_week FROM time_period "
        "WHERE time_level='day' AND epi_week IS NOT NULL) d "
        "JOIN (SELECT epi_year, epi_week FROM time_period "
        "WHERE time_level='epi_week') w USING (epi_year, epi_week);")
    payload = {
        "generated_by": "pilots/station2-twin/ingest/load_epiweek_calendar.py --apply",
        "generated_at": _now(),
        "source_url": SOURCE_URL,
        "crosswalk_file": os.path.relpath(CROSSWALK, _repo_root()),
        "crosswalk_sha256": hashlib.sha256(open(CROSSWALK, "rb").read()).hexdigest(),
        "crosswalk_days": len(cal),
        "crosswalk_first": min(cal),
        "crosswalk_last": max(cal),
        "day_periods": len(days),
        "day_periods_labelled": int(filled),
        "unlabelled_days": miss[:50],
        "weeks_joinable": int(joinable),
    }
    out = os.path.join(_repo_root(), "evidence", "data", "epiweek_calendar.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = out + ".tmp"
    with io.open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, out)
    print("wrote evidence/data/epiweek_calendar.json "
          "(crosswalk ends %s, %s weeks joinable)"
          % (payload["crosswalk_last"], joinable))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

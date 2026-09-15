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

WHERE IT WRITES, AND WHY NOT time_period (corrected 2026-09-14).

The first version filled `time_period.epi_year/epi_week` on the `day` rows.
That was wrong, and the way it was wrong is worth keeping: those two columns
are part of the row's identity --

    time_period_natural  UNIQUE NULLS NOT DISTINCT
                         (time_level, epi_year, epi_week, cal_date)

-- so a day row's natural key is (day, NULL, NULL, <date>). Labelling it
changed that key, `load_dimensional.py`'s ON CONFLICT stopped matching, and one
ingest inserted a second copy of every day row: 3,885 -> 7,777 periods,
4.1M -> 8.2M day facts. The next run of this job then failed on the unique
constraint it had itself made unsatisfiable. Rolled back on 2026-09-14
(3,885 periods and 4,104,117 facts deleted inside one transaction with
post-conditions), and the mapping moved to its own table by migration 019.

The crosswalk is reference data about the CALENDAR, not an attribute of a
period. In `epi_calendar` it cannot collide with anything's identity, and the
join is time_period.cal_date -> epi_calendar.cal_date -> (epi_year, epi_week).

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
        psql("DELETE FROM epi_calendar;")
        print("cleared epi_calendar")
        return 0

    cal = load_crosswalk()
    days = [d for d in psql(
        "SELECT to_char(cal_date,'YYYY-MM-DD') FROM time_period "
        "WHERE time_level='day' ORDER BY cal_date;").splitlines() if d]
    if not days:
        raise SystemExit("REFUSING: no day periods found -- nothing to map")

    hit = [d for d in days if d in cal]
    miss = [d for d in days if d not in cal]
    print("crosswalk  %d days  %s .. %s" % (len(cal), min(cal), max(cal)))
    print("day rows   %d       %s .. %s" % (len(days), days[0], days[-1]))
    print("mappable   %d" % len(hit))
    print("unmappable %d%s" % (len(miss), ("  first: " + miss[0]) if miss else ""))

    if not apply_:
        print("\n(dry run -- pass --apply to write)")
        return 0

    # Batched multi-row upsert. Idempotent by construction: cal_date is the
    # primary key and the row is replaced, so re-running changes nothing.
    items = sorted(cal.items())
    BATCH = 800
    for i in range(0, len(items), BATCH):
        vals = ",".join("('%s',%d,%d)" % (d, y, w) for d, (y, w) in items[i:i + BATCH])
        psql("INSERT INTO epi_calendar (cal_date, epi_year, epi_week) VALUES %s "
             "ON CONFLICT (cal_date) DO UPDATE SET epi_year=EXCLUDED.epi_year, "
             "epi_week=EXCLUDED.epi_week;" % vals)

    loaded = int(psql("SELECT count(*) FROM epi_calendar;"))
    if loaded != len(cal):
        raise SystemExit("post-condition failed: loaded %d, crosswalk has %d"
                         % (loaded, len(cal)))

    # time_period MUST be untouched: no day row may carry a week label, or the
    # natural key breaks again exactly as it did on 2026-09-13.
    labelled = int(psql("SELECT count(*) FROM time_period "
                        "WHERE time_level='day' AND epi_week IS NOT NULL;"))
    if labelled:
        raise SystemExit("post-condition failed: %d day rows carry a week label; "
                         "that is what broke the ingest natural key" % labelled)
    dup = int(psql("SELECT count(*) FROM (SELECT cal_date FROM time_period "
                   "WHERE time_level='day' GROUP BY 1 HAVING count(*)>1) x;"))
    if dup:
        raise SystemExit("post-condition failed: %d dates have duplicate day rows" % dup)

    joinable = int(psql(
        "SELECT count(*) FROM (SELECT DISTINCT c.epi_year, c.epi_week "
        "FROM time_period tp JOIN epi_calendar c ON c.cal_date=tp.cal_date "
        "WHERE tp.time_level='day') d JOIN (SELECT epi_year, epi_week FROM time_period "
        "WHERE time_level='epi_week') w USING (epi_year, epi_week);"))

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
        "day_periods_mappable": len(hit),
        "unmappable_days": miss[:50],
        "weeks_joinable": joinable,
        "rows_in_epi_calendar": loaded,
        "day_rows_with_week_label": labelled,
        "duplicate_day_dates": dup,
    }
    out = os.path.join(_repo_root(), "evidence", "data", "epiweek_calendar.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = out + ".tmp"
    with io.open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, out)
    print("\nloaded %d rows into epi_calendar; %d week periods joinable; "
          "time_period untouched (0 labels, 0 duplicate dates)"
          % (loaded, joinable))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

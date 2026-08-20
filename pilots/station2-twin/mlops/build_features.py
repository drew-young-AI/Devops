#!/usr/bin/env python3
"""Build the forecasting feature set, and record where it came from.

WHAT IS BEING PREDICTED

    %ILI(t+1) and %ILI(t+2) for 台中市 outpatient care
    %ILI = 類流感健保就診人次 / 健保就診總人次

Not the raw visit count. The denominator drifts on its own -- public holidays,
pandemic-era care avoidance, NHI policy -- so a model on raw counts learns
"more people went to a doctor" and reports it as "more people are ill". The
numerator and denominator correlate at r = 0.671 in this series, which is
enough to produce a confident, wrong forecast.

EVERY FEATURE HERE IS STRICTLY BACKWARD-LOOKING

Each row's features are computed only from rows at or before its own seq. That
is what makes precomputing them safe, and it is verified rather than asserted:
tests/test_no_lookahead.py rebuilds the feature set over a truncated series and
requires every retained row to be identical. If a feature secretly peeked
forward, truncating the future would change the past, and it would fail.

seasonal_index IS NOT BUILT HERE, ON PURPOSE

The design lists it as a feature: the historical median %ILI for that epi-week.
Computed over the whole series it is a leak -- the future is in the median that
predicts the past, the backtest looks excellent, and production does not. It is
recomputed inside each backtest fold from that fold's training window only, so
it cannot be precomputed, and it must not be stored. See backtest.py.

WHY seq AND NOT A CALENDAR DATE

The epi-week to calendar-date convention is still unconfirmed with 疾管署 (six
standard conventions all fail this data's 53-week years). Ordering by
time_period.seq is correct for a single weekly series regardless of which
convention is right, and it does not silently commit us to a wrong one. It is
NOT sufficient for joining weekly to daily data -- that still waits on the
answer.

Usage:
  build_features.py                 # 台中市 outpatient ILI, the default series
  build_features.py --geo 66000 --visit-type 門診
  build_features.py --max-seq 500   # truncate, for the no-lookahead test
  build_features.py --dry-run
"""
import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
FEATURE_SET_NAME = "ili_outpatient_v1"

# The series the target is drawn from.
TARGET_DISEASE = "influenza_like_illness"
TARGET_METRIC = "nhi_visits"

# Cross-disease interference signals. Both are the SAME metric on a different
# disease -- which is only expressible because migration 012 stopped encoding
# the disease in the metric name.
COVID_DISEASE = "covid19"
ENTERO_DISEASE = "enterovirus"

# NHI age bands that make up "young children". The bands are stored verbatim
# from the source and never harmonised at load time, so the grouping happens
# here where it can be seen and argued with.
YOUNG_BANDS = ("0~2", "3~6")


def code_sha():
    """sha256 of this file. Two feature sets with the same name and different
    code are different things wearing the same label."""
    return hashlib.sha256(HERE.joinpath("build_features.py").read_bytes()).hexdigest()


def weekly_series(cur, geo_code, visit_type, disease_code, max_seq):
    """(seq, epi_year, epi_week, numerator, denominator) for one disease.

    Aggregated across age bands, numerator AND denominator both SUMmed.

    The first version of this averaged the denominator, on the reasoning that
    健保就診總人次 is a per-cell county total repeated on each age-band row. That
    was an assumption, and it was wrong -- checked against the data:

        2026W32 台中市 門診   0~2     978 /  18,375
                              13~15   279 /  11,782
                              25~64  6,057 / 394,482

    The denominator is per age band. Averaging it produced a %ILI of 45%, and
    the only reason that was caught is that 45% of all outpatient visits being
    influenza-like is obviously absurd. A subtler error -- averaging two similar
    denominators -- would have produced a plausible number and shipped.
    """
    cur.execute("""
        SELECT tp.seq, tp.epi_year, tp.epi_week,
               SUM(f.value)::double precision              AS numerator,
               SUM(f.denominator)::double precision        AS denominator
        FROM surveillance_fact f
        JOIN time_period tp ON tp.period_id = f.period_id
        JOIN disease d      ON d.disease_id = f.disease_id
        JOIN metric m       ON m.metric_id  = f.metric_id
        WHERE f.geo_code = %s
          AND f.visit_type = %s
          AND d.code = %s
          AND m.code = %s
          AND tp.time_level = 'epi_week'
          AND (%s::int IS NULL OR tp.seq <= %s::int)
        GROUP BY tp.seq, tp.epi_year, tp.epi_week
        ORDER BY tp.seq
    """, (geo_code, visit_type, disease_code, TARGET_METRIC, max_seq, max_seq))
    return cur.fetchall()


def young_share_series(cur, geo_code, visit_type, max_seq):
    """Share of ILI visits in the 0-6 age bands, per week."""
    cur.execute("""
        SELECT tp.seq,
               SUM(f.value) FILTER (WHERE f.age_band = ANY(%s))::double precision
                 / NULLIF(SUM(f.value), 0) AS young_share
        FROM surveillance_fact f
        JOIN time_period tp ON tp.period_id = f.period_id
        JOIN disease d      ON d.disease_id = f.disease_id
        JOIN metric m       ON m.metric_id  = f.metric_id
        WHERE f.geo_code = %s AND f.visit_type = %s
          AND d.code = %s AND m.code = %s
          AND tp.time_level = 'epi_week'
          AND (%s::int IS NULL OR tp.seq <= %s::int)
        GROUP BY tp.seq ORDER BY tp.seq
    """, (list(YOUNG_BANDS), geo_code, visit_type, TARGET_DISEASE,
          TARGET_METRIC, max_seq, max_seq))
    return {r[0]: r[1] for r in cur.fetchall()}


def rate_by_seq(rows):
    """seq -> rate, skipping cells with no denominator.

    Missing stays missing. A zero denominator is not a zero rate, and filling it
    with 0.0 would put a fabricated trough into a time series whose whole
    purpose is detecting troughs and peaks.
    """
    out = {}
    for seq, _y, _w, num, den in rows:
        if den and den > 0:
            out[seq] = num / den
    return out


def build(cur, geo_code, visit_type, max_seq):
    target = weekly_series(cur, geo_code, visit_type, TARGET_DISEASE, max_seq)
    if not target:
        sys.exit(f"no data for geo={geo_code} visit_type={visit_type}")

    rate = rate_by_seq(target)
    covid = rate_by_seq(weekly_series(cur, geo_code, visit_type, COVID_DISEASE, max_seq))
    entero = rate_by_seq(weekly_series(cur, geo_code, visit_type, ENTERO_DISEASE, max_seq))
    young = young_share_series(cur, geo_code, visit_type, max_seq)
    denom = {seq: den for seq, _y, _w, _n, den in target}

    seqs = [r[0] for r in target]
    meta = {r[0]: (r[1], r[2]) for r in target}

    # time_period.seq IS NOT A COUNTER. It is encoded year*100 + week, so
    # 200752 - 1 = 200751 happens to work inside a year and 200801 - 1 = 200800
    # does not exist. Subtracting from it gave lag_1 for 543 of 554 weeks (the
    # year boundaries silently missing) and same_week_last_year for 44 -- a
    # feature that is 92% absent while looking populated enough to train on.
    #
    # So lags are taken over the ORDINAL position in the ordered series, and the
    # series is asserted contiguous first. Ordinals alone would silently close a
    # real gap, turning "we have no data for week 30" into "week 29 is adjacent
    # to week 31"; the assertion is what makes the ordinal safe to use.
    ordinal = {seq: i for i, seq in enumerate(seqs)}
    gaps = []
    for prev, cur_seq in zip(seqs, seqs[1:]):
        py, pw = meta[prev]
        cy, cw = meta[cur_seq]
        contiguous = (cy == py and cw == pw + 1) or (cy == py + 1 and cw == 1)
        if not contiguous:
            gaps.append(f"{py}W{pw} -> {cy}W{cw}")
    if gaps:
        sys.exit("series is not contiguous, so ordinal lags would be wrong:\n  "
                 + "\n  ".join(gaps[:10]))

    def at(seq, back):
        """Value `back` positions before `seq` (negative looks forward, which is
        only used for the LABELS y_next_*, never for a feature)."""
        i = ordinal[seq] - back
        return rate.get(seqs[i]) if 0 <= i < len(seqs) else None

    def other(series, seq, back):
        i = ordinal[seq] - back
        return series.get(seqs[i]) if i >= 0 else None

    rows = []
    for seq in seqs:
        epi_year, epi_week = meta[seq]
        lag = {k: at(seq, k) for k in (1, 2, 3, 4)}
        rows.append(dict(
            seq=seq, epi_year=epi_year, epi_week=epi_week,
            y=rate.get(seq),
            y_next_1=at(seq, -1),
            y_next_2=at(seq, -2),
            lag_1=lag[1], lag_2=lag[2], lag_3=lag[3], lag_4=lag[4],
            delta_1=(lag[1] - lag[2]) if (lag[1] is not None
                                          and lag[2] is not None) else None,
            # 52 positions back, not "same epi_week last year": in a 53-week
            # year those differ, and looking up by (year-1, week) returns a
            # value one week out of phase for every 53-week year -- of which
            # this series has two (2020 and 2025).
            same_week_last_year=at(seq, 52),
            week_of_year=epi_week,
            denominator_lag_1=(int(other(denom, seq, 1))
                               if other(denom, seq, 1) else None),
            covid_lag_1=other(covid, seq, 1),
            entero_lag_1=other(entero, seq, 1),
            age_share_0_6_lag_1=other(young, seq, 1),
        ))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--geo", default="66000", help="geo_code (default 台中市)")
    ap.add_argument("--visit-type", default="門診")
    ap.add_argument("--max-seq", type=int, default=None,
                    help="truncate the series; used by the no-lookahead test")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    import psycopg

    dsn = os.environ.get("DATABASE_URL") or (
        f"host={os.environ.get('PGHOST', 'host.docker.internal')} "
        f"port={os.environ.get('PGPORT', '15432')} "
        f"dbname={os.environ.get('PGDATABASE', 'twin')} "
        f"user={os.environ.get('PGUSER', 'twin')} "
        f"password={os.environ.get('PGPASSWORD', '')}")

    with psycopg.connect(dsn) as conn:
        cur = conn.cursor()
        rows = build(cur, args.geo, args.visit_type, args.max_seq)

        cur.execute("SELECT disease_id FROM disease WHERE code = %s",
                    (TARGET_DISEASE,))
        did = cur.fetchone()[0]
        cur.execute("SELECT name FROM geo_area WHERE geo_code = %s", (args.geo,))
        geo_name = cur.fetchone()[0]

        usable = [r for r in rows if r["y"] is not None]
        print(f"  {geo_name} {args.visit_type} {TARGET_DISEASE}")
        print(f"  {len(rows):,} weeks, seq {rows[0]['seq']}..{rows[-1]['seq']}, "
              f"{len(usable):,} with a computable rate")
        if usable:
            lo = min(r["y"] for r in usable) * 100
            hi = max(r["y"] for r in usable) * 100
            print(f"  %ILI range {lo:.3f}% .. {hi:.3f}%")
        for col in ("covid_lag_1", "entero_lag_1", "age_share_0_6_lag_1",
                    "same_week_last_year"):
            n = sum(1 for r in rows if r[col] is not None)
            print(f"    {col:<22} {n:>5,} / {len(rows):,} populated")

        if args.dry_run:
            print("  (dry run, nothing written)")
            return

        params = {"target_metric": TARGET_METRIC, "young_bands": list(YOUNG_BANDS),
                  "max_seq": args.max_seq}
        cur.execute("""
            INSERT INTO feature_set (name, code_sha256, geo_code, disease_id,
                                     visit_type, target, n_rows, seq_min,
                                     seq_max, params)
            VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
            ON CONFLICT ON CONSTRAINT feature_set_natural DO UPDATE
                SET n_rows = EXCLUDED.n_rows, built_at = now(),
                    params = EXCLUDED.params
            RETURNING feature_set_id
        """, (FEATURE_SET_NAME, code_sha(), args.geo, did, args.visit_type,
              "pct_ili", len(rows), rows[0]["seq"], rows[-1]["seq"],
              json.dumps(params)))
        fsid = cur.fetchone()[0]

        cols = ["seq", "epi_year", "epi_week", "y", "y_next_1", "y_next_2",
                "lag_1", "lag_2", "lag_3", "lag_4", "delta_1",
                "same_week_last_year", "week_of_year", "denominator_lag_1",
                "covid_lag_1", "entero_lag_1", "age_share_0_6_lag_1"]
        cur.execute("DELETE FROM feature_row WHERE feature_set_id = %s", (fsid,))
        with cur.copy("COPY feature_row (feature_set_id, " + ", ".join(cols) +
                      ") FROM STDIN") as cp:
            for r in rows:
                cp.write_row([fsid] + [r[c] for c in cols])
        conn.commit()
        print(f"  feature_set_id={fsid}  code_sha={code_sha()[:16]}  "
              f"{len(rows):,} rows written")


if __name__ == "__main__":
    main()

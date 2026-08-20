#!/usr/bin/env python3
"""Refit on all available data and publish a forecast -- if the model earned it.

WHAT THIS DOES NOT DO: hand a model to the API.

The API never loads an estimator. Unpickling is arbitrary code execution in the
most exposed process here, and a pickle silently produces different numbers
after a scikit-learn upgrade rather than failing. So this container computes and
writes a row; the API does a SELECT. See migration 014.

THE GATE IS IN THE DATABASE, NOT IN THIS FILE.

This script picks the best qualifying model_run and refuses early with a clear
message if there is none. But the actual enforcement is a TRIGGER: a second
publisher written later by someone who never read this file still cannot insert
a forecast from a model that lost. Putting the rule only here would make it a
convention, and conventions are what this platform keeps discovering were never
running.

BACKTEST SCORE AND PUBLISHED MODEL ARE NOT THE SAME FIT.

The score comes from rolling-origin folds; the published forecast comes from a
final refit on every row. That is standard and it is also a real caveat: the
refit has more data than any fold that scored it, so the score is a conservative
estimate of the deployed model, not a measurement of it. Recorded here rather
than glossed, because "the model has MAE X" is the sentence everyone repeats.

Usage:
  publish_forecast.py                 # publish every horizon that qualifies
  publish_forecast.py --horizon 2
  publish_forecast.py --dry-run
"""
import argparse
import os
import sys

import numpy as np
from sklearn.ensemble import HistGradientBoostingRegressor

import backtest as bt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--horizon", type=int, choices=(1, 2), default=None,
                    help="default: try both")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    horizons = [args.horizon] if args.horizon else [1, 2]

    import psycopg
    dsn = os.environ.get("DATABASE_URL") or (
        f"host={os.environ.get('PGHOST', 'host.docker.internal')} "
        f"port={os.environ.get('PGPORT', '15432')} "
        f"dbname={os.environ.get('PGDATABASE', 'twin')} "
        f"user={os.environ.get('PGUSER', 'twin')} "
        f"password={os.environ.get('PGPASSWORD', '')}")

    published = refused = 0
    with psycopg.connect(dsn) as conn:
        cur = conn.cursor()
        for h in horizons:
            # Best QUALIFYING run: rolling origin, beats both baselines, lowest
            # MAE. Ordering by MAE among winners only -- never picking the best
            # of a losing set, which is how a losing model gets deployed as
            # "the best one we have".
            cur.execute("""
                SELECT mr.model_run_id, mr.feature_set_id, mr.mae,
                       mr.baseline_persistence_mae, mr.hyperparams,
                       fs.geo_code, fs.disease_id, fs.visit_type
                FROM model_run mr JOIN feature_set fs USING (feature_set_id)
                WHERE mr.horizon_weeks = %s
                  AND mr.split_strategy = 'rolling_origin'
                  AND mr.beats_baselines
                ORDER BY mr.mae ASC LIMIT 1
            """, (h,))
            row = cur.fetchone()
            if not row:
                cur.execute("""
                    SELECT count(*), min(mae), min(baseline_persistence_mae)
                    FROM model_run WHERE horizon_weeks = %s
                      AND split_strategy = 'rolling_origin'
                """, (h,))
                n, best_mae, base = cur.fetchone()
                print(f"  t+{h}: REFUSED -- no qualifying model.")
                if n:
                    print(f"        {n} rolling-origin run(s) exist; best MAE "
                          f"{best_mae*100:.4f} pp against persistence "
                          f"{base*100:.4f} pp.")
                    print(f"        A model that loses to persistence is not "
                          f"published. This is the gate working.")
                else:
                    print(f"        no rolling-origin run recorded at this horizon.")
                refused += 1
                continue

            (mrid, fsid, mae, base_mae, hyper, geo, did, vtype) = row

            rows = bt.load_rows(cur, fsid, h)
            usable = [r for r in rows if r["label"] is not None and r["y"] is not None]
            # The origin is the LAST row with an observation, not the last row
            # with a label: the newest weeks have no label yet, and that is
            # exactly the week we are forecasting from.
            observed = [r for r in rows if r["y"] is not None]
            origin = observed[-1]

            idx = bt.seasonal_index(usable)
            model = HistGradientBoostingRegressor(
                max_iter=int(hyper.get("max_iter", 60)),
                max_depth=int(hyper.get("max_depth", 3)),
                learning_rate=float(hyper.get("learning_rate", 0.05)),
                random_state=bt.SEED)
            X = bt.vectorise(usable, idx)
            y = np.array([(r["label"] - r["y"]) for r in usable], float)
            ok = ~np.isnan(y)
            model.fit(X[ok], y[ok])

            delta = float(model.predict(bt.vectorise([origin], idx))[0])
            predicted = origin["y"] + delta
            if predicted < 0:
                # The model predicts a CHANGE, so a large negative change can
                # push the level below zero. A negative rate is not a forecast;
                # clamp and say so rather than letting the CHECK constraint
                # reject it with a less informative message.
                print(f"  t+{h}: predicted {predicted*100:.4f} pp is negative; "
                      f"clamped to 0. Investigate before trusting this horizon.")
                predicted = 0.0

            # LABELLING THE TARGET WEEK.
            #
            # The first version only accepted a target already present in the
            # series, which made the publisher structurally incapable of
            # forecasting: a forecast is by definition about a week that is not
            # in the data yet. An over-cautious guard that prevents the system
            # doing its job is as wrong as a missing one, and it looks
            # responsible while doing it.
            #
            # The real constraint is narrow. Advancing the WEEK NUMBER inside a
            # year needs no convention knowledge at all -- W32 + 1 is W33,
            # always. Only crossing the year boundary needs to know whether the
            # outgoing year has 52 or 53 weeks, which is the open 疾管署
            # question. So: advance freely inside the year, refuse at the
            # boundary, and say which.
            oi = [r["seq"] for r in rows].index(origin["seq"])
            if oi + h < len(rows):
                target = rows[oi + h]        # already observed; use its label
            elif origin["epi_week"] + h <= 52:
                target = {"epi_year": origin["epi_year"],
                          "epi_week": origin["epi_week"] + h}
            else:
                print(f"  t+{h}: origin is "
                      f"{origin['epi_year']}W{origin['epi_week']}, so the target "
                      f"crosses the year boundary. Whether "
                      f"{origin['epi_year']} has 52 or 53 weeks is the "
                      f"unconfirmed 疾管署 question, so the target week cannot "
                      f"be labelled without guessing. Refused.")
                refused += 1
                continue

            print(f"  t+{h}: model_run {mrid}  origin "
                  f"{origin['epi_year']}W{origin['epi_week']} "
                  f"observed {origin['y']*100:.4f} pp")
            print(f"        -> {target['epi_year']}W{target['epi_week']}  "
                  f"predicted {predicted*100:.4f} pp  "
                  f"(backtest MAE {mae*100:.4f} pp)")

            if args.dry_run:
                continue

            # baseline_persistence_mae and backtest_mae are passed as 0 and
            # OVERWRITTEN by the trigger from model_run. Passing the real values
            # here would let a publisher report a score the model never got.
            cur.execute("""
                INSERT INTO forecast (model_run_id, geo_code, disease_id,
                    visit_type, target_epi_year, target_epi_week, horizon_weeks,
                    origin_epi_year, origin_epi_week, observed_at_origin,
                    predicted_value, baseline_persistence_mae, backtest_mae)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,0,0)
                ON CONFLICT ON CONSTRAINT forecast_natural DO UPDATE
                    SET model_run_id = EXCLUDED.model_run_id,
                        predicted_value = EXCLUDED.predicted_value,
                        observed_at_origin = EXCLUDED.observed_at_origin,
                        generated_at = now()
                RETURNING forecast_id
            """, (mrid, geo, did, vtype, target["epi_year"], target["epi_week"],
                  h, origin["epi_year"], origin["epi_week"], origin["y"],
                  predicted))
            print(f"        published forecast_id={cur.fetchone()[0]}")
            published += 1
        if not args.dry_run:
            conn.commit()

    print(f"\n  {published} published, {refused} refused")
    # Refusing is a correct outcome, not an error: exit 0 so a scheduled run
    # does not page anyone because the model honestly did not qualify.
    return 0


if __name__ == "__main__":
    sys.exit(main())

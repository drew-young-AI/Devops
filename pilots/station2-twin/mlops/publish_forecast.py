#!/usr/bin/env python3
"""Refit on all available data and publish a forecast -- if the model earned it.

WHAT THIS DOES NOT DO: hand a model to the API.

The API never loads an estimator. Unpickling is arbitrary code execution in the
most exposed process here, and a pickle silently produces different numbers
after a scikit-learn upgrade rather than failing. So this container computes and
writes a row; the API does a SELECT. See migration 014.

TWO GATES, AND THEY ANSWER DIFFERENT QUESTIONS.

  1. IS IT A MODEL AT ALL?   Enforced in the DATABASE, by a trigger:
     beats_baselines (a GENERATED column) must be true and the split must be
     rolling_origin. A second publisher written later by someone who never read
     this file still cannot publish a model that lost to persistence.

  2. IS IT BETTER THAN THE ONE ALREADY DEPLOYED?   Enforced HERE, because it is
     a policy and not a fact -- see THE REPLACEMENT RULE below. Gate 1 compared
     the candidate to doing nothing; until this file existed, nothing ever
     compared it to what is actually serving. `ORDER BY mae ASC LIMIT 1` reads
     like it does, and does not: it silently replaced the deployed model
     whenever a challenger was 0.01% better, and equally silently kept a
     challenger that was scored on a DIFFERENT feature set, where the MAE is
     not even the same quantity.

BACKTEST SCORE AND PUBLISHED MODEL ARE NOT THE SAME FIT.

The score comes from rolling-origin folds; the published forecast comes from a
final refit on every row. That is standard and it is also a real caveat: the
refit has more data than any fold that scored it, so the score is a conservative
estimate of the deployed model, not a measurement of it. Recorded here rather
than glossed, because "the model has MAE X" is the sentence everyone repeats.

THE REFIT USES THE REGISTRY, NOT A CONSTRUCTOR TYPED HERE.

It used to build a HistGradientBoostingRegressor by name, whatever algorithm
the winning run had used, reading its hyperparameters with `.get(key, default)`
so a missing key silently became a default. A Ridge run that won its horizon
would have been published as an HGB fit carrying the Ridge run's id and the
Ridge run's MAE. Both models exist in this database today; only the fact that
Ridge lost kept that from happening. It now goes through backtest.fit_one --
one fitting path, used by the folds and by the refit.

Usage:
  publish_forecast.py                 # publish every horizon that qualifies
  publish_forecast.py --horizon 2
  publish_forecast.py --dry-run
  publish_forecast.py --explain-gate  # the replacement rule, worked, no DB
"""
import argparse
import os
import sys

import backtest as bt

# The RULE is platform-level (platform/mlops/promotion_policy.py, mounted
# read-only by run.sh); the NUMBER below is this pilot's, because the
# justification for it is a measurement on this data. Splitting them that way
# is the point: another project reusing the rule must supply its own margin,
# and promotion_policy.choose_run has no default to fall back on.
import promotion_policy as policy

# ---------------------------------------------------------------------------
# THE REPLACEMENT RULE (Backlog T22)
#
# A challenger replaces the deployed model only if it is better by more than
# REPLACEMENT_MARGIN, relative. Otherwise the incumbent stays and is refit on
# the newest data. Ties, and improvements below the margin, go to the
# incumbent.
#
# WHY A MARGIN AT ALL, AND WHY THIS NUMBER.
#
# Measured on this database, 2026-09-08. Runs 2/6/8/10 are the same
# configuration on feature_set 1; runs 12/14 are the same configuration on
# feature_set 55, which is the same pipeline two weeks later:
#
#     t+2, HGB, identical config, feature_set 1   MAE 0.001682
#     t+2, HGB, identical config, feature_set 55  MAE 0.001680   (-0.12%)
#
# So two extra weeks of data moved the score by 0.12% with the model held
# constant. A challenger that wins by less than that has not been shown to be a
# better model; it has been shown that the data moved. 2% is an order of
# magnitude above that observed drift and an order of magnitude below the
# differences that separate the families here (Ridge is 11.6% worse than HGB at
# t+2). It is a deliberately blunt instrument in the gap between the two.
#
# WHAT WOULD REPLACE IT. A paired test on per-fold errors -- the same folds,
# error by error, which is what actually answers "is this difference real".
# That needs per-fold errors stored, and model_run keeps only the aggregate.
# Registered as Backlog T23; until then the margin is a stated policy, not a
# statistical claim, and it says so on the board.
#
# WHY THE INCUMBENT WINS TIES. Replacing a served model is not free: the
# published series changes shape, anything downstream that learned its
# behaviour is invalidated, and the reason for the change has to be explainable
# to a clinician afterwards. Paying that for a difference inside the noise
# floor is a cost with no benefit. The bias is toward stability and it is a
# choice, recorded in ADR-0016 rather than left implicit in an ORDER BY.
#
# THE COMPARISON UNIVERSE IS ONE FEATURE SET. This is the half that is easy to
# miss. migration 013 already says, about the baselines, that "a baseline
# evaluated on different folds is not a comparison, and that mismatch is
# invisible in a single reported number" -- and the publisher was then written
# to `ORDER BY mae ASC` across every feature set there had ever been. Same
# error, one table over. A model scored on 551 folds of one feature build and a
# model scored on 553 folds of the next produce two numbers that render
# identically and mean different things. Candidates are therefore restricted to
# the CURRENT feature_set before the rule above ever sees them.
REPLACEMENT_MARGIN = 0.02


def choose_run(candidates, deployed, margin=None):
    """This pilot's binding of the shared rule to its own margin."""
    return policy.choose_run(candidates, deployed,
                             REPLACEMENT_MARGIN if margin is None else margin)


# The rule, exercised on cases rather than described. Run with --explain-gate;
# no database, so it is also the suite's fixture.
EXPLAIN_CASES = [
    ("nothing deployed yet",
     [dict(model_run_id=9, mae=0.0020, algorithm="A", config={})], None),
    ("challenger clearly better (-20%)",
     [dict(model_run_id=9, mae=0.0016, algorithm="B", config={}),
      dict(model_run_id=8, mae=0.0020, algorithm="A", config={})],
     dict(model_run_id=8, algorithm="A", config={})),
    ("challenger better but inside the margin (-1%)",
     [dict(model_run_id=9, mae=0.00198, algorithm="B", config={}),
      dict(model_run_id=8, mae=0.0020, algorithm="A", config={})],
     dict(model_run_id=8, algorithm="A", config={})),
    ("incumbent is still the best available",
     [dict(model_run_id=8, mae=0.0020, algorithm="A", config={})],
     dict(model_run_id=7, algorithm="A", config={})),
    ("incumbent never scored on the current feature set",
     [dict(model_run_id=9, mae=0.0020, algorithm="B", config={})],
     dict(model_run_id=8, algorithm="A", config={})),
    ("no qualifying candidate at all", [], None),
]


def explain_gate():
    print(f"replacement margin: {REPLACEMENT_MARGIN*100:.0f}% relative MAE, "
          f"incumbent wins ties")
    print("candidates are restricted to the CURRENT feature set: an MAE from "
          "another feature\nset was computed on different folds and is not the "
          "same quantity.\n")
    for label, cands, dep in EXPLAIN_CASES:
        chosen, decision, detail = choose_run(cands, dep)
        outcome = (f"publish from run {chosen['model_run_id']}" if chosen
                   else "publish nothing")
        print(f"  {label}\n    -> {decision:<12} {outcome}\n"
              f"       {detail}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--horizon", type=int, choices=(1, 2), default=None,
                    help="default: try both")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--explain-gate", action="store_true",
                    help="print the replacement rule worked through its cases "
                         "and exit; needs no database")
    args = ap.parse_args()

    if args.explain_gate:
        explain_gate()
        return 0

    horizons = [args.horizon] if args.horizon else [1, 2]

    import numpy as np
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

        # The current feature set defines the comparison universe. Newest by
        # built_at, which is the same row backtest.py trains against.
        cur.execute("SELECT feature_set_id, name FROM feature_set "
                    "ORDER BY built_at DESC LIMIT 1")
        fs = cur.fetchone()
        if not fs:
            print("no feature_set -- run build_features.py first")
            return 1
        current_fsid, current_fsname = fs
        print(f"comparison universe: feature_set {current_fsid} "
              f"'{current_fsname}'  (margin {REPLACEMENT_MARGIN*100:.0f}%)")

        for h in horizons:
            cur.execute("""
                SELECT mr.model_run_id, mr.mae, mr.algorithm, mr.hyperparams,
                       fs.geo_code, fs.disease_id, fs.visit_type,
                       mr.feature_set_id
                FROM model_run mr JOIN feature_set fs USING (feature_set_id)
                WHERE mr.horizon_weeks = %s
                  AND mr.split_strategy = 'rolling_origin'
                  AND mr.beats_baselines
                  AND mr.feature_set_id = %s
                ORDER BY mr.mae ASC, mr.trained_at DESC, mr.model_run_id DESC
            """, (h, current_fsid))
            candidates = []
            for (mrid, mae, algo, hyper, geo, did, vtype, fsid) in cur.fetchall():
                ctor, cfg = bt.split_stored_hyperparams(hyper)
                candidates.append(dict(
                    model_run_id=mrid, mae=mae, algorithm=algo, config=cfg,
                    ctor=ctor, geo=geo, disease_id=did, visit_type=vtype,
                    feature_set_id=fsid))

            cur.execute("""
                SELECT f.model_run_id, mr.algorithm, mr.hyperparams, mr.mae,
                       mr.feature_set_id
                FROM forecast f JOIN model_run mr USING (model_run_id)
                WHERE f.horizon_weeks = %s
                ORDER BY f.forecast_id DESC LIMIT 1
            """, (h,))
            drow = cur.fetchone()
            deployed = None
            if drow:
                d_ctor, d_cfg = bt.split_stored_hyperparams(drow[2])
                deployed = dict(model_run_id=drow[0], algorithm=drow[1],
                                config=d_cfg, ctor=d_ctor, mae=drow[3],
                                feature_set_id=drow[4])

            chosen, decision, detail = choose_run(candidates, deployed)
            dep_txt = (f"run {deployed['model_run_id']} {deployed['algorithm']} "
                       f"(feature_set {deployed['feature_set_id']})"
                       if deployed else "none")
            print(f"\n  t+{h}: deployed {dep_txt}")
            print(f"        {len(candidates)} qualifying candidate(s) on "
                  f"feature_set {current_fsid}")
            print(f"        {decision}: {detail}")

            if chosen is None:
                cur.execute("""
                    SELECT count(*), min(mae), min(baseline_persistence_mae)
                    FROM model_run WHERE horizon_weeks = %s
                      AND split_strategy = 'rolling_origin'
                """, (h,))
                n, best_mae, base = cur.fetchone()
                if n:
                    print(f"        {n} rolling-origin run(s) exist; best MAE "
                          f"{best_mae*100:.4f} pp against persistence "
                          f"{base*100:.4f} pp.")
                    print(f"        A model that loses to persistence is not "
                          f"published. This is the gate working.")
                else:
                    print(f"        no rolling-origin run recorded at this "
                          f"horizon.")
                refused += 1
                continue

            mrid = chosen["model_run_id"]

            # The refit must reproduce the run that was SCORED. Three things
            # have to match, and each is refused loudly rather than defaulted:
            # the algorithm must be a registered one, its constructor arguments
            # must be the ones the registry declares today, and the target
            # convention must be recorded.
            spec = bt.model_spec(chosen["algorithm"])
            if chosen["ctor"] != spec["hyperparams"]:
                print(f"        REFUSED: run {mrid} was scored with "
                      f"{chosen['ctor']} but the registry now declares "
                      f"{spec['hyperparams']} for {chosen['algorithm']}. "
                      f"Refitting would deploy a model that was never "
                      f"evaluated. Re-run backtest.py and publish that.")
                refused += 1
                continue
            if "predict_delta" not in chosen["config"]:
                print(f"        REFUSED: run {mrid} does not record "
                      f"predict_delta, so the target convention it was scored "
                      f"under is unknown (migration 016 backfills this).")
                refused += 1
                continue
            predict_delta = bool(chosen["config"]["predict_delta"])

            rows = bt.load_rows(cur, chosen["feature_set_id"], h)
            usable = [r for r in rows
                      if r["label"] is not None and r["y"] is not None]
            # The origin is the LAST row with an observation, not the last row
            # with a label: the newest weeks have no label yet, and that is
            # exactly the week we are forecasting from.
            observed = [r for r in rows if r["y"] is not None]
            origin = observed[-1]

            model, idx = bt.fit_one(usable, spec, predict_delta)
            raw = float(model.predict(bt.vectorise([origin], idx))[0])
            predicted = (origin["y"] + raw) if predict_delta else raw
            if predicted < 0:
                # A delta model predicts a CHANGE, so a large negative change
                # can push the level below zero. A negative rate is not a
                # forecast; clamp and say so rather than letting the CHECK
                # constraint reject it with a less informative message.
                print(f"        predicted {predicted*100:.4f} pp is negative; "
                      f"clamped to 0. Investigate before trusting this "
                      f"horizon.")
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
                print(f"        origin is "
                      f"{origin['epi_year']}W{origin['epi_week']}, so the "
                      f"target crosses the year boundary. Whether "
                      f"{origin['epi_year']} has 52 or 53 weeks is the "
                      f"unconfirmed 疾管署 question, so the target week cannot "
                      f"be labelled without guessing. Refused.")
                refused += 1
                continue

            print(f"        model_run {mrid} {chosen['algorithm']} "
                  f"(target = {'change' if predict_delta else 'level'})  "
                  f"origin {origin['epi_year']}W{origin['epi_week']} "
                  f"observed {origin['y']*100:.4f} pp")
            print(f"        -> {target['epi_year']}W{target['epi_week']}  "
                  f"predicted {predicted*100:.4f} pp  "
                  f"(backtest MAE {chosen['mae']*100:.4f} pp)")

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
            """, (mrid, chosen["geo"], chosen["disease_id"],
                  chosen["visit_type"], target["epi_year"],
                  target["epi_week"], h, origin["epi_year"],
                  origin["epi_week"], origin["y"], predicted))
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

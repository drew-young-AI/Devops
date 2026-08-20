#!/usr/bin/env python3
"""Rolling-origin backtest against two naive baselines, and the wrong way beside it.

THE ONLY QUESTION A FORECAST HAS TO ANSWER FIRST

Not "what is the MAE" -- an MAE alone is unreadable, because the scale of the
target sets it. The question is whether the model beats doing nothing:

    persistence      y(t+1) = y(t)                 "assume next week is this week"
    seasonal naive   y(t+1) = y(t+51)              "assume next week is last year"

A model that loses to either is not a model. `model_run.beats_baselines` is a
GENERATED column precisely so nobody can write `true` into it by hand.

Both baselines are evaluated on THE SAME FOLDS as the model, per run. A baseline
computed over a different span is not a comparison, and the mismatch is
invisible once it has been reduced to one number on a slide.

ROLLING ORIGIN, NOT A RANDOM SPLIT

    train [....................]  test [.]
    train [.....................] test [.]
    train [......................]test [.]

Train to week t, predict t+h, step forward, repeat. Every prediction is made
with only the past available to it, which is the situation the model will
actually be in.

A random split puts week 300 in training and week 299 in test. The model is
asked to interpolate a series it has already seen either side of, which it does
extremely well, and the reported score is meaningless. This script runs that
mistake DELIBERATELY, once, and stores it next to the honest number with
split_strategy='random' -- because the inflated figure is not distinguishable
from a good result by looking at it, and the gap between the two is the whole
lesson.

seasonal_index IS COMPUTED HERE, PER FOLD, FROM TRAINING DATA ONLY

The historical median %ILI for a given epi-week is a genuinely useful feature
and a textbook leak. Computed once over the whole series, every fold's training
median already contains that fold's test week. It is therefore recomputed inside
each fold from that fold's training rows alone, and never stored -- see the
comment in migration 013 for why it has no column.

Usage:
  backtest.py                        # horizon 1, rolling origin
  backtest.py --horizon 2
  backtest.py --also-wrong-split     # additionally run and record the leak
  backtest.py --dry-run
"""
import argparse
import hashlib
import json
import os
import statistics
import sys
from pathlib import Path

import numpy as np
# HistGradientBoostingRegressor, not GradientBoostingRegressor. The first
# version used the latter and then fed it np.nan_to_num(X, nan=-1.0) -- which
# directly contradicted this file's own comment about not inventing data. A
# sentinel of -1.0 in a series whose values live in 0.004..0.05 is not a neutral
# placeholder; it is an extreme outlier that a tree will happily split on, so
# "missing" became a strong fabricated signal. Hist* supports NaN natively and
# routes missing values down whichever branch the training data supports.
from sklearn.ensemble import HistGradientBoostingRegressor

HERE = Path(__file__).resolve().parent
SEED = 42

# Order matters and is fixed: the model is refit per fold, and a feature vector
# whose column order drifted between folds would train on one meaning and
# predict another.
BASE_FEATURES = [
    "lag_1", "lag_2", "lag_3", "lag_4", "delta_1",
    "same_week_last_year", "week_of_year", "denominator_lag_1",
    "covid_lag_1", "entero_lag_1", "age_share_0_6_lag_1",
]
DERIVED_FEATURES = ["seasonal_index"]   # computed per fold, never stored
FEATURES = BASE_FEATURES + DERIVED_FEATURES


def code_sha():
    return hashlib.sha256(HERE.joinpath("backtest.py").read_bytes()).hexdigest()


def load_rows(cur, feature_set_id, horizon):
    label = f"y_next_{horizon}"
    cur.execute(f"""
        SELECT seq, epi_year, epi_week, y, {label} AS label,
               {', '.join(BASE_FEATURES)}
        FROM feature_row WHERE feature_set_id = %s ORDER BY seq
    """, (feature_set_id,))
    cols = ["seq", "epi_year", "epi_week", "y", "label"] + BASE_FEATURES
    return [dict(zip(cols, r)) for r in cur.fetchall()]


def seasonal_index(train_rows):
    """Median %ILI per epi-week, from TRAINING rows only.

    Returns a dict; weeks unseen in training get None rather than a global
    fallback. A fallback would quietly substitute information the fold does not
    have, which is the same leak in a smaller font.
    """
    buckets = {}
    for r in train_rows:
        if r["y"] is not None:
            buckets.setdefault(r["epi_week"], []).append(r["y"])
    return {w: statistics.median(v) for w, v in buckets.items() if v}


def vectorise(rows, index):
    """Feature matrix. Missing values stay NaN and reach the model as NaN --
    imputing a mean would invent data, imputing 0 would place a fabricated
    trough in a series whose troughs are the signal, and a sentinel like -1.0
    would be an outlier the tree can split on."""
    out = []
    for r in rows:
        vec = [(np.nan if r[f] is None else float(r[f])) for f in BASE_FEATURES]
        si = index.get(r["epi_week"])
        vec.append(np.nan if si is None else float(si))
        out.append(vec)
    return np.array(out, dtype=float)


def metrics(actual, predicted):
    a, p = np.asarray(actual, float), np.asarray(predicted, float)
    mae = float(np.mean(np.abs(a - p)))
    with np.errstate(divide="ignore", invalid="ignore"):
        mape = float(np.mean(np.abs((a - p) / a)) * 100) if np.all(a != 0) else None
    return mae, mape


def direction_accuracy(last_obs, actual, predicted):
    """Did we get the DIRECTION right -- up or down from the last observed week?

    For staffing and antiviral stock this is often the decision-relevant number:
    knowing it will rise matters more than the second decimal of how much.
    """
    hits = tot = 0
    for lo, a, p in zip(last_obs, actual, predicted):
        if lo is None:
            continue
        tot += 1
        if (a >= lo) == (p >= lo):
            hits += 1
    return (hits / tot) if tot else None


def rolling_origin(rows, horizon, min_train):
    """Yield (train, test_row) with test strictly after every training row."""
    usable = [r for r in rows if r["label"] is not None and r["y"] is not None]
    for i in range(min_train, len(usable)):
        yield usable[:i], usable[i]


# PREDICTING THE LEVEL vs PREDICTING THE CHANGE.
#
# The first honest run lost to persistence: MAE 0.1836 pp against 0.1175, with
# direction accuracy at 49.7% -- a coin flip. That is not a tuning problem, it
# is a modelling error with a specific name.
#
# A gradient-boosted TREE cannot extrapolate. Every prediction it makes is an
# average of training labels, so asked for the LEVEL of %ILI next week it can
# only return a level it has already seen. On a series with drift and with
# regime changes as violent as 2020-2022, the level it learned is frequently no
# longer where the series is, and persistence -- which needs no training and
# simply says "the same as now" -- wins easily.
#
# Predicting the CHANGE (y_next - y) reframes it so persistence IS the model's
# zero prediction. The model then only has to beat predicting zero, and a tree
# is well suited to that: deltas are stationary in a way levels are not.
#
# This is ONE change, made for a stated structural reason, and both results are
# recorded. It is not a search for a configuration that wins -- that search is
# how a backtest becomes a slide with no predictive content behind it.
def run_rolling(rows, horizon, min_train, predict_delta=False):
    actual, pred, last_obs = [], [], []
    persistence, seasonal = [], []
    n_train_last = 0
    for train, test in rolling_origin(rows, horizon, min_train):
        idx = seasonal_index(train)
        model = HistGradientBoostingRegressor(
            max_iter=60, max_depth=3, learning_rate=0.05, random_state=SEED)
        Xtr = vectorise(train, idx)
        if predict_delta:
            ytr = np.array([(r["label"] - r["y"]) for r in train], float)
        else:
            ytr = np.array([r["label"] for r in train], float)
        ok = ~np.isnan(ytr)
        model.fit(Xtr[ok], ytr[ok])
        raw = float(model.predict(vectorise([test], idx))[0])
        # Add the change back onto the last observed value. test["y"] is the
        # week the forecast is MADE from, so this uses no future information.
        yhat = (test["y"] + raw) if predict_delta else raw

        actual.append(test["label"])
        pred.append(yhat)
        last_obs.append(test["y"])
        # Persistence: next week equals this week.
        persistence.append(test["y"])
        # Seasonal naive: same week last year. None when unavailable, and the
        # pair is dropped rather than filled -- a baseline scored on a different
        # subset is not the same baseline.
        seasonal.append(test["same_week_last_year"])
        n_train_last = len(train)
    return actual, pred, last_obs, persistence, seasonal, n_train_last


def run_random_split(rows, horizon, min_train):
    """THE MISTAKE, ON PURPOSE. Shuffles time away and reports the flattering
    number so it can sit next to the honest one."""
    usable = [r for r in rows if r["label"] is not None and r["y"] is not None]
    rng = np.random.default_rng(SEED)
    order = rng.permutation(len(usable))
    cut = int(len(usable) * 0.8)
    train = [usable[i] for i in order[:cut]]
    test = [usable[i] for i in order[cut:]]
    # The leak in one line: the index is built from a training set that is
    # scattered through the whole timeline, including weeks after the test rows.
    idx = seasonal_index(train)
    model = HistGradientBoostingRegressor(
        max_iter=60, max_depth=3, learning_rate=0.05, random_state=SEED)
    Xtr, ytr = vectorise(train, idx), np.array([r["label"] for r in train], float)
    ok = ~np.isnan(ytr)
    model.fit(Xtr[ok], ytr[ok])
    pred = model.predict(vectorise(test, idx))
    return ([r["label"] for r in test], list(map(float, pred)),
            [r["y"] for r in test], [r["y"] for r in test],
            [r["same_week_last_year"] for r in test], len(train))


def summarise(tag, actual, pred, last_obs, persistence, seasonal):
    mae, mape = metrics(actual, pred)
    p_mae, _ = metrics(actual, persistence)
    pairs = [(a, s) for a, s in zip(actual, seasonal) if s is not None]
    s_mae = (float(np.mean([abs(a - s) for a, s in pairs])) if pairs else None)
    da = direction_accuracy(last_obs, actual, pred)
    print(f"  {tag}")
    print(f"    n_test              {len(actual):,}")
    print(f"    model MAE           {mae*100:.4f} pp")
    print(f"    persistence MAE     {p_mae*100:.4f} pp")
    print(f"    seasonal-naive MAE  "
          f"{f'{s_mae*100:.4f} pp' if s_mae else 'n/a'}"
          f"   ({len(pairs)}/{len(actual)} weeks comparable)")
    print(f"    direction accuracy  {f'{da*100:.1f}%' if da is not None else 'n/a'}")
    beats = mae < p_mae and (s_mae is None or mae < s_mae)
    # The MARGIN, not just the verdict. beats_baselines is a strict `<`, so it
    # reports YES for a 0.3% improvement exactly as loudly as for a 30% one, and
    # a 0.3% edge over persistence on 449 folds is noise. A floor is not a
    # certificate, and printing only the boolean is how noise becomes a claim.
    edge = (p_mae - mae) / p_mae * 100 if p_mae else 0.0
    verdict = "YES" if beats else "NO"
    if beats and edge < 5.0:
        verdict += f"  (but only by {edge:.1f}% -- within noise, not a result)"
    elif beats:
        verdict += f"  ({edge:.1f}% better than persistence)"
    else:
        verdict += f"  ({-edge:.1f}% WORSE than persistence)"
    print(f"    beats both baselines: {verdict}")
    return dict(mae=mae, mape=mape, direction=da,
                persistence=p_mae, seasonal=s_mae, beats=beats)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--horizon", type=int, default=1, choices=(1, 2))
    ap.add_argument("--min-train", type=int, default=104,
                    help="weeks of history before the first prediction "
                         "(default 2 years, so seasonality is learnable)")
    ap.add_argument("--also-wrong-split", action="store_true")
    ap.add_argument("--predict-delta", action="store_true",
                    help="model the change from the last observed week instead "
                         "of the level; persistence becomes the zero prediction")
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
        cur.execute("SELECT feature_set_id, name, n_rows FROM feature_set "
                    "ORDER BY built_at DESC LIMIT 1")
        row = cur.fetchone()
        if not row:
            sys.exit("no feature_set -- run build_features.py first")
        fsid, name, n_rows = row
        rows = load_rows(cur, fsid, args.horizon)
        print(f"feature_set {fsid} '{name}'  {n_rows:,} rows  horizon t+{args.horizon}")
        print(f"  seed {SEED}, HistGradientBoostingRegressor(60, depth 3, lr 0.05)")

        runs = []
        label = ("rolling origin, predicting the CHANGE" if args.predict_delta
                 else "rolling origin, predicting the LEVEL")
        r = run_rolling(rows, args.horizon, args.min_train, args.predict_delta)
        runs.append(("rolling_origin", summarise(label, *r[:5]), r[5], len(r[0])))
        if args.also_wrong_split:
            w = run_random_split(rows, args.horizon, args.min_train)
            runs.append(("random", summarise("random split (LEAKS -- not a result)",
                                             *w[:5]), w[5], len(w[0])))

        if args.dry_run:
            print("  (dry run, nothing written)")
            return

        for strategy, m, n_train, n_test in runs:
            cur.execute("""
                INSERT INTO model_run (feature_set_id, algorithm, hyperparams,
                    seed, split_strategy, horizon_weeks, n_train, n_test,
                    mae, mape, direction_accuracy,
                    baseline_persistence_mae, baseline_seasonal_mae,
                    code_sha256, notes)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                RETURNING model_run_id, beats_baselines
            """, (fsid, "HistGradientBoostingRegressor",
                  json.dumps({"max_iter": 60, "max_depth": 3,
                              "learning_rate": 0.05, "min_train": args.min_train}),
                  SEED, strategy, args.horizon, n_train, n_test,
                  m["mae"], m["mape"], m["direction"],
                  m["persistence"], m["seasonal"], code_sha(),
                  ("seasonal_index recomputed per fold from training rows only; "
                   + ("target = change from last observed week"
                      if args.predict_delta else "target = level"))
                  if strategy == "rolling_origin" else
                  "DELIBERATE LEAK, kept for contrast. A random split on a time "
                  "series trains on weeks either side of each test week."))
            mid, beats = cur.fetchone()
            print(f"  model_run_id={mid} strategy={strategy} "
                  f"beats_baselines={beats}")
        conn.commit()


if __name__ == "__main__":
    main()

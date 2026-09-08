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

# The registry CONTRACT lives at platform/mlops/model_registry.py and is mounted
# read-only by run.sh. It is shared because it is not about influenza: every
# project that trains a model needs the same declaration and the same refusal.
# What is NOT shared is MODELS below -- the entries are this pilot's, and the
# reasons in them are about this feature set.
try:
    import model_registry as mreg
except ImportError:  # pragma: no cover - environment defect, not a code path
    sys.exit("cannot import model_registry. It is mounted at /platform/mlops "
             "by run.sh; running this script outside that container will not "
             "find it. Use ./run.sh backtest.py ...")

# HistGradientBoostingRegressor, not GradientBoostingRegressor. The first
# version used the latter and then fed it np.nan_to_num(X, nan=-1.0) -- which
# directly contradicted this file's own comment about not inventing data. A
# sentinel of -1.0 in a series whose values live in 0.004..0.05 is not a neutral
# placeholder; it is an extreme outlier that a tree will happily split on, so
# "missing" became a strong fabricated signal. Hist* supports NaN natively and
# routes missing values down whichever branch the training data supports.

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


# ---------------------------------------------------------------------------
# THE MODEL REGISTRY
#
# WHY A REGISTRY AND NOT JUST A DIFFERENT CONSTRUCTOR CALL.
#
# The algorithm used to be three literals that had to agree by hand: the banner
# line, the constructor in run_rolling (and again in run_random_split), and the
# INSERT into model_run. Changing the model in one place would have left
# `model_run.algorithm` and `hyperparams` describing the PREVIOUS model, which
# is worse than no provenance -- every downstream comparison would silently be
# between two things wearing the same name. Everything now reads from here.
#
# WHAT AN ENTRY MUST DECLARE, AND WHY EACH FIELD IS NOT OPTIONAL.
#
#   family        what class of model this is. On the board and in the report,
#                 so a reviewer can see whether two runs are even comparable.
#   build(hp)     returns an UNFITTED estimator. Fitting happens per fold, on
#                 training rows only; an entry that returns a fitted object, or
#                 that peeks at the full frame, breaks rolling-origin silently.
#   hyperparams   recorded verbatim into model_run.hyperparams. Not a copy of
#                 what build() uses -- the SAME dict is passed to build().
#   handles_nan   whether the estimator accepts NaN features. This is the field
#                 that decides whether a family can be added at all here; see
#                 nan_policy.
#   nan_policy    required when handles_nan is False. NaN in this feature set is
#                 not noise: covid_lag_1 is NULL in 288 of 556 rows (51.8%)
#                 because COVID did not exist before 2020, and
#                 same_week_last_year is NULL in 52 (9.4%). Dropping incomplete
#                 rows would discard half the history; imputing silently would
#                 invent a pre-2020 COVID signal. So a non-NaN model must SAY
#                 what it does, in the pipeline, where it is reviewable.
#   deterministic whether the same seed and the same rows give the same numbers.
#                 False is allowed but must be declared -- CLAUDE.md §5b treats
#                 a non-reproducible result as UNVERIFIED, and the gate compares
#                 MAE to four decimal places.
#
# HOW TO ADD ONE: append an entry, run
#   ./run.sh backtest.py --algorithm <name> --horizon 1 --dry-run
# and the guide in docs/MLOps-Model-Extension.md.

def _build_hgb(hp):
    from sklearn.ensemble import HistGradientBoostingRegressor
    return HistGradientBoostingRegressor(random_state=SEED, **hp)


def _build_ridge(hp):
    """Linear model + an explicit, leak-free missing-value policy.

    SimpleImputer(add_indicator=True) learns the medians INSIDE the pipeline,
    so Pipeline.fit on a training fold never sees the test row -- the same
    property rolling_origin exists to protect. The indicator columns are the
    honest half: "this value was missing" is itself a feature here, because
    for covid_lag_1 it means "before 2020", which is a real distinction and not
    a defect in the data.
    """
    from sklearn.impute import SimpleImputer
    from sklearn.linear_model import Ridge
    from sklearn.pipeline import make_pipeline
    from sklearn.preprocessing import StandardScaler
    return make_pipeline(
        SimpleImputer(strategy="median", add_indicator=True),
        StandardScaler(),
        Ridge(**hp))


MODELS = {
    "HistGradientBoostingRegressor": {
        "family": "梯度提升樹（tree ensemble）",
        "build": _build_hgb,
        "hyperparams": {"max_iter": 60, "max_depth": 3, "learning_rate": 0.05},
        "handles_nan": True,
        "nan_policy": None,
        "deterministic": True,
    },
    "Ridge": {
        "family": "統計／線性（L2 正則化）",
        "build": _build_ridge,
        "hyperparams": {"alpha": 1.0},
        "handles_nan": False,
        "nan_policy": "median-impute + missing indicator, fitted per fold "
                      "inside the pipeline (never on test rows)",
        "deterministic": True,
    },
}

# Keys that describe the RUN, not the estimator. They are stored alongside the
# constructor hyperparams in model_run.hyperparams -- one blob is what the
# schema gives us -- so anything reading that blob back must separate them
# again. Passing min_train to a constructor is a TypeError; passing
# predict_delta silently would be worse.
RUN_CONFIG_KEYS = ("min_train", "predict_delta")


def model_spec(name):
    """Select from MODELS through the shared contract.

    sys.exit rather than a traceback: the caller is a scheduled job, and the
    message has to be the whole diagnosis.
    """
    try:
        return mreg.get(MODELS, name)
    except mreg.RegistryError as e:
        sys.exit(f"{e}\nSee docs/MLOps-Model-Extension.md.")


def stored_hyperparams(spec, min_train, predict_delta):
    """What goes into model_run.hyperparams: the constructor arguments plus the
    run configuration that changes what the number MEANS.

    predict_delta was previously recorded only as English inside `notes`. The
    publisher refits from scratch and has to reproduce the same target
    convention; reading it out of prose is not reading it, and a level-trained
    run refitted as a delta model would publish a number no evaluation ever
    covered while every artefact still looked normal.
    """
    return dict(spec["hyperparams"], min_train=min_train,
                predict_delta=bool(predict_delta))


def split_stored_hyperparams(hp):
    """(constructor kwargs, run config) from a stored blob."""
    cfg = {k: hp[k] for k in RUN_CONFIG_KEYS if k in hp}
    ctor = {k: v for k, v in hp.items() if k not in RUN_CONFIG_KEYS}
    return ctor, cfg


def fit_one(train_rows, spec, predict_delta, index=None):
    """Build, fit, return (model, seasonal_index). THE single fitting path.

    Both the backtest fold and the final refit call this. They used to be two
    similar blocks in two files, and they had already diverged: the publisher
    constructed a HistGradientBoostingRegressor by name whatever the winning
    run's algorithm was, and assumed predict_delta. A fork whose two halves
    agree today is not the same thing as one implementation.
    """
    idx = seasonal_index(train_rows) if index is None else index
    model = spec["build"](spec["hyperparams"])
    X = vectorise(train_rows, idx)
    if predict_delta:
        y = np.array([(r["label"] - r["y"]) for r in train_rows], float)
    else:
        y = np.array([r["label"] for r in train_rows], float)
    ok = ~np.isnan(y)
    model.fit(X[ok], y[ok])
    return model, idx


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
def run_rolling(rows, horizon, min_train, predict_delta=False, spec=None):
    actual, pred, last_obs = [], [], []
    persistence, seasonal = [], []
    n_train_last = 0
    for train, test in rolling_origin(rows, horizon, min_train):
        model, idx = fit_one(train, spec, predict_delta)
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


def run_random_split(rows, horizon, min_train, spec=None):
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
    # Same fitting path as the honest run -- this contrast is only meaningful if
    # the ONLY difference between the two is how the rows were split.
    model, idx = fit_one(train, spec, predict_delta=False)
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
    ap.add_argument("--algorithm", default="HistGradientBoostingRegressor",
                    help="a key of MODELS in this file. Unknown names are "
                         "refused with the list, never defaulted -- see "
                         "docs/MLOps-Model-Extension.md")
    ap.add_argument("--list-models", action="store_true",
                    help="print the registry and exit")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if args.list_models:
        # Validate through the SAME contract the run path uses, and BUILD every
        # entry, not just print it. A listing that shows an entry which would
        # be refused on selection -- or whose build() raises on its own
        # declared hyperparams -- is a catalogue of things that may not exist,
        # the exact shape this repo keeps finding. Listing is the self-test.
        try:
            mreg.validate_all(MODELS)
        except mreg.RegistryError as e:
            sys.exit(f"{e}\nSee docs/MLOps-Model-Extension.md.")
        print(mreg.describe(
            MODELS, dumps=lambda d: json.dumps(d, ensure_ascii=False)))
        return
    spec = model_spec(args.algorithm)

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
        # Read from the registry, not retyped: this line used to be a third
        # hand-maintained copy of the model's identity.
        print(f"  seed {SEED}, {args.algorithm}"
              f"({json.dumps(spec['hyperparams'], ensure_ascii=False)})"
              f"  family={spec['family']}"
              + ("" if spec["deterministic"] else "  [NON-DETERMINISTIC]"))

        runs = []
        label = ("rolling origin, predicting the CHANGE" if args.predict_delta
                 else "rolling origin, predicting the LEVEL")
        r = run_rolling(rows, args.horizon, args.min_train, args.predict_delta,
                        spec=spec)
        runs.append(("rolling_origin", summarise(label, *r[:5]), r[5], len(r[0])))
        if args.also_wrong_split:
            w = run_random_split(rows, args.horizon, args.min_train, spec=spec)
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
            """, (fsid, args.algorithm,
                  json.dumps(stored_hyperparams(
                      spec, args.min_train, args.predict_delta)),
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

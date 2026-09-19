#!/usr/bin/env python3
"""Replay the PUBLISHING DECISION week by week. Not the model -- the system.

WHY THIS EXISTS.

The board's mlops row rests on a post-hoc score of n=1. `forecast` holds two
published rows; one target week has arrived. That is the entire measured track
record of this platform's predictions, and it grows by roughly one row a week
because `retrain` is a weekly job and t+1 has never passed the gate. Reaching
an n anyone could speak from is months away.

The data to answer it already exists. Every ingredient of the weekly decision
-- the features, the fitting path, the gate, the replacement rule -- is
deterministic and available for every week of history. So the question

    "if this system had been running all along, would the numbers it PUBLISHED
     have beaten persistence, and how often?"

can be answered today, at n in the hundreds, without waiting.

WHAT THIS IS NOT.

It is not a backtest of a model. `backtest.py` already scores a model against
folds. This scores the DECISION: which algorithm the gate would have chosen at
each origin, whether it would have published at all, and how the published
number then fared against the week that actually arrived. A run where the gate
correctly refuses to publish is a success of the system and has no MAE.

It is not the live record either, and the two must never be added together --
this is a REPLAY under today's code, and the live rows were produced by the
code of their day. The metrics it emits are prefixed `mlops_policy_backtest_`
for exactly that reason.

LEAKAGE IS THE WHOLE DIFFICULTY, and it has three separate doors here:

  1. Fitting. Handled by fit_one over `rolling_origin`'s strictly-prior train
     rows -- the same path the real backtest uses, not a copy.
  2. SELECTION. The gate at origin i may only use errors observed at origins
     BEFORE i. Choosing the algorithm that turned out to win overall is the
     classic way a replay reports a track record nobody could have had.
  3. The baseline. Persistence is scored on exactly the origins the model was
     scored on; a baseline evaluated over a different subset is not the same
     baseline.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

import numpy as np

import backtest as bt
import promotion_policy as policy

# Inside the pilot image this file lives at /mlops, with no repo above it, so
# nothing here may reach for a repo root. publish_forecast.py is its sibling in
# both layouts, which is the only path this script needs.
HERE = Path(__file__).resolve().parent

# Origins whose trailing errors are too few to choose from. Below this the
# "champion" is whichever algorithm happened to win two coin flips, and the
# replay would be measuring noise selection rather than a policy.
MIN_HISTORY = 20


def connect():
    """psycopg3, matching backtest.py -- this runs inside the same pilot image
    and psycopg2 is not installed there. Same DSN shape, same env defaults."""
    import psycopg
    dsn = os.environ.get("DATABASE_URL") or (
        f"host={os.environ.get('PGHOST', 'host.docker.internal')} "
        f"port={os.environ.get('PGPORT', '15432')} "
        f"dbname={os.environ.get('PGDATABASE', 'twin')} "
        f"user={os.environ.get('PGUSER', 'twin')} "
        f"password={os.environ.get('PGPASSWORD', '')}")
    return psycopg.connect(dsn)


def positive_int(v):
    n = int(v)
    if n < 1:
        raise argparse.ArgumentTypeError(
            "--limit takes a positive count; use --all-origins for everything")
    return n


def trailing_mae(errors):
    return float(np.mean(errors)) if errors else None


def replay(rows, horizon, min_train, predict_delta, margin, algorithms,
           lock_family=None, limit=None):
    """One pass over history. Returns (decisions, per-algorithm error series).

    At each origin every candidate algorithm is fitted and scored, because the
    gate needs a comparable number for each of them -- that is what makes this
    a replay of the DECISION and not of one model. The cost is one fit per
    (origin, algorithm), which is why --limit exists.
    """
    origins = list(bt.rolling_origin(rows, horizon, min_train))
    if limit:
        origins = origins[-limit:]

    errs = {a: [] for a in algorithms}      # abs error per origin, in order
    base_errs = []                          # persistence, same origins
    decisions = []
    deployed = None                         # what the replay currently serves

    for i, (train, test) in enumerate(origins):
        # ---- score every candidate at this origin --------------------------
        preds = {}
        for name in algorithms:
            spec = bt.model_spec(name)
            model, idx = bt.fit_one(train, spec, predict_delta)
            raw = float(model.predict(bt.vectorise([test], idx))[0])
            preds[name] = (test["y"] + raw) if predict_delta else raw
        base_pred = test["y"]

        # ---- the gate, using ONLY errors from strictly earlier origins -----
        base_trailing = trailing_mae(base_errs)
        candidates = []
        for name in algorithms:
            m = trailing_mae(errs[name])
            if m is None or base_trailing is None:
                continue
            if len(errs[name]) < MIN_HISTORY:
                continue
            # Gate 1, the fact: it must beat the naive baseline over the same
            # origins. Same rule the database trigger enforces on model_run.
            if m >= base_trailing:
                continue
            candidates.append({"model_run_id": f"{name}@{i}", "mae": m,
                               "algorithm": name,
                               "config": {"predict_delta": predict_delta}})
        candidates.sort(key=lambda c: c["mae"])

        if lock_family:
            candidates = [c for c in candidates if c["algorithm"] == lock_family]

        chosen, decision, _ = policy.choose_run(candidates, deployed, margin)

        published = None
        if chosen is not None:
            deployed = chosen
            published = preds[chosen["algorithm"]]

        decisions.append({
            "origin_index": i,
            "epi_year": test["epi_year"], "epi_week": test["epi_week"],
            "decision": decision,
            "algorithm": chosen["algorithm"] if chosen else None,
            "published": published,
            "actual": test["label"],
            "persistence": base_pred,
        })

        # ---- accumulate errors AFTER the decision, never before ------------
        for name in algorithms:
            errs[name].append(abs(test["label"] - preds[name]))
        base_errs.append(abs(test["label"] - base_pred))

    return decisions, errs, base_errs


def summarise(decisions):
    """Score only the origins where the system actually published.

    A refused origin is not a miss. Counting it as one would punish the gate
    for working, and the whole point of the gate is that publishing nothing is
    an allowed outcome.
    """
    served = [d for d in decisions if d["published"] is not None]
    # The decision counts are computed FIRST and returned in every case. The
    # first version returned a bare {"n": 0} when nothing was published, and
    # printed "origins replayed 0" for a replay that had walked 40 origins and
    # refused at all of them -- a run that did its job reported as a run that
    # did not happen. The refusals are the finding, not the absence of one.
    counts = {}
    for d in decisions:
        counts[d["decision"]] = counts.get(d["decision"], 0) + 1
    base = {"n": 0, "n_origins": len(decisions), "decisions": counts}
    if not served:
        return base
    err_model = [abs(d["actual"] - d["published"]) for d in served]
    err_base = [abs(d["actual"] - d["persistence"]) for d in served]
    won = sum(1 for a, b in zip(err_model, err_base) if a < b)
    mae_m, mae_b = float(np.mean(err_model)), float(np.mean(err_base))
    families = {}
    for d in served:
        families[d["algorithm"]] = families.get(d["algorithm"], 0) + 1
    return {
        "n": len(served),
        "n_origins": len(decisions),
        "won": won,
        "win_rate": won / len(served),
        "mae_published": mae_m,
        "mae_persistence": mae_b,
        # The headline: over the weeks it chose to publish, did the SYSTEM beat
        # doing nothing? Positive = yes.
        "margin_ratio": (mae_b - mae_m) / mae_b if mae_b else None,
        "decisions": counts,
        "families_served": families,
    }


def write_artifact(args, fs, margin, summary, decisions, to_stdout, say):
    """One writer for both exit paths.

    The refusal path had its own copy of this block and it had already drifted:
    it omitted min_train and predict_delta. Two writers for one artifact means
    the same run is recorded differently depending on how it ended -- and the
    path that drifts is always the one nobody reads.

    `-` writes to STDOUT because run.sh mounts only /mlops into the pilot
    image: a run inside the container physically cannot write into evidence/.
    """
    # THE TARGET, NOT JUST THE FEATURE SET ID. Two targets exist as of
    # 2026-09-09 (ILI and influenza), and every downstream reader keyed on
    # (horizon, mode) alone -- so the flu artifact and the ILI artifact for the
    # same horizon overwrote each other, and whichever was written last became
    # "the" result. An id is not a name; a reader six months out cannot tell
    # feature_set 99 from 100.
    doc = {"feature_set": fs, "target": getattr(args, "target", None),
           "feature_set_name": getattr(args, "feature_set_name", None),
           "horizon": args.horizon, "margin": margin,
           "min_train": args.min_train, "predict_delta": args.predict_delta,
           "lock_family": args.lock_family, "limit": args.limit,
           "all_origins": args.all_origins,
           "summary": summary, "decisions": decisions,
           "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    text = json.dumps(doc, ensure_ascii=False, indent=1)
    if to_stdout:
        sys.stdout.write(text + "\n")
        say("  json=<stdout>")
    else:
        Path(args.json).write_text(text, encoding="utf-8")
        say(f"  json={args.json}")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--horizon", type=int, default=2)
    ap.add_argument("--min-train", type=int, default=104)
    ap.add_argument("--predict-delta", action="store_true", default=True)
    ap.add_argument("--margin", type=float, default=None,
                    help="replacement margin; default reads publish_forecast.py")
    # --limit takes a POSITIVE count only. `0` is not accepted as "no limit":
    # zero means zero, and a flag whose zero silently means "everything" is how
    # a bounded run becomes a full-corpus one by accident. Unlimited has its own
    # name.
    ap.add_argument("--limit", type=positive_int, default=None,
                    help="replay only the last N origins (N >= 1). One model "
                         "fit per origin per algorithm, so this is the cost "
                         "knob. NOTE: it truncates the TRAILING ERROR HISTORY "
                         "too, so the first MIN_HISTORY origins of a limited "
                         "run can never publish -- a limited run understates "
                         "publication and is for smoke-testing, not for a "
                         "result.")
    ap.add_argument("--all-origins", action="store_true",
                    help="replay every origin. Measured at ~0.07s per origin "
                         "per algorithm, so the full history is well inside "
                         "the bounded-runtime rule.")
    ap.add_argument("--lock-family", default=None,
                    help="restrict the gate to one algorithm. Locked answers "
                         "'is HGB any good'; unlocked answers 'is this "
                         "PROCESS any good' -- two different questions, and "
                         "the unlocked one is what the board claims.")
    ap.add_argument("--feature-set", type=int, default=None)
    ap.add_argument("--json", default=None,
                    help="write the full replay here; `-` means stdout")
    args = ap.parse_args()
    # When stdout carries the artifact, the human summary goes to stderr.
    # Mixing them produces a file that is valid text and invalid JSON, which
    # test_evidence_contract.sh rejects -- correctly, and only afterwards.
    to_stdout = args.json == "-"
    report = sys.stderr if to_stdout else sys.stdout

    def say(*a):
        print(*a, file=report)

    if args.limit is None and not args.all_origins:
        ap.error("choose one: --limit N (a smoke test) or --all-origins (a "
                 "result). Defaulting either way would let a truncated replay "
                 "be read as a track record.")
    if args.limit is not None and args.all_origins:
        ap.error("--limit and --all-origins contradict each other")

    margin = args.margin
    if margin is None:
        # One home for the threshold. Read, never retyped -- the same rule the
        # board and the exporter follow.
        src = HERE / "publish_forecast.py"
        for line in src.read_text(encoding="utf-8").splitlines():
            if line.startswith("REPLACEMENT_MARGIN = "):
                margin = float(line.split("=")[1].strip())
                break
    if margin is None:
        sys.exit("cannot read REPLACEMENT_MARGIN and none was given")

    with connect() as conn, conn.cursor() as cur:
        fs = args.feature_set
        if fs is None:
            cur.execute("SELECT max(feature_set_id) FROM feature_set")
            fs = cur.fetchone()[0]
        cur.execute("SELECT target, name FROM feature_set WHERE feature_set_id = %s",
                    (fs,))
        row = cur.fetchone()
        target, set_name = row if row else (None, None)
        rows = bt.load_rows(cur, fs, args.horizon)

    algorithms = sorted(bt.MODELS)
    t0 = time.time()
    args.target = target
    args.feature_set_name = set_name
    decisions, errs, base_errs = replay(
        rows, args.horizon, args.min_train, args.predict_delta, margin,
        algorithms, lock_family=args.lock_family, limit=args.limit)
    s = summarise(decisions)
    elapsed = time.time() - t0

    say(f"policy replay  feature_set={fs} ({set_name}, target={target})  "
        f"t+{args.horizon}  "
          f"margin={margin}  "
          f"mode={'locked:' + args.lock_family if args.lock_family else 'policy'}")
    say(f"  origins replayed        {s.get('n_origins', 0)}  "
          f"({elapsed:.1f}s, {len(algorithms)} algorithm(s) fitted per origin)")
    if s["n"] == 0:
        say(f"  decisions               {s['decisions']}")
        say("  the gate published NOTHING over this window -- no MAE to")
        say("  report, and that is a RESULT: over these origins no algorithm")
        say("  beat persistence on its own trailing errors.")
        if args.json:
            write_artifact(args, fs, margin, s, decisions, to_stdout, say)
        return 0
    say(f"  published at            {s['n']} origin(s)")
    say(f"  beat persistence at     {s['won']}/{s['n']}  "
          f"({s['win_rate']*100:.1f}%)")
    say(f"  MAE published           {s['mae_published']*100:.4f} pp")
    say(f"  MAE persistence         {s['mae_persistence']*100:.4f} pp")
    say(f"  relative advantage      {s['margin_ratio']*100:+.2f}%")
    say(f"  decisions               {s['decisions']}")
    say(f"  families actually served{s['families_served']}")

    if args.json:
        write_artifact(args, fs, margin, s, decisions, to_stdout, say)
    return 0


if __name__ == "__main__":
    sys.exit(main())

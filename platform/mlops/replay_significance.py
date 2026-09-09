#!/usr/bin/env python3
"""Is the replay's margin distinguishable from noise? A PAIRED test.

WHY THIS IS NOT T23.

T23 registered the real gap: `model_run` stores only aggregate MAE, so a paired
test between two models on the same folds is impossible without a new schema.
That is still true and still registered.

But the question T23 was going to answer -- "is this margin real?" -- has a
second instance that needs no migration at all. The policy replay
(pilots/station2-twin/mlops/policy_backtest.py) already records, for every
origin it published at, the actual value, the published value and the
persistence value. That is a PAIRED sample: the same week, scored two ways,
hundreds of times. The paired errors are in the artifact; nothing has to be
stored that is not already stored.

WHAT IT REPORTS, AND WHY THREE THINGS AND NOT ONE.

  * A SIGN TEST on wins. It assumes almost nothing -- only that each week is
    an independent draw -- and it answers the plainest form of the question:
    is the win rate distinguishable from a coin?
  * A PAIRED BOOTSTRAP interval on the relative margin. The margin is a ratio
    of two means over the same weeks, and a ratio has no closed-form interval
    worth trusting at this sample size. Resampling WEEKS (not errors
    independently) preserves the pairing, which is the entire point.
  * The autocorrelation caveat, stated rather than corrected. Weekly
    surveillance errors are not independent: an epidemic week is followed by
    another epidemic week. Both procedures above assume independence, so both
    UNDERSTATE the interval. A moving-block bootstrap is the standard repair;
    it is not done here, and the number is reported with that limitation
    attached rather than quietly presented as if it were not there.

Deterministic: fixed seed, pure stdlib. Same artifact in, same numbers out.
"""
from __future__ import annotations

import argparse
import glob
import json
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SEED = 42
RESAMPLES = 10000


def newest_artifacts(directory):
    """Latest artifact per (horizon, mode)."""
    out = {}
    for f in sorted(glob.glob(os.path.join(directory, "policy_backtest_*.json"))):
        try:
            with open(f, encoding="utf-8") as fh:
                doc = json.load(fh)
        except (OSError, ValueError):
            continue
        # KEYED ON THE TARGET AS WELL. Keyed on (horizon, mode) alone, the
        # influenza artifact and the ILI artifact for the same horizon
        # overwrote each other and whichever sorted last silently became "the"
        # result -- for a different disease.
        key = (doc.get("target") or f"fs{doc.get('feature_set')}",
               doc.get("horizon"),
               "locked" if doc.get("lock_family") else "policy")
        prev = out.get(key)
        if prev is None or doc.get("generated_at", "") >= prev[1].get("generated_at", ""):
            out[key] = (f, doc)
    return out


def paired_errors(doc):
    """(model_error, baseline_error) for every origin that PUBLISHED.

    Refused origins are excluded and that is not a choice about statistics: a
    refusal produced no number, so there is nothing to score. Including them as
    ties would dilute the sample with weeks the system deliberately sat out.
    """
    pairs = []
    for d in doc.get("decisions", []):
        if d.get("published") is None or d.get("actual") is None:
            continue
        pairs.append((abs(d["actual"] - d["published"]),
                      abs(d["actual"] - d["persistence"])))
    return pairs


def sign_test(wins, n):
    """Two-sided binomial p-value against p=0.5, exact.

    math.comb is exact for these n, so no normal approximation is needed and
    none is used -- an approximation here would be a second thing to justify
    for no benefit.
    """
    if n == 0:
        return None
    k = min(wins, n - wins)
    tail = sum(math.comb(n, i) for i in range(k + 1)) / (2.0 ** n)
    return min(1.0, 2.0 * tail)


def bootstrap_margin(pairs, resamples=RESAMPLES, seed=SEED):
    """Percentile interval for (mae_base - mae_model)/mae_base.

    Resamples WEEKS with replacement, keeping each week's two errors together.
    Resampling the two error lists independently would destroy the pairing and
    produce a wider, wrong interval that still looks like an interval.
    """
    rng = random.Random(seed)
    n = len(pairs)
    if n == 0:
        return None
    stats = []
    for _ in range(resamples):
        idx = [rng.randrange(n) for _ in range(n)]
        m = sum(pairs[i][0] for i in idx) / n
        b = sum(pairs[i][1] for i in idx) / n
        if b:
            stats.append((b - m) / b)
    if not stats:
        return None
    stats.sort()
    lo = stats[int(0.025 * len(stats))]
    hi = stats[min(len(stats) - 1, int(0.975 * len(stats)))]
    return lo, hi


def lag1_autocorrelation(values):
    """How far from independent the weekly differences are.

    Reported, not corrected. A number near zero means the independence
    assumption above is roughly harmless; a large one means both intervals are
    too narrow and should be read as a lower bound on the uncertainty.
    """
    n = len(values)
    if n < 3:
        return None
    mean = sum(values) / n
    var = sum((v - mean) ** 2 for v in values)
    if not var:
        return None
    cov = sum((values[i] - mean) * (values[i + 1] - mean) for i in range(n - 1))
    return cov / var


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dir", default=os.path.join(REPO_ROOT, "evidence", "mlops"))
    ap.add_argument("--json", default=None)
    args = ap.parse_args()

    found = newest_artifacts(args.dir)
    if not found:
        print(f"no replay artifact in {args.dir} -- run policy_backtest.py first",
              file=sys.stderr)
        return 78

    results = []
    for (target, horizon, mode), (path, doc) in sorted(found.items(),
                                                      key=lambda kv: str(kv[0])):
        pairs = paired_errors(doc)
        n = len(pairs)
        if n == 0:
            print(f"{target} t+{horizon} [{mode}]  published nothing -- nothing to test")
            continue
        wins = sum(1 for m, b in pairs if m < b)
        mae_m = sum(p[0] for p in pairs) / n
        mae_b = sum(p[1] for p in pairs) / n
        margin = (mae_b - mae_m) / mae_b if mae_b else None
        p = sign_test(wins, n)
        ci = bootstrap_margin(pairs)
        ac = lag1_autocorrelation([b - m for m, b in pairs])

        print(f"{target} t+{horizon} [{mode}]  n={n}")
        print(f"  win rate            {wins}/{n} = {wins/n*100:.1f}%")
        print(f"  sign test p         {p:.4f}"
              f"   ({'distinguishable from a coin' if p < 0.05 else 'NOT distinguishable from a coin'})")
        print(f"  relative margin     {margin*100:+.2f}%")
        if ci:
            print(f"  95% CI (paired bs)  [{ci[0]*100:+.2f}%, {ci[1]*100:+.2f}%]"
                  f"   ({'excludes 0' if ci[0] > 0 or ci[1] < 0 else 'INCLUDES 0'})")
        if ac is not None:
            print(f"  lag-1 autocorr      {ac:+.3f}"
                  "   (independence assumed by both tests; a large value means"
                  " the interval is too NARROW)")
        results.append({"target": target, "horizon": horizon, "mode": mode,
                        "n": n, "wins": wins,
                        "sign_test_p": p, "margin_ratio": margin,
                        "ci95": list(ci) if ci else None,
                        "lag1_autocorrelation": ac, "artifact": os.path.basename(path)})

    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump({"seed": SEED, "resamples": RESAMPLES, "results": results},
                      fh, ensure_ascii=False, indent=1)
        print(f"json={args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

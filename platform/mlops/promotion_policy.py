"""When does a new model replace the one already serving? Project-neutral.

WHY THIS IS NOT IN THE DATABASE WITH THE OTHER GATE.

There are two questions and only one of them has a factual answer.

  "Is this a model at all?"  -- yes if it beats doing nothing. That is a fact
  about the numbers, it is the same fact in every project, and it belongs in a
  trigger where no publisher can route around it.

  "Should it replace what is serving?" -- this is a judgement about cost. A
  0.5% better model is better; whether it is better ENOUGH to justify changing
  a series that people have built expectations on is a business question, and
  a different business will answer it differently. Encoding that in a trigger
  would make a policy look like a law.

So the rule lives here, as a pure function over already-computed scores, and
the MARGIN is supplied by the project rather than defaulted. There is no
default on purpose: a project that has not thought about its margin should be
made to, not handed 0.02 and a silence.

THE COMPARISON UNIVERSE IS THE CALLER'S JOB.

`candidates` must already be restricted to runs that are comparable with each
other -- same evaluation protocol, same data build, same target. This function
cannot check that, and a caller that passes scores computed on different data
gets an answer that is arithmetically correct and meaningless. The one thing it
does enforce is that the incumbent is only ever compared against its own
re-scored self within that universe.
"""


class PolicyError(ValueError):
    pass


def relative_gain(incumbent_error, challenger_error):
    """How much better the challenger is, as a fraction of the incumbent's
    error. Positive means better (lower error)."""
    if not incumbent_error:
        return 0.0
    return (incumbent_error - challenger_error) / incumbent_error


def choose_run(candidates, deployed, margin):
    """Pick the run to publish from. No database, no fitting, no I/O.

    candidates -- comparable qualifying runs, BEST FIRST. Each a dict with
                  model_run_id, mae, algorithm, config.
    deployed   -- the run behind what is currently served, or None. It may sit
                  outside the comparison universe, and that case has its own
                  answer rather than being silently treated as a loss.
    margin     -- required. Relative improvement the challenger must clear.

    Returns (chosen, decision, detail); chosen is None only when there is
    nothing publishable. decision is one of REFUSED / BOOTSTRAP / INCOMPARABLE
    / REFRESH / REPLACE / KEEP, and detail is the sentence a human reads.
    """
    if margin is None:
        raise PolicyError("margin is required: a replacement rule with an "
                          "implicit threshold is a threshold nobody agreed to")
    if margin < 0:
        raise PolicyError(f"margin must be >= 0, got {margin}")
    if not candidates:
        return None, "REFUSED", "no qualifying run in the comparison universe"

    best = candidates[0]
    if deployed is None:
        return best, "BOOTSTRAP", "nothing is deployed at this horizon yet"

    # The incumbent's score IN THIS UNIVERSE -- the same configuration
    # re-scored, not its old number carried forward. Identity is (algorithm,
    # config): two runs of the same algorithm with different hyperparameters
    # are different models wearing one name.
    same = [c for c in candidates
            if c["algorithm"] == deployed["algorithm"]
            and c["config"] == deployed["config"]]
    if not same:
        return best, "INCOMPARABLE", (
            f"the deployed model (run {deployed['model_run_id']}, "
            f"{deployed['algorithm']}) has no score in the current comparison "
            f"universe, so the two cannot be compared on the same folds. "
            f"Publishing the best available and saying so -- a scheduled "
            f"retrain of the incumbent is what normally prevents this")
    incumbent = same[0]

    if best["model_run_id"] == incumbent["model_run_id"]:
        return incumbent, "REFRESH", (
            f"the deployed configuration is still the best available "
            f"(MAE {incumbent['mae']*100:.4f} pp); refit on the newest data")

    gain = relative_gain(incumbent["mae"], best["mae"])
    if gain >= margin:
        return best, "REPLACE", (
            f"run {best['model_run_id']} ({best['algorithm']}) beats the "
            f"deployed configuration by {gain*100:.2f}% "
            f"({best['mae']*100:.4f} vs {incumbent['mae']*100:.4f} pp), "
            f"clearing the {margin*100:.0f}% margin")
    return incumbent, "KEEP", (
        f"run {best['model_run_id']} ({best['algorithm']}) is "
        f"{gain*100:+.2f}% against the deployed configuration, inside the "
        f"{margin*100:.0f}% margin. The incumbent stays; a difference this "
        f"size is not evidence of a better model")

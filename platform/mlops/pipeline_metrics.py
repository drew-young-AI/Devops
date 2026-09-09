#!/usr/bin/env python3
"""MLOps metrics for Prometheus. The layer that had a lamp and no numbers.

WHY THIS FILE EXISTS.

2026-09-08, measured: Prometheus held 99 metric names. `devops_*` had 20 and
`dataops_*` had 15. `mlops` had ZERO. The whole layer was represented by one
series -- `devops_node_state_code{layer="mlops"}` -- which is a light, not a
measurement. Consequences, all of them silent:

  * Nothing can alert on a model. A deployed model that stops beating its
    baseline turns a board node amber and pages nobody.
  * There is no trend. "Is the model better than last month" had no answer
    that did not involve opening psql.
  * The one real number on the board -- the margin over baseline -- lived
    only inside a Python f-string in dag.py's node detail. A string cannot be
    graphed, ranged over, or compared with its own past.

That is this platform's catalogued shape 「登記為存在，但不執行」 one layer up:
mlops was registered on the board, with nothing measured underneath.

WHAT IT DELIBERATELY DOES NOT DO.

No verdicts. Every threshold lives in
observability/prometheus/alerts/mlops.yml, for the same reason dataops keeps
its judgements there: "what counts as too old / too small" should be one
reviewable list, not a number buried in a Python file nobody opens.

No second copy of the scoring query. `FORECAST_SCORE_SQL` is imported from
statusdag/dag.py, which is its one definition. That query's first version
omitted geo_code and visit_type from the join and fanned 2 forecasts out to
44 rows -- a plausible-looking sample size built entirely from duplicates. A
copy here would be a second chance to reintroduce exactly that.

No registry inventory. Counting registered model families would need the
pilot's sklearn image (a ~12s container start per run) to answer a question
nobody would ever alert on. A metric that no rule and no panel reads is cost
with no reader.

CARDINALITY. Labels are horizon (2 values) and algorithm (2 values), both
bounded by the registry, not by time. Nothing here is keyed on model_run_id
as a LABEL -- run ids grow without limit, and a label that grows forever is
how a textfile exporter quietly becomes the most expensive series in the
database. The deployed run id is emitted as a VALUE instead.
"""
from __future__ import annotations

import calendar
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO_ROOT, "platform", "statusdag"))

import dag  # noqa: E402  -- psql(), FORECAST_SCORE_SQL, replacement_margin()

OUT = os.environ.get(
    "MLOPS_PROM",
    os.path.join(REPO_ROOT, "evidence", "statusdag", "mlops.prom"))

# PROJECT IS A LABEL, NOT A FILE (ADR-0017).
#
# A second project must not double the exporters, the freshness thresholds or
# the dashboards. Every series here carries `project`, so a second pilot means
# one more value in a dropdown rather than one more of everything. The loop
# over projects is the extension point: this reads one pilot database today,
# and when there are two it iterates and writes both into the same .prom --
# which is exactly why the file is not named after the project.
#
# The platform-level exporters (host disk, loki, health rollup) deliberately do
# NOT carry it: one host, one cluster, and a dimension with one possible value
# is not information. That omission is a decision, recorded in ADR-0017.
PROJECT = os.environ.get("MLOPS_PROJECT", "station2-twin")

# TARGET IS A LABEL TOO, for the same reason one level down: as of 2026-09-09
# this pilot forecasts influenza-like illness AND influenza, which are
# different diseases in this warehouse and different numbers on the same axis.
# Without it the two feature sets' runs take turns in one slot and the series
# reads as one model getting better and worse.
def base_labels():
    return f'project="{esc(PROJECT)}"' 

# THE COMPARISON UNIVERSE, AS A FILTER AND NOT AS A CAVEAT.
#
# An MAE from one feature set is not the same quantity as an MAE from another:
# 551 folds and 553 folds produce numbers that print alike and mean different
# things. publish_forecast.py already refuses to compare across feature sets
# (ADR-0016). The exporter has to make the same restriction, or a Grafana panel
# would happily draw a line through the discontinuity and call it improvement.
CURRENT_SET = """
    WITH cur AS (
      -- THE NEWEST FEATURE SET *PER TARGET*, not the newest overall.
      --
      -- `max(feature_set_id)` was right while one target existed. From
      -- 2026-09-09 this pilot forecasts influenza-like illness AND influenza,
      -- so the newest set overall is simply whichever was rebuilt last -- and
      -- every metric would have described that one disease while claiming to
      -- describe the layer.
      SELECT DISTINCT ON (fs.target) fs.target, fs.feature_set_id AS fs
      FROM feature_set fs
      WHERE EXISTS (SELECT 1 FROM model_run m
                    WHERE m.feature_set_id = fs.feature_set_id
                      AND m.split_strategy = 'rolling_origin')
      ORDER BY fs.target, fs.feature_set_id DESC
    )
"""


def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"')


def rows(sql, timeout=25):
    """Split psql -qtAX output into fields. None (no answer) is kept distinct
    from [] (answered, zero rows) -- the board already colours those two
    differently and the exporter must not collapse them either."""
    out = dag.psql(sql, timeout=timeout)
    if out is None:
        return None
    return [ln.split("|") for ln in out.strip().splitlines() if ln.strip()]


def margin(mae, base):
    """Relative advantage over the persistence baseline. Positive = better.

    This is the definition of relative error, not a policy, so computing it
    here and again in dag.py's display SQL is not the repeated-threshold
    defect: the POLICY number (2%) has exactly one home, publish_forecast.py's
    REPLACEMENT_MARGIN, and is emitted below by reading that file.
    """
    return None if not base else (base - mae) / base


def latest_runs(lines):
    """The newest run per (horizon, algorithm) inside the current feature set.

    DISTINCT ON (horizon, algorithm), not DISTINCT ON (horizon): once a second
    family was registered, "the latest run at t+1" stopped being a single
    thing. Without the algorithm a tree-ensemble number and a linear-model
    number take turns in one slot, and the series reads as one model getting
    better and worse on alternate weeks.
    """
    r = rows(CURRENT_SET + """
        SELECT DISTINCT ON (cur.target, m.horizon_weeks, m.algorithm)
               m.horizon_weeks, m.algorithm, m.feature_set_id,
               m.mae, m.baseline_persistence_mae,
               extract(epoch FROM m.trained_at)::bigint,
               cur.target
        FROM model_run m
        JOIN cur ON cur.fs = m.feature_set_id
        WHERE m.split_strategy = 'rolling_origin'
        ORDER BY cur.target, m.horizon_weeks, m.algorithm, m.trained_at DESC,
                 m.model_run_id DESC;""")
    if r is None:
        return None
    lines += [
        "# HELP mlops_run_mae Mean absolute error of the newest run per horizon and algorithm, current feature set.",
        "# TYPE mlops_run_mae gauge",
        "# HELP mlops_run_baseline_mae Persistence baseline MAE over the same folds.",
        "# TYPE mlops_run_baseline_mae gauge",
        "# HELP mlops_run_margin_ratio (baseline-mae)/baseline. Positive means the model beats persistence.",
        "# TYPE mlops_run_margin_ratio gauge",
        "# HELP mlops_run_trained_timestamp_seconds When that run was trained.",
        "# TYPE mlops_run_trained_timestamp_seconds gauge",
    ]
    for h, algo, fs, mae, base, trained, target in r:
        lbl = (f'{base_labels()},target="{esc(target)}",horizon="{esc(h)}",'
               f'algorithm="{esc(algo)}",feature_set="{esc(fs)}"')
        lines.append(f"mlops_run_mae{{{lbl}}} {float(mae)}")
        lines.append(f"mlops_run_baseline_mae{{{lbl}}} {float(base)}")
        m = margin(float(mae), float(base))
        if m is not None:
            lines.append(f"mlops_run_margin_ratio{{{lbl}}} {m}")
        lines.append(f"mlops_run_trained_timestamp_seconds{{{lbl}}} {int(trained)}")
    lines.append("")
    return len(r)


def horizon_totals(lines):
    """Per horizon: how many candidates exist, and has ANY of them ever passed.

    `mlops_horizon_gate_passed` is the t+1 fact turned into a series. Every
    run at t+1 has lost to persistence since 2026-08-20 (HGB by 12.08%, Ridge
    by 21.99%), so nothing has ever been published at that horizon. The board
    said so in a sentence; a sentence cannot be ranged over, and "how long has
    this been true" had no answer.
    """
    r = rows(CURRENT_SET + """
        SELECT cur.target, m.horizon_weeks, count(*),
               max(CASE WHEN m.beats_baselines THEN 1 ELSE 0 END)
        FROM model_run m JOIN cur ON cur.fs = m.feature_set_id
        WHERE m.split_strategy = 'rolling_origin'
        GROUP BY 1, 2 ORDER BY 1, 2;""")
    if r is None:
        return None
    lines += [
        "# HELP mlops_runs_total Candidate runs at this horizon in the current feature set.",
        "# TYPE mlops_runs_total gauge",
        "# HELP mlops_horizon_gate_passed 1 if any run at this horizon has ever beaten both baselines.",
        "# TYPE mlops_horizon_gate_passed gauge",
    ]
    for target, h, n, passed in r:
        lbl = f'{base_labels()},target="{esc(target)}",horizon="{esc(h)}"'
        lines.append(f"mlops_runs_total{{{lbl}}} {int(n)}")
        lines.append(f"mlops_horizon_gate_passed{{{lbl}}} {int(passed)}")
    lines.append("")
    return len(r)


def deployed(lines):
    """What is actually serving, and by how much it beats persistence.

    THE ONE NUMBER THIS FILE EXISTS FOR. Measured 2026-09-08 it is 0.0055 at
    t+2 -- smaller than the 2% margin ADR-0016 requires before REPLACING a
    champion. The exporter states both so the comparison is possible at all;
    it does not judge, because whether that is acceptable is a policy question
    and policy lives in the alert rules.
    """
    r = rows("""
        SELECT DISTINCT ON (fs.target, f.horizon_weeks)
               fs.target, f.horizon_weeks, f.model_run_id, m.mae,
               m.baseline_persistence_mae,
               extract(epoch FROM f.generated_at)::bigint
        FROM forecast f
        JOIN model_run m   ON m.model_run_id = f.model_run_id
        JOIN feature_set fs ON fs.feature_set_id = m.feature_set_id
        ORDER BY fs.target, f.horizon_weeks, f.forecast_id DESC;""")
    if r is None:
        return None
    lines += [
        "# HELP mlops_deployed_margin_ratio Relative advantage over persistence of the run behind the newest published forecast.",
        "# TYPE mlops_deployed_margin_ratio gauge",
        "# HELP mlops_deployed_run_id model_run_id of that run. A VALUE, not a label: run ids grow without limit.",
        "# TYPE mlops_deployed_run_id gauge",
        "# HELP mlops_deployed_published_timestamp_seconds When that forecast was written.",
        "# TYPE mlops_deployed_published_timestamp_seconds gauge",
    ]
    for target, h, run_id, mae, base, gen in r:
        lbl = f'{base_labels()},target="{esc(target)}",horizon="{esc(h)}"'
        m = margin(float(mae), float(base))
        if m is not None:
            lines.append(f"mlops_deployed_margin_ratio{{{lbl}}} {m}")
        lines.append(f"mlops_deployed_run_id{{{lbl}}} {int(run_id)}")
        lines.append(f"mlops_deployed_published_timestamp_seconds{{{lbl}}} {int(gen)}")
    lines.append("")
    return len(r)


def scoring(lines):
    """Did the published numbers turn out to be right? Per horizon.

    Backtest MAE is not this measurement. A fold scores a model against
    history it was fitted around; this scores the number that was actually
    published, against the week that actually arrived.

    n is tiny by construction -- 1 as of 2026-09-08, growing by roughly one
    per week because `retrain` is a weekly job and t+1 never publishes. That
    is exactly why it belongs in Prometheus: the question "when will n be big
    enough to say anything" is a question about a time series.
    """
    raw = dag.psql(dag.FORECAST_SCORE_SQL)
    if raw is None:
        return None
    scored_rows = dag.score_rows(raw)
    lines += [
        "# HELP mlops_forecast_scored_total Published forecasts whose target week has arrived and was compared.",
        "# TYPE mlops_forecast_scored_total gauge",
        "# HELP mlops_forecast_pending_total Published forecasts whose target week has not arrived yet.",
        "# TYPE mlops_forecast_pending_total gauge",
        "# HELP mlops_forecast_beat_baseline_total Of the scored ones, how many were closer than the value at origin.",
        "# TYPE mlops_forecast_beat_baseline_total gauge",
    ]
    for h, target, scored, pending, won in scored_rows:
        # THE TARGET IS A LABEL HERE, since 2026-09-09. Before that these three
        # series carried project and horizon only, on the reasoning that "there
        # is exactly one published horizon so nothing collides". That sentence
        # was true when written and stopped being true the day influenza was
        # published: `scored=1, pending=3` summed two targets into one bucket
        # and could not say which model the 1 belonged to. Nothing errored --
        # the numbers were still correct, just unattributable. It is the same
        # shape as the join bug T28 fixed, one step later in the pipeline.
        lbl = f'{base_labels()},horizon="{esc(h)}",target="{esc(target)}"'
        lines.append(f"mlops_forecast_scored_total{{{lbl}}} {scored}")
        lines.append(f"mlops_forecast_pending_total{{{lbl}}} {pending}")
        lines.append(f"mlops_forecast_beat_baseline_total{{{lbl}}} {won}")
    lines.append("")
    return len(scored_rows)


def feature_volume(lines):
    """The row count that gates everything upstream of the model.

    The warehouse holds 6.5M surveillance facts; the modelling table holds
    about 555 rows per feature set, because a weekly national rate for one
    disease is one row per week. Every "why not deep learning" conversation
    ends at this number, so it is worth being a series rather than a memory.
    """
    r = rows("""
        SELECT fr.feature_set_id, count(*), coalesce(fs.target, 'unknown')
        FROM feature_row fr
        JOIN feature_set fs ON fs.feature_set_id = fr.feature_set_id
        GROUP BY 1, 3 ORDER BY 1;""")
    if r is None:
        return None
    lines += [
        "# HELP mlops_feature_rows Rows available for training, per feature set.",
        "# TYPE mlops_feature_rows gauge",
    ]
    for fs, n, target in r:
        lines.append(f"mlops_feature_rows{{{base_labels()},"
                     f'feature_set="{esc(fs)}",target="{esc(target)}"}} {int(n)}')
    lines.append("")
    return len(r)


def policy_replay(lines):
    """The REPLAY's numbers, from the newest artifact per (horizon, mode).

    WHY THESE ARE A SEPARATE METRIC FAMILY AND NOT MORE SCORING METRICS.

    `mlops_forecast_scored_total` counts forecasts this platform really
    published: n=1. These count a simulation over history: n=383 at t+2. Both
    are honest; added together they would be a track record that is part
    measurement and part replay, and once both are numbers in a table an
    estimate and a measurement are indistinguishable. Different prefix,
    different HELP text, and a `mode` label that says which question was asked
    (`policy` = the gate could switch families, `locked` = it could not).

    Read from the artifact rather than recomputed: the replay costs ~21s per
    horizon inside the pilot's sklearn image, which does not belong in an
    hourly exporter. The artifact's own generated_at is emitted so a stale
    replay is visible as a stale replay rather than as a current one.
    """
    import glob
    d = os.path.join(REPO_ROOT, "evidence", "mlops")
    files = sorted(glob.glob(os.path.join(d, "policy_backtest_*.json")))
    if not files:
        return 0
    newest = {}
    for f in files:
        try:
            with open(f, encoding="utf-8") as fh:
                doc = json.load(fh)
        except (OSError, ValueError):
            # A half-written or truncated artifact is skipped, not guessed at.
            continue
        mode = "locked" if doc.get("lock_family") else "policy"
        # Keyed on the TARGET as well: two targets exist, and keyed on
        # (horizon, mode) alone the influenza artifact and the ILI artifact for
        # the same horizon overwrote each other -- whichever sorted last
        # silently became "the" result, for a different disease.
        key = (doc.get("target") or f"fs{doc.get('feature_set')}",
               doc.get("horizon"), mode)
        prev = newest.get(key)
        if prev is None or doc.get("generated_at", "") >= prev.get("generated_at", ""):
            newest[key] = doc
    if not newest:
        return 0
    lines += [
        "# HELP mlops_policy_backtest_n Origins at which a REPLAY of the publishing decision would have published. A simulation, not the live record.",
        "# TYPE mlops_policy_backtest_n gauge",
        "# HELP mlops_policy_backtest_origins Origins walked by that replay.",
        "# TYPE mlops_policy_backtest_origins gauge",
        "# HELP mlops_policy_backtest_win_rate Share of published origins where the replay was closer than persistence.",
        "# TYPE mlops_policy_backtest_win_rate gauge",
        "# HELP mlops_policy_backtest_margin_ratio Relative MAE advantage of the replayed published series over persistence. Negative means the system would have been worse than doing nothing.",
        "# TYPE mlops_policy_backtest_margin_ratio gauge",
        "# HELP mlops_policy_backtest_generated_timestamp_seconds When that replay ran.",
        "# TYPE mlops_policy_backtest_generated_timestamp_seconds gauge",
    ]
    for (target, h, mode), doc in sorted(newest.items(),
                                        key=lambda kv: str(kv[0])):
        sm = doc.get("summary") or {}
        lbl = (f'{base_labels()},target="{esc(target)}",horizon="{esc(h)}",'
               f'mode="{esc(mode)}"')
        lines.append(f"mlops_policy_backtest_n{{{lbl}}} {int(sm.get('n', 0))}")
        lines.append(f"mlops_policy_backtest_origins{{{lbl}}} "
                     f"{int(sm.get('n_origins', 0))}")
        for key, metric in (("win_rate", "mlops_policy_backtest_win_rate"),
                            ("margin_ratio",
                             "mlops_policy_backtest_margin_ratio")):
            v = sm.get(key)
            if v is not None:
                lines.append(f"{metric}{{{lbl}}} {float(v)}")
        ts = doc.get("generated_at")
        if ts:
            try:
                epoch = int(calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")))
                lines.append("mlops_policy_backtest_generated_timestamp_seconds"
                             f"{{{lbl}}} {epoch}")
            except ValueError:
                pass
    lines.append("")
    return len(newest)


def replay_significance(lines):
    """The interval around the replay's margin, and the p-value.

    WHY THE MARGIN MUST NOT BE EMITTED ALONE.

    The replay's headline at t+2 is -3.60%, which reads as "the system is worse
    than persistence". The paired bootstrap interval is [-11.92%, +3.43%] and
    it INCLUDES ZERO, and the sign test on 196 wins out of 383 gives p=0.68.
    The defensible statement is therefore not "worse" but "indistinguishable
    from persistence at n=383" -- a different claim, and the one a panel
    showing only the point estimate would silently overwrite.

    A point estimate published without its interval is the same failure this
    repo already catalogues one level down: an estimate and a measurement are
    indistinguishable once both are numbers in a table.
    """
    import glob
    d = os.path.join(REPO_ROOT, "evidence", "mlops")
    files = sorted(glob.glob(os.path.join(d, "replay_significance_*.json")))
    if not files:
        return 0
    try:
        with open(files[-1], encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return 0
    results = doc.get("results") or []
    if not results:
        return 0
    lines += [
        "# HELP mlops_policy_backtest_margin_ci_low Lower bound of a 95% paired-bootstrap interval on the replay's margin.",
        "# TYPE mlops_policy_backtest_margin_ci_low gauge",
        "# HELP mlops_policy_backtest_margin_ci_high Upper bound of that interval. If low<0<high the margin is not distinguishable from zero.",
        "# TYPE mlops_policy_backtest_margin_ci_high gauge",
        "# HELP mlops_policy_backtest_sign_test_p Two-sided exact binomial p-value for the win rate against 0.5.",
        "# TYPE mlops_policy_backtest_sign_test_p gauge",
        "# HELP mlops_policy_backtest_lag1_autocorrelation Lag-1 autocorrelation of the weekly paired differences. Both procedures assume independence, so a large value means the interval is too NARROW.",
        "# TYPE mlops_policy_backtest_lag1_autocorrelation gauge",
    ]
    for r in results:
        lbl = (f'{base_labels()},'
               f'target="{esc(r.get("target"))}",'
               f'horizon="{esc(r.get("horizon"))}",'
               f'mode="{esc(r.get("mode"))}"')
        ci = r.get("ci95")
        if ci:
            lines.append(f"mlops_policy_backtest_margin_ci_low{{{lbl}}} {float(ci[0])}")
            lines.append(f"mlops_policy_backtest_margin_ci_high{{{lbl}}} {float(ci[1])}")
        for key, metric in (("sign_test_p", "mlops_policy_backtest_sign_test_p"),
                            ("lag1_autocorrelation",
                             "mlops_policy_backtest_lag1_autocorrelation")):
            v = r.get(key)
            if v is not None:
                lines.append(f"{metric}{{{lbl}}} {float(v)}")
    lines.append("")
    return len(results)


def policy(lines):
    """The replacement margin, READ from the publisher rather than retyped.

    Same argument as dag.py's replacement_margin(): a dashboard or an alert
    that keeps its own copy of a threshold will eventually state one the
    system does not enforce, and it will still render.
    """
    m = dag.replacement_margin()
    if m is None:
        return 0
    lines += [
        "# HELP mlops_replacement_margin_ratio Relative MAE improvement a challenger needs to replace the champion (ADR-0016). Read from publish_forecast.py.",
        "# TYPE mlops_replacement_margin_ratio gauge",
        f"mlops_replacement_margin_ratio{{{base_labels()}}} {m}",
        "",
    ]
    return 1


def main():
    lines = [
        "# Generated by platform/mlops/pipeline_metrics.py.",
        "# Numbers only -- every threshold lives in",
        "# platform/observability/prometheus/alerts/mlops.yml.",
        "",
    ]
    counts = {}
    for name, fn in (("runs", latest_runs), ("horizons", horizon_totals),
                     ("deployed", deployed), ("scored", scoring),
                     ("features", feature_volume), ("replay", policy_replay),
                     ("significance", replay_significance),
                     ("policy", policy)):
        counts[name] = fn(lines)

    db_sections = [v for k, v in counts.items()
                   if k not in ("replay", "significance", "policy")]
    if all(v is None for v in db_sections):
        # Every section failed to reach the database. Writing a file of
        # nothing but a timestamp would look FRESH to the freshness alert
        # while carrying no measurement at all -- the exact failure this
        # platform keeps finding. Refuse instead, and let the staleness rule
        # be the one that speaks.
        print("cannot reach the pilot database -- no metrics written",
              file=sys.stderr)
        return 78

    lines += [
        "# HELP mlops_metrics_generated_timestamp_seconds When this file was written.",
        "# TYPE mlops_metrics_generated_timestamp_seconds gauge",
        f"mlops_metrics_generated_timestamp_seconds {int(time.time())}",
        "",
    ]
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = OUT + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    # Atomic rename: node-exporter reads this directory continuously, and a
    # half-written .prom makes it drop EVERY file in the directory, not just
    # this one.
    os.replace(tmp, OUT)
    print("mlops metrics: " + ", ".join(
        f"{k}={'unreachable' if v is None else v}" for k, v in counts.items()))
    print(f"artifact={OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

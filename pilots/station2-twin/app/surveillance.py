"""The twin's model and divergence detection.

A state store plus a REST API is not a digital twin. A twin needs something
that says what the entity was EXPECTED to do, so that the gap between
expectation and observation means something. For disease surveillance that
gap is the entire product: it is the outbreak signal.

METHOD: historical limits (CDC's classic aberration-detection method).

For the target week, take the same ISO week +/- 1 in each of the previous
`baseline_years` years. That is 15 comparison points for a 5-year baseline.
Compute mean and standard deviation, then a z-score for the observation.

    z = (observed - mean) / sd

Chosen over anything more sophisticated on purpose. This pilot exists to
exercise the DevOps platform, not to advance epidemiology, and a method a
hospital administrator can follow in one sentence is worth more here than a
better AUC nobody can interrogate. It is also the method public health
practitioners already recognise, which matters when the output is shown to
them.

WHY +/- 1 WEEK: a single historical week is a sample of five, and respiratory
season timing shifts by a week or two year to year. Widening the window
trades a little sharpness for a baseline that does not swing on one
anomalous year.

WHAT THIS DELIBERATELY DOES NOT DO: no trend term, no population
denominator, no reporting-delay correction. Each of those is a real
epidemiological requirement and each is listed in the pilot's known gaps
rather than being approximated badly here. An honest z-score with stated
limits is more useful than a sophisticated number nobody can defend.

── WHY THIS MODULE NOW NAMES ITS SOURCE AND ITS METRIC ─────────────────────

It used to read surveillance_observations, a single-source table where every
row was a weekly county ILI count, so "the data" was unambiguous. It now reads
surveillance_fact, which holds four feeds at three granularities and two
measure types -- including 4.1M rows of TB cases *under management*, which is
a STOCK.

Feeding a stock into this model would produce a confident, plausible, entirely
meaningless z-score: the baseline would be built from "how many people were
mid-treatment in this week five years ago", and summing it across weeks counts
the same patient once per day of a nine-month course. Nothing about the number
would look wrong.

So the model does not accept a disease and go looking. Each supported disease
is bound here to exactly one (source, metric, time_level), and a disease with
no binding is refused by name rather than answered from whatever happens to
match. Adding TB to this model is not a matter of adding a row to MODELS -- it
needs an incidence feed, or a method that understands prevalence.
"""

BASELINE_YEARS = 5
WEEK_WINDOW = 1
# Above 2 sd is the conventional "exceeds historical limits" line. Kept as a
# named constant because it is a policy choice, not a fact -- the threshold
# that suits a 500-bed hospital's staffing decision is not necessarily the
# one that suits a national alert.
ALERT_Z = 2.0

# disease -> the one series this model is entitled to read for it.
#
# RODS rather than NHI, though NHI carries a denominator and would give a rate:
# RODS is emergency-department presentations, which is the signal a hospital
# actually staffs against, and it reaches back to 2007 where NHI starts in
# 2016 -- a five-year baseline needs the history.
MODELS = {
    "influenza_like_illness": {
        "source": "cdc-rods-ili",
        "metric": "ili_ed_visits",
        "time_level": "epi_week",
    },
}


class UnmodelledDisease(Exception):
    """Asked for a disease this model has no defensible series for."""


def model_for(disease):
    try:
        return MODELS[disease]
    except KeyError:
        raise UnmodelledDisease(disease) from None


# Every query below funnels through this join and this filter, so a caller
# cannot accidentally widen the series by forgetting a predicate. Source,
# metric and time_level are all pinned: without the metric predicate the same
# geo/period would match TB stock rows as well.
def _from(with_geo=False):
    geo = ("\n      JOIN geo_area    g ON g.geo_code   = f.geo_code"
           if with_geo else "")
    return f"""
      FROM surveillance_fact f
      JOIN data_source s ON s.source_id  = f.source_id
      JOIN metric      m ON m.metric_id  = f.metric_id
      JOIN disease     d ON d.disease_id = f.disease_id
      JOIN time_period t ON t.period_id  = f.period_id{geo}
     WHERE s.code = %(source)s AND m.code = %(metric)s AND d.code = %(disease)s
       AND t.time_level = %(time_level)s
"""


_FROM = _from()


def _params(disease, **extra):
    m = model_for(disease)
    return {"source": m["source"], "metric": m["metric"],
            "disease": disease, "time_level": m["time_level"], **extra}


def _baseline_rows(cur, disease, county_code, year, week):
    """Same week +/- window, previous N years. Excludes the target year."""
    weeks = [((week - 1 + d) % 53) + 1 for d in range(-WEEK_WINDOW, WEEK_WINDOW + 1)]
    cur.execute(
        f"""
        SELECT t.epi_year, t.epi_week, SUM(f.value)::float
        {_FROM}
           AND f.geo_code = %(geo)s
           AND t.epi_year BETWEEN %(from_year)s AND %(to_year)s
           AND t.epi_week = ANY(%(weeks)s)
         GROUP BY t.epi_year, t.epi_week
        """,
        _params(disease, geo=county_code, weeks=weeks,
                from_year=year - BASELINE_YEARS, to_year=year - 1))
    return [r[2] for r in cur.fetchall()]


def observed(cur, disease, county_code, year, week):
    """The observed total, or None if the week was never reported.

    Returns None rather than 0.0 for an absent week. The previous version used
    COALESCE(SUM(visits), 0), which made "the county reported nothing" and "the
    county reported zero visits" the same number -- and then handed that zero
    to a z-score, where a reporting outage during a bad season renders as a
    strongly NEGATIVE divergence. That is the missing-is-not-zero rule the
    schema enforces, quietly discarded one layer above it.
    """
    cur.execute(
        f"""
        SELECT SUM(f.value)::float
        {_FROM}
           AND f.geo_code = %(geo)s
           AND t.epi_year = %(year)s AND t.epi_week = %(week)s
        """,
        _params(disease, geo=county_code, year=year, week=week))
    row = cur.fetchone()
    return None if row is None or row[0] is None else float(row[0])


def _stats(values):
    n = len(values)
    if n == 0:
        return None, None, 0
    mean = sum(values) / n
    if n < 2:
        return mean, None, n
    var = sum((v - mean) ** 2 for v in values) / (n - 1)
    return mean, var ** 0.5, n


def divergence(cur, disease, county_code, year, week):
    """Observed vs expected for one county-week. The twin's actual output."""
    model = model_for(disease)
    obs = observed(cur, disease, county_code, year, week)
    base = _baseline_rows(cur, disease, county_code, year, week)
    mean, sd, n = _stats(base)

    result = {
        "disease": disease,
        "county_code": county_code,
        "epi_year": year,
        "epi_week": week,
        "observed": obs,
        "baseline_mean": round(mean, 1) if mean is not None else None,
        "baseline_sd": round(sd, 1) if sd is not None else None,
        "baseline_n": n,
        "baseline_years": BASELINE_YEARS,
        "week_window": WEEK_WINDOW,
        # State which series produced this, so a number on a dashboard can be
        # traced back to a feed without reading the code.
        "source": model["source"],
        "metric": model["metric"],
    }

    # Not reported is its own answer, and it is not a low week.
    if obs is None:
        result.update(status="not_reported", z_score=None, alert=False,
                      detail="no observation for this county-week")
        return result

    # Insufficient history is its own answer, not a zero.
    #
    # Returning z=0 when there is nothing to compare against would render as
    # "normal" on any dashboard -- the single most dangerous output this
    # module could produce, because it is indistinguishable from a real
    # all-clear. Same principle as the platform's exit-3 UNKNOWN: not knowing
    # is a distinct state from being fine.
    if mean is None or n < 3:
        result.update(status="insufficient_baseline", z_score=None, alert=False,
                      detail=f"only {n} historical point(s); need 3")
        return result

    if sd is None or sd == 0:
        # A flat history means any deviation is infinitely many sd's. Report
        # the ratio instead of dividing by zero and calling it certainty.
        result.update(status="degenerate_baseline", z_score=None,
                      alert=obs > mean, detail="baseline has zero variance")
        return result

    z = (obs - mean) / sd
    result.update(
        status="ok",
        z_score=round(z, 2),
        ratio_to_mean=round(obs / mean, 2) if mean else None,
        upper_limit=round(mean + ALERT_Z * sd, 1),
        alert=bool(z > ALERT_Z),
        alert_threshold_z=ALERT_Z,
    )
    return result


def latest_week(cur, disease):
    cur.execute(
        f"""
        SELECT t.epi_year, t.epi_week
        {_FROM}
         ORDER BY t.epi_year DESC, t.epi_week DESC
         LIMIT 1
        """,
        _params(disease))
    row = cur.fetchone()
    return (row[0], row[1]) if row else (None, None)


def series(cur, disease, county_code, weeks=26):
    cur.execute(
        f"""
        SELECT t.epi_year, t.epi_week, SUM(f.value)::int
        {_FROM}
           AND f.geo_code = %(geo)s
         GROUP BY t.epi_year, t.epi_week
         ORDER BY t.epi_year DESC, t.epi_week DESC
         LIMIT %(limit)s
        """,
        _params(disease, geo=county_code, limit=weeks))
    rows = cur.fetchall()
    return [{"epi_year": r[0], "epi_week": r[1], "visits": r[2]}
            for r in reversed(rows)]


def scan(cur, disease, year, week):
    """Divergence for every county in one week -- the operational view.

    The county list is every county this FEED has ever covered, not every
    county that reported THIS week. A county whose surveillance just failed
    therefore still appears, as not_reported -- which is the row an operator
    most needs to see. Selecting on the target week instead would drop it
    silently, and a shorter list reads as "nothing wrong there".
    """
    cur.execute(
        f"""
        SELECT DISTINCT f.geo_code, g.name
        {_from(with_geo=True)}
           AND g.geo_level = 'county'
         ORDER BY f.geo_code
        """,
        _params(disease))
    counties = cur.fetchall()
    out = []
    for code, name in counties:
        d = divergence(cur, disease, code, year, week)
        d["county"] = name
        out.append(d)
    # Alerts first, then by how far above expectation.
    out.sort(key=lambda d: (not d["alert"], -(d.get("z_score") or -99)))
    return out

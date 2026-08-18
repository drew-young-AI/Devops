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
"""

BASELINE_YEARS = 5
WEEK_WINDOW = 1
# Above 2 sd is the conventional "exceeds historical limits" line. Kept as a
# named constant because it is a policy choice, not a fact -- the threshold
# that suits a 500-bed hospital's staffing decision is not necessarily the
# one that suits a national alert.
ALERT_Z = 2.0


def _baseline_rows(cur, disease, county_code, year, week):
    """Same week +/- window, previous N years. Excludes the target year."""
    weeks = [((week - 1 + d) % 53) + 1 for d in range(-WEEK_WINDOW, WEEK_WINDOW + 1)]
    cur.execute(
        """
        SELECT epi_year, epi_week, SUM(visits)::float
          FROM surveillance_observations
         WHERE disease = %s AND county_code = %s
           AND epi_year BETWEEN %s AND %s
           AND epi_week = ANY(%s)
         GROUP BY epi_year, epi_week
        """,
        (disease, county_code, year - BASELINE_YEARS, year - 1, weeks),
    )
    return [r[2] for r in cur.fetchall()]


def observed(cur, disease, county_code, year, week):
    cur.execute(
        """
        SELECT COALESCE(SUM(visits), 0)::float
          FROM surveillance_observations
         WHERE disease = %s AND county_code = %s
           AND epi_year = %s AND epi_week = %s
        """,
        (disease, county_code, year, week),
    )
    row = cur.fetchone()
    return float(row[0]) if row else 0.0


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
    }

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
        """
        SELECT epi_year, epi_week
          FROM surveillance_observations
         WHERE disease = %s
         ORDER BY epi_year DESC, epi_week DESC
         LIMIT 1
        """,
        (disease,),
    )
    row = cur.fetchone()
    return (row[0], row[1]) if row else (None, None)


def series(cur, disease, county_code, weeks=26):
    cur.execute(
        """
        SELECT epi_year, epi_week, SUM(visits)::int
          FROM surveillance_observations
         WHERE disease = %s AND county_code = %s
         GROUP BY epi_year, epi_week
         ORDER BY epi_year DESC, epi_week DESC
         LIMIT %s
        """,
        (disease, county_code, weeks),
    )
    rows = cur.fetchall()
    return [{"epi_year": r[0], "epi_week": r[1], "visits": r[2]}
            for r in reversed(rows)]


def scan(cur, disease, year, week):
    """Divergence for every county in one week -- the operational view."""
    cur.execute(
        """
        SELECT DISTINCT county_code, county
          FROM surveillance_observations
         WHERE disease = %s
         ORDER BY county_code
        """,
        (disease,),
    )
    counties = cur.fetchall()
    out = []
    for code, name in counties:
        d = divergence(cur, disease, code, year, week)
        d["county"] = name
        out.append(d)
    # Alerts first, then by how far above expectation.
    out.sort(key=lambda d: (not d["alert"], -(d.get("z_score") or -99)))
    return out

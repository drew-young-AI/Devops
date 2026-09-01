#!/usr/bin/env python3
"""Static audit of the Grafana dashboards.

WHY THIS EXISTS.

On 2026-08-29 every panel of `platform-stages.json` -- the board meant for a
reviewer to open -- was querying datasource uid "prometheus", which does not
exist. Grafana answers `{"message":"Data source not found"}` and the panel
renders empty. An empty panel and a healthy platform look identical.

Nothing could have caught it: the JSON was valid, the PromQL was valid, the
metrics existed, and no test read the dashboards at all. The three checks here
are the three ways a dashboard can be confidently wrong while parsing fine:

  1. it points at a datasource that is not provisioned
  2. it queries a metric nobody produces
  3. it restates a fact that lives somewhere else, and drifts from it

Run with --check to audit, or as a library from the test suite.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
# Overridable so the test suite can point the audit at a fixture copy and
# break each rule on purpose. A guard nobody has watched fail is a guard
# nobody has any reason to trust.
DASH_DIR = os.environ.get(
    "DASHBOARDS_DIR",
    os.path.join(ROOT, "platform/observability/grafana/dashboards"))
DS_FILE = os.path.join(ROOT, "platform/observability/grafana/provisioning/"
                             "datasources/datasources.yml")
ALERT_DIR = os.path.join(ROOT, "platform/observability/prometheus/alerts")
PROM_DIR = os.path.join(ROOT, "evidence/statusdag")

# PromQL vocabulary. Anything matching the metric-name shape that is actually a
# function, keyword or modifier. Kept explicit rather than "starts with a known
# prefix": a whitelist of prefixes would pass a typo'd metric in the same family.
PROMQL_WORDS = {
    "sum", "count", "min", "max", "avg", "stddev", "stdvar", "topk", "bottomk",
    "quantile", "count_values", "group", "rate", "irate", "increase", "delta",
    "idelta", "deriv", "predict_linear", "holt_winters", "abs", "ceil", "floor",
    "round", "clamp", "clamp_max", "clamp_min", "exp", "ln", "log2", "log10",
    "sqrt", "time", "timestamp", "vector", "scalar", "absent", "absent_over_time",
    "changes", "resets", "sort", "sort_desc", "label_replace", "label_join",
    "histogram_quantile", "day_of_week", "day_of_month", "days_in_month", "hour",
    "minute", "month", "year", "by", "without", "on", "ignoring", "group_left",
    "group_right", "offset", "and", "or", "unless", "bool", "start", "end",
    "avg_over_time", "sum_over_time", "max_over_time", "min_over_time",
    "count_over_time", "last_over_time", "present_over_time", "quantile_over_time",
    "stddev_over_time", "stdvar_over_time", "humanize", "humanizeDuration",
    "humanizePercentage", "humanize1024", "inf", "nan",
}
NAME_RE = re.compile(r"[a-zA-Z_:][a-zA-Z0-9_:]*")
# Label matchers and string literals must be stripped first, or label VALUES
# (e.g. state="ok") get mistaken for metric names.
STRIP_RE = re.compile(r'"[^"]*"' r"|'[^']*'" r"|\{[^}]*\}" r"|\[[^\]]*\]")


def dashboards():
    for f in sorted(os.listdir(DASH_DIR)):
        if f.endswith(".json"):
            path = os.path.join(DASH_DIR, f)
            with open(path, encoding="utf-8") as fh:
                yield f, json.load(fh)


def provisioned_uids():
    uids = set()
    with open(DS_FILE, encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r"\s*uid:\s*(\S+)", line)
            if m:
                uids.add(m.group(1).strip("\"'"))
    return uids


def referenced_uids(dash):
    out = set()

    def walk(o):
        if isinstance(o, dict):
            if "uid" in o and o.get("type") in ("prometheus", "loki",
                                                "alertmanager"):
                out.add(o["uid"])
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(dash.get("panels", []))
    return out


def exprs(dash):
    for p in dash.get("panels", []):
        for t in p.get("targets", []):
            if t.get("expr"):
                yield p.get("title", "?"), t["expr"]


def metric_names(expr):
    return {n for n in NAME_RE.findall(STRIP_RE.sub(" ", expr))
            if n not in PROMQL_WORDS and not n.isdigit()}


# Synthesised by Prometheus itself; no exporter emits them.
SYNTHETIC = {"up", "ALERTS", "ALERTS_FOR_STATE", "scrape_duration_seconds",
             "scrape_samples_scraped", "scrape_samples_post_metric_relabeling",
             "scrape_series_added", "scrape_body_size_bytes"}


def live_metric_names(url=None):
    """The authority, when it is reachable.

    Textfile exports and recording rules cover only what THIS repo produces.
    A dashboard may legitimately query a metric a scraped application exposes
    (station2_* comes from the pilot's own /metrics), and it is exactly those
    that vanish silently when a service is retired -- service-health.yml's
    header records rules that stayed green for weeks watching a deleted
    service. So ask the running Prometheus what exists.

    Returns None when unreachable, which the caller must treat as UNVERIFIED
    rather than as permission to pass.
    """
    import urllib.request
    url = url or os.environ.get("PROM_URL", "http://127.0.0.1:19090")
    try:
        with urllib.request.urlopen(
                url + "/api/v1/label/__name__/values", timeout=8) as r:
            return set(json.load(r)["data"])
    except Exception:  # noqa: BLE001
        return None


def produced_metrics():
    """Names that actually exist: emitted by an exporter, or defined as a
    recording rule. A recording rule counts -- it is produced by Prometheus."""
    names = set(SYNTHETIC)
    for f in sorted(os.listdir(PROM_DIR)):
        if f.endswith(".prom"):
            with open(os.path.join(PROM_DIR, f), encoding="utf-8") as fh:
                for line in fh:
                    if line.startswith("# TYPE "):
                        names.add(line.split()[2])
    for f in sorted(os.listdir(ALERT_DIR)):
        if f.endswith(".yml"):
            with open(os.path.join(ALERT_DIR, f), encoding="utf-8") as fh:
                for line in fh:
                    m = re.match(r"\s*-?\s*record:\s*(\S+)", line)
                    if m:
                        names.add(m.group(1))
    return names


def rank_from_dag():
    sys.path.insert(0, os.path.join(ROOT, "platform/statusdag"))
    from dag import RANK  # noqa: E402
    return RANK


def audit():
    problems = []
    unverified = []
    uids = provisioned_uids()
    produced = produced_metrics()
    live = live_metric_names()
    if live is not None:
        produced |= live
    rank = rank_from_dag()
    seen_uid = {}

    for name, dash in dashboards():
        duid = dash.get("uid")
        if duid in seen_uid:
            problems.append(f"{name}: dashboard uid {duid!r} also used by "
                            f"{seen_uid[duid]} -- Grafana keeps one and silently "
                            "drops the other")
        seen_uid[duid] = name

        for u in sorted(referenced_uids(dash) - uids):
            problems.append(
                f"{name}: queries datasource uid {u!r}, which is not in "
                "datasources.yml. Grafana answers 'Data source not found' and "
                "the panel renders empty -- indistinguishable from healthy.")

        for title, expr in exprs(dash):
            for m in sorted(metric_names(expr) - produced):
                if live is None:
                    unverified.append(
                        f"{name}: panel {title!r} queries {m!r}; no local "
                        "exporter or recording rule defines it and Prometheus "
                        "is unreachable, so its existence is UNVERIFIED.")
                    continue
                problems.append(
                    f"{name}: panel {title!r} queries {m!r}, which nothing "
                    "produces -- not an exporter, not a recording rule, and "
                    "not the live Prometheus. It will draw nothing, forever, "
                    "and look calm doing it.")
            # A panel listing individual node names is a second copy of
            # stage_report.py's LINES. The `layer` label already carries the
            # membership; a hand-kept list is a thing that goes stale silently.
            if re.search(r'node=~"[a-z]+\|[a-z]+\|[a-z|]+"', expr):
                problems.append(
                    f"{name}: panel {title!r} hardcodes a node list. Use the "
                    "`layer` label -- the list is a copy of LINES that nothing "
                    "keeps in step.")

        for p in dash.get("panels", []):
            has_code = any("devops_node_state_code" in t.get("expr", "")
                           for t in p.get("targets", []))
            for mp in p.get("fieldConfig", {}).get("defaults", {}).get(
                    "mappings", []):
                if mp.get("type") != "value" or not has_code:
                    continue
                got = {k: v.get("text") for k, v in mp["options"].items()}
                want = {str(v) for v in rank.values()}
                if set(got) != want:
                    problems.append(
                        f"{name}: panel {p.get('title')!r} maps codes "
                        f"{sorted(got)} but dag.py's RANK is {sorted(want)}. "
                        "RANK reorders when a state is inserted -- SUPERSEDED "
                        "already did that once -- and a stale mapping labels "
                        "every band wrong while still rendering.")
    return problems, unverified


if __name__ == "__main__":
    probs, unver = audit()
    for p in probs:
        print("  FAIL  " + p)
    for u in unver:
        print("  UNVERIFIED  " + u)
    print(f"{len(probs)} problem(s), {len(unver)} unverified")
    sys.exit(1 if probs else 0)

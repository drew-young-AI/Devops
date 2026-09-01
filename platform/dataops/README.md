---
type: platform-adapter
title: DataOps 指標
description: Freshness, distribution drift and execution health -- the three things write-time constraints cannot see.
tags:
  - dataops
  - monitoring
  - data-quality
timestamp: 2026-09-01T09:53:38+08:00
---

# platform/dataops — the three things write-time constraints cannot see

## Start here

```bash
platform/dataops/run.sh           # compute metrics, write the textfile collector
```

Requires the analytics venv: `platform/analytics/setup.sh`. It deliberately
reuses that venv rather than creating a second one — duckdb and psycopg2 are
exactly the dependencies it needs, and two venvs holding the same pins are two
things to keep in step.

## Why this exists

Data **quality** is already enforced at write time by `CHECK` constraints, and
those do not need monitoring: a constraint never fails, it refuses. Monitoring
belongs where constraints are blind:

1. **Freshness** — a source that should have updated and did not. A constraint
   cannot see a thing that did not happen.
2. **Distribution drift** — data that is legal but changed (a county's case
   count halving). Constraints check format and conservation, not distribution.
3. **Execution health** — batch duration and reject-rate trend, from
   `ingest_runs`.

## The exporter emits no verdicts, on purpose

`pipeline_metrics.py` emits only ages and ratios. Every judgement — what counts
as too old, what counts as too much drift — lives in
`platform/observability/prometheus/alerts/dataops.yml`, so the thresholds are
one reviewable list rather than numbers buried in a Python file nobody opens.

## The defect this area produced, worth remembering

`WidespreadGeoDrift` joins two metric families and needs an explicit
`group_left`. Without it the rule **parses**, `promtool check rules` reports
SUCCESS, and evaluation fails every single cycle — so the rule reads as
"configured" and can never fire. It shipped on 2026-08-28 and stood for 11
hours. This is the origin of ADR-0007: *verify by evaluation, not by parsing*.

## Files

| File | What it does |
|---|---|
| `run.sh` | Entry point; resolves the DB password from the running container. |
| `pipeline_metrics.py` | Emits ages and ratios as Prometheus textfile metrics. |
| `settled_week.py` | Decides which epidemiological weeks are settled enough to compare. |

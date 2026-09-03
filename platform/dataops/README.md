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


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`dataops/ingest.sh`](ingest.sh) | 排程（每日 03:00） | 拉取 19 支週報監測 feed 並 upsert 進 `surveillance_fact` | **這條線在 2026-09-03 之前根本不存在**：載入器 2026-08-20 手動跑過一次，之後 jobs.conf 的 19 個 job 沒有一個抓資料，下游全部在一份不再變動的資料上維持綠燈。每日而非每週，因為疾管署不公告星期幾發布 |
| [`dataops/run.sh`](run.sh) | 排程 | 入口 | **重用 analytics 的 venv 不另建一個**：需要的正好就是 duckdb 與 psycopg2，兩個 venv 釘同一組版本＝兩個要同步的東西 |
| [`pipeline_metrics.py`](pipeline_metrics.py) | 排程 | 產出資料庫約束**抓不到**的三件事的指標 | 約束能擋住壞資料進來，擋不住「該來的沒來」「來得太晚」「來了但語意變了」 |
| [`settled_week.py`](settled_week.py) | 由指標流程呼叫 | 決定漂移比較用哪一個流行病學週、落後資料多久 | 週定義是這條線唯一還沒有權威來源的參數（要問疾管署），所以它被獨立出來而不是散在各處 |

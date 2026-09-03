---
type: platform-adapter
title: 狀態 DAG 與階段看板
description: Traffic lights on the platform's own mechanisms, and the blast radius only a DAG can express.
tags:
  - statusdag
  - observability
  - board
timestamp: 2026-09-01T09:53:38+08:00
---

# platform/statusdag — what is broken, and what it takes down with it

## Two boards, different questions

```
valuestream/board.py   "where is my work?"           nodes are commits
statusdag/dag.py       "what is broken right now,    nodes are mechanisms
                        and what does it take down?"
```

## Start here

```bash
python3 platform/statusdag/dag.py            # node states
python3 platform/statusdag/stage_report.py   # the reviewer-facing HTML board
```

The board is served at `http://mac.local:18085/Stage-Report.html`.

## What only a DAG can express: blast radius

Vault sits upstream of identity, CI credentials, the Grafana admin login and the
audit trail. A flat status list shows four green rows and one red one, and says
nothing about the fact that the four are green only because nothing has asked
them anything yet. The edges are the point.

## The rule this directory keeps re-learning

A node added to `dag.py` and not to the report's `LINES` **disappears from the
report**, and a missing stage reads exactly like a healthy one. That coverage
guard lives in `platform/tests/test_stage_report.sh` and is the reason that
suite exists.

The same shape has now occurred four times across the platform: a threshold in
`install.sh` and again in its test; `LINES` in `stage_report.py` and again as a
regex in a dashboard; `RANK` in `dag.py` and again as a Grafana value mapping; a
drift expression in an alert and again in a panel. **One definition, many
readers** — never two copies.

## Known gaps

1. **No `iac` node.** The Infrastructure-as-Code layer is not represented on the
   board at all, so the board has never had an opinion about it — which is part
   of why `platform/iac/` went unverified for months.
2. **No CI node.** GitHub Actions was red for at least six days with nobody
   notified, because CI state reaches no board and no channel.
3. `llmreview` is SUPERSEDED: its input comes from the retired Compose path and
   it has not been reconnected to the Kubernetes artefacts.


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`dag.py`](dag.py) | 排程，每 15 分鐘 | 現場探測每個節點，產出值班者看的板子 | 一個節點一列，問的是「哪些容器活著」。**退役 Pilot 的證據會落到 `SUPERSEDED` 而不是被當成現況** |
| [`stage_report.py`](stage_report.py) | 排程，跟著 `dag` 走 | 把同一批探測重組成**階段**，一份模型三種輸出 | `html` 給人與長官、`json` 給程式、`md` 給 AI（4KB）。**新增節點沒加進 `LINES` 就直接拒絕產生報告**——消失的階段讀起來和健康的階段一模一樣 |

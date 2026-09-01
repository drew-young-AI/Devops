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

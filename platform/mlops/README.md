---
type: platform-adapter
title: MLOps 週期重訓與發布閘門
description: Weekly retraining with a publication gate that is currently, and correctly, refusing to publish.
tags:
  - mlops
  - model-gate
timestamp: 2026-09-01T09:53:38+08:00
---

# platform/mlops — weekly retrain, and a gate that is allowed to say no

## Start here

```bash
platform/mlops/retrain.sh         # rebuild features, re-backtest, publish only if it qualifies
```

## Why weekly

The cadence comes from how fast the thing it watches can change. The source is
**weekly** surveillance data published with roughly a two-week lag. Retraining
daily would rebuild an identical feature set six days out of seven and write six
`model_run` rows differing only by timestamp — noise that makes the one real
weekly change harder to see.

## The gate is the valuable part

Publishing is not a separate decision made by a human afterwards. A model is
published only if it beats the incumbent on the backtest; otherwise the run
completes, records why, and publishes nothing.

**The gate is currently refusing to publish, and that is the correct outcome.**
The candidate loses to a persistence baseline (t+1 −12.31%, t+2 +0.32%). A gate
that has never said no is not a gate — it is a formality — so this state is
evidence the mechanism works, not evidence that MLOps is broken. It appears on
the board as `mgate: warn`, which is honest: the pipeline is healthy, the model
is not good enough.

## Known gaps

1. **No golden evaluation set.** Non-determinism is detectable today (the same
   `inputs_digest` producing different conclusions is a catchable failure), but
   **quality regression is not**: change the prompt or the features and nothing
   answers whether the result got better or worse.
2. **Cross-architecture numerics are unverified.** BLAS can differ in the last
   bits between arm64 and amd64. If a model is ever trained on the Mac and
   scored on the Ubuntu box, the gate's win/lose verdict could flip for reasons
   that have nothing to do with the model. Any determinism claim must record the
   architecture it was measured on.
3. `run.sh status` does not exist; only `retrain.sh` does. Read the `mgate` node
   on the board for current state.

## 這條線實際執行的三支（2026-09-02 補上索引）

`mlops/run.sh` 是入口，它依序跑下面兩支。**在 2026-09-02 之前這兩支沒有被任何
從 README 連得到的文件指名**，只被程式呼叫——而那代表下一個人找不到它們。

| 檔案 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`build_features.py`](../../pilots/station2-twin/mlops/build_features.py) | 由 `retrain.sh` 呼叫 | 建立預測特徵集，並**記錄它從哪裡來** | 血緣寫入 `feature_set` / `feature_row`，每個特徵都回溯得到事實表 |
| [`backtest.py`](../../pilots/station2-twin/mlops/backtest.py) | 由 `retrain.sh` 呼叫 | rolling-origin 回測，**同時把兩個天真基準放在旁邊** | 每一折重算 seasonal index，**不得使用未來資料**；守衛 `platform/tests/test_no_lookahead.sh` |

第二欄的「把基準放在旁邊」不是修辭：模型輸給天真基準時，`forecast_gate` 會擋下發布，
而那是這條線目前最有價值的機制——**它正在正確地擋著**。


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`retrain.sh`](retrain.sh) | 排程，每週 | 重建特徵 → 重跑回測 → **只在合格時**才發布 | 週期取自它所觀察的東西變化多快（來源是週資料），與 `jobs.conf` 每個 job 同一條規則。不合格就不發布，閘門正在正確地擋著 |

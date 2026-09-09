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
published only if it clears TWO gates; otherwise the run completes, records
why, and publishes nothing.

  1. **Is it a model at all?** It must beat both naive baselines on the same
     folds. This is a fact, it is the same fact in every project, and it is
     enforced by a database trigger that no publisher can route around.
  2. **Is it better than what is serving?** Since 2026-09-08: a challenger must
     beat the deployed configuration by 2% relative MAE, ON THE SAME FEATURE
     SET, or the incumbent stays and is refit on the newest data. This is a
     policy, not a fact, so it lives in code and in ADR-0016 rather than in a
     trigger. Until then the sentence above ("beats the incumbent") described
     something no code did: the publisher compared candidates to the baseline
     and to each other, never to what was actually deployed.

**The gate is currently refusing to publish at t+1, and that is the correct
outcome.** A gate that has never said no is not a gate — it is a formality — so
this state is evidence the mechanism works, not evidence that MLOps is broken.
It appears on the board as `mgate: warn`, which is honest: the pipeline is
healthy, the model is not good enough.

**Do not read a number out of this README.** Every margin quoted here has been
wrong at some point, because a document written on the day of a measurement
ages the moment the next retrain runs. Since 2026-09-08 the numbers are a
time series:

```bash
python3 platform/mlops/pipeline_metrics.py    # writes evidence/statusdag/mlops.prom
```

and the standing shape of them — t+1 has never beaten persistence, t+2 beats it
by well under the 2% replacement margin — is on the **MLOps 模型** Grafana
dashboard, which reads the series rather than restating it.

**And the harder finding, 2026-09-09.** Replaying the publishing decision over
every origin in history (`policy_backtest.py`, n=383 at t+2 instead of the live
n=1) puts the published series at −3.60% against persistence, winning 51.2% of
weeks. But the paired bootstrap interval is **[−11.92%, +3.43%] and it includes
zero** (sign test p=0.68), so the defensible claim is not "worse" — it is

> **at n=383, indistinguishable from persistence.**

Which is still decision-relevant: a model that cannot show an advantage over
383 weeks has not earned its complexity. The point estimate is never emitted
without its interval, for the same reason this repo separates estimates from
measurements everywhere else. `replay_significance.py`; docs/Backlog.md §36.

## 兩個預測題目（2026-09-09）

`influenza` 與 `influenza_like_illness` 在這個倉庫裡是**兩支不同的資料**，不是同一件
事的兩個名字。類流感是症候群定義（含非流感的呼吸道疾病），流感是流感本身。
第二個題目不需要新資料，只需要 `build_features.py --disease influenza`。

**流感明顯比較好預測**：對持平基準 t+2 是 +10.4%，類流感是 +2.3%。
重放（`policy_backtest.py`，n=431）給流感 t+2 **+6.58%**，類流感 +0.01%——
兩者的區間都還包含 0，但流感是目前唯一值得繼續的組合。詳見 docs/Backlog.md §37。

每個題目有自己的 feature set，而每一個下游步驟都必須**明講要哪一個**：
`backtest.py --feature-set`、`publish_forecast.py --feature-set`。
「取最新的那個」在有兩個題目之後就不再是一個明確的意思，而它不會報錯——
它會發布另一種疾病，並把數字記在第一種的名下。

```bash
platform/mlops/retrain.sh    # 兩個題目 × 兩個時程，各自建集、回測、發布、重放
```

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
| [`model_registry.py`](model_registry.py) | 由 pilot 的 `backtest.py` import（`run.sh` 唯讀掛載進容器） | 模型註冊表的**契約**：一筆登記合不合法、`build()` 回傳的是不是未擬合的估計器 | 專案中立，無領域知識。未登記的名稱被拒絕並列出清單；回傳已擬合估計器的條目被拒絕（守衛本身有突變測試） |
| [`mlops/pipeline_metrics.py`](pipeline_metrics.py) | 排程，每小時（`jobs.conf` 的 `mlopsmetrics`） | 把模型層的數字寫成 Prometheus textfile：對基準的相對優勢、各時程有沒有通過過閘門、事後評分、距上次重訓 | **只出數字不下判斷**——門檻全部在 `alerts/mlops.yml`。2026-09-08 之前這一層在 Prometheus 有 0 個指標（`devops_*` 20 個、`dataops_*` 15 個），整層只有看板上的燈 |
| [`replay_significance.py`](replay_significance.py) | 重訓後（`retrain.sh` 步驟 5b），或手動重跑重放時 | 對重放出來的每一組（題目×時程）算配對自助法 95% CI、精確雙尾符號檢定、以及 lag-1 自相關 | **點估計永遠不單獨出現**——`margin_ratio` 一定跟著 `ci_low`／`ci_high`。固定 seed 42、10000 次重抽、純標準函式庫，兩次執行逐位元相同。自相關是**回報**不是校正：把它偷偷修掉會讓區間看起來比它應得的更窄 |
| [`policy_backtest.py`](../../pilots/station2-twin/mlops/policy_backtest.py) | `retrain.sh` 第 5 步，每週；也可手動 | 把**發布決策**在整段歷史上逐週重放：每個原點閘門選誰、發不發、發出去的數字對上真的發生的那一週如何 | 三道洩漏門都堵住（配適走 `fit_one`、選擇只能用當時的誤差、基準只在同一組原點上算）。它是**模擬**，指標前綴 `mlops_policy_backtest_*` 與實績永不相加 |
| [`promotion_policy.py`](promotion_policy.py) | 由 pilot 的 `publish_forecast.py` import | 挑戰者何時取代現役模型：六種判定（BOOTSTRAP／REPLACE／KEEP／REFRESH／INCOMPARABLE／REFUSED） | **門檻沒有預設值**——沒想過門檻的專案會被迫想。現役只跟它在同一比較範圍內重評的分數比 |

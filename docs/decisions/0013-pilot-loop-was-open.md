---
type: explanation
title: pilot 的資料迴路是開的——排程有 19 個 job，沒有一個抓資料
description: "Every downstream stage stayed green for fourteen days on a dataset that had stopped moving, because nothing was scheduled to fetch."
tags:
  - decision
  - dataops
  - mlops
  - scheduler
  - pilot
timestamp: 2026-09-03T00:00:00+08:00
decision:
  id: 13
  status: accepted
  date: 2026-09-03
  measured: true
  rerun: platform/scheduler/status.sh
  supersedes: []
---

# 0013 pilot 的資料迴路是開的——排程有 19 個 job，沒有一個抓資料

## 決定

**新增 `ingest` 排程 job（每日 03:00），把 pilot 的資料收錄接上排程器。**
同時修正兩個讓這條線即使被排程也跑不起來的缺陷。

## 量測（2026-09-03，修正前）

問題是「公衛疾病預測 pilot 到底還在不在跑」。三個子問題分開量。

| 問題 | 修正前的答案 | 證據 |
|---|---|---|
| DataOps 有定期收錄資料嗎 | **沒有。完全沒有。** | `jobs.conf` 19 個 job 逐條檢查，無一執行 `pilots/station2-twin/ingest/`。最後一次 `ingest_runs.fetched_at` = 2026-08-20，手動 |
| DevOps 有對資料 CI/CD 嗎 | **沒有。** | 兩個 workflow 的 `paths:` 過濾器是 `platform/**`、`evidence/**`、`platform/iac/**`。`pilots/**` 不在任何一個裡面 |
| MLOps 有定期更新 model 嗎 | **跑了，但沒有更新。** | `retrain` 每週觸發且綠燈，`model_run` 每次新增列——而 `n_train` 從 2026-08-20 起固定 552／551，`code_sha256` 三次全同 `b27a652e` |

### 資料停止移動的 14 天裡，每一層都是綠的

`mirror` 每日重建、`dataops` 每小時算指標、`retrain` 每週訓練並寫入 `model_run`。
全部正確執行，全部處理同一份 2026-08-20 之後不再變動的資料。

**唯一注意到的是 `DataSourceStale`**（`dataops_source_age_seconds > 14 * 86400`），
而它是在 **2026-09-03 00:41 才進入 pending**——因為門檻正好是 14 天。
換句話說：偵測是對的，但它是這條線上唯一的偵測，而且它花了兩週才開口。

### 這是一種新的失效形狀

平台既有的目錄是「登記為存在，但不執行」。這一次是它的鄰居：

> **執行了，但沒有效果。**

`retrain` 沒有騙人——它真的跑了，真的訓練了，真的寫了列。
問題是**沒有任何東西檢查 `n_train` 有沒有長大**，
而一次在相同資料上的重訓，與一次真正的重訓，
在平台產出的每一件產物裡都長得一模一樣。

## 修正前擋在路上的兩個缺陷

### 一、`run.sh` 每次都重建映像（時區）

`ingest/run.sh` 與 `mlops/run.sh` 都用這行判斷要不要重建：

```bash
img_epoch="$(date -j -f '%Y-%m-%dT%H:%M:%S' "${img_created%.*}" +%s ...)"
```

docker 的 `.Created` 是 **UTC**，`date -j` 卻按**本地時間**解析。
在 UTC+8 這台機器上，映像永遠看起來比實際舊 8 小時：

```
img_epoch (as-local, 原本) : 1787155766
img_epoch (as-UTC,   修正) : 1787184566
dockerfile_epoch           : 1787184539
skew                       : 28800 秒 = 整整 8 小時
```

原本的比較 `1787155766 > 1787184539` 恆為假，
所以「只在 Dockerfile 較新時重建」這個最佳化**從來沒有生效過**——
每一次 ingest、每一次 retrain 都在重建映像。

這不只是慢。它讓每次執行都**靜默地依賴 Docker Hub 可連線**。
2026-09-03 Docker Hub 連不上（TLS handshake timeout，而一般網路正常），
於是本機明明有 `station2-ingest:local`，ingest 仍然無法啟動。

修正是加一個 `-u`。修正後 dry-run **3.2 秒完成並抓到 3.6 MB 資料**。

### 二、`pilots/**` 不在 CI 的觸發路徑裡

守衛是存在的：`test_static.sh`（tier 1，在 CI 跑）會讀 pilot 原始碼，
`test_no_lookahead.sh` 專門擋 pilot 特徵工程的前視洩漏。
**守衛在，但改動它們所保護的程式碼不會觸發它們。**
這是漏洞不是範圍決定——tier 2 在 CI 跑不起來是另一回事，且已另有說明。

## 修正後的量測（同日）

```
ingest --sources nhi_all,rods_all    5 分 00 秒，19 支 feed，拒絕 0，衝突 0
surveillance_fact                    6,503,799 -> 6,512,272  (+8,473)
資料水位                              2026-W32 -> 2026-W34
dataops_source_age_seconds           1,242,254 秒 -> 100~350 秒
mirror                               重建 6,512,272 列 / 40 MB / 8.9s
retrain                              46 秒（不再重建映像）
n_train                              552/551 -> 554/553   << 2026-08-20 以來第一次移動
forecast                             新發布 forecast_id=7，origin 2026W34 -> 2026W36
```

`t+1` 依閘門拒絕發布（模型輸給 persistence），`t+2` 通過。
**閘門拒絕不是失敗**，這一點 `retrain.sh` 的註解早已寫明，此處不重複。

## 為什麼是每日，而來源是每週

`jobs.conf` 的規則是「cadence 取決於被觀察的東西變多快」，照這條規則應該是每週。
每日的理由是另一件事：**疾管署不公告星期幾發布**。
週排程若落在錯的星期幾，會在來源本身約兩週的公告延遲之上，
再疊加最多 7 天的可避免延遲，而且沒有任何訊號可以對齊。
每日一次成本 5 分鐘，upsert 冪等，上游沒動就不寫入任何列。

## 刻意不做的

**`--sources all` 不用。** 它會加入 `cdc-tb-town` 與 `cdc-tb-caremag`，
兩者都不餵預測模型，而 caremag 是 410 萬列 stock 資料，
每天重讀一次只為了確認它沒變。年報級來源不屬於日排程；
它們維持手動載入，由 `DataSourceStale`（14 天）與 `MissingSource`（45 天）看著。

**不在 `retrain.sh` 裡加「n_train 有沒有長大」的檢查。**
這正是 `retrain.sh` 自己註解裡拒絕過的模式——
把同一條規則放進第三個沒人會想到去看的地方，然後讓三份副本各自漂移。
資料層已經有 `DataSourceStale`。它涵蓋不到的那個縫隙記在
[`docs/Backlog.md`](../Backlog.md) §19，不在這裡實作。

## 相關

- [0011](0011-loki-not-elk.md)：同一個形狀的上一個實例（Loki Up 21 小時，沒有東西檢查它有沒有在收）
- [`docs/Reachability.md`](../Reachability.md)：四層涵蓋不到的缺口①正是本案——可達性看得到檔案，看不到正在跑的東西

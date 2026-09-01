---
type: explanation
title: Spark 範圍縮到串流語意一段，特徵與模型不遷移
description: "What Spark is genuinely good at, which of those things this platform needs, and why sections 3.2 and 3.3 of Spark-Design are dropped while 3.1 is kept."
tags:
  - decision
  - spark
  - streaming
  - mlops
timestamp: 2026-08-28T00:00:00+08:00
decision:
  id: 2
  status: accepted
  date: 2026-08-28
  measured: true
  rerun: platform/analytics/benchmark.sh
---

# 0002 Spark 範圍縮到串流語意一段，特徵與模型不遷移

## Spark 到底好在哪裡

先誠實列出它真正強的地方，再看哪些是我們需要的。

| Spark 的長處 | 內容 | 我們需要嗎 |
|---|---|---|
| **1. 分散式 shuffle** | 資料超過單機記憶體，且操作需要全體對全體搬動（大 join、全域排序、超高基數 group by）。這是 Spark 不可取代的核心 | **不需要**。6,503,799 列、Parquet 40 MB |
| **2. Structured Streaming 語意** | event-time window、**watermark**（遲到資料怎麼算才對）、checkpoint 帶來的 exactly-once sink、stream-static join | **需要，而且別處學不到** |
| **3. 批次與串流同一套 API** | 同一份 DataFrame 程式碼兩邊跑 | 次要 |
| **4. 以 lineage 做容錯** | 分割遺失時重算而非全量 checkpoint | 不需要（單機） |
| **5. 技能可攜性** | 產業標準。醫院／研究單位真有叢集時，這個技能直接轉移 | **需要** |

**第 2 項值得展開，因為那才是真正買不到替代品的東西。**

串流的難處不是「即時算」，是**遲到資料**。第 32 週的通報在第 34 週才進來，你怎麼辦？
重算第 32 週？那已經發出去的數字算什麼？永遠等？那永遠不能結算。
**watermark 就是把「等多久」變成一個明確宣告的參數**，而不是一個沒人講清楚的預設行為。
event-time window + watermark + 冪等 sink 這一組，是分散式串流二十年累積下來的答案。
單機引擎不解這個問題——不是做得差，是根本不在它的問題範圍內。

`Spark-Design.md` 另外指出一件更具體的：Kafka consumer group 正是
**「blue/green 對串流任務語意錯誤」**的根源——兩個顏色同時消費會分走 partition。
**而那個問題會在 K8s 上再次出現。** 這是唯一能真正練到它的方式。

## 決定

`Spark-Design.md` 的三段，只保留一段。

| 段落 | 決定 | 理由 |
|---|---|---|
| **3.1 Structured Streaming** | **保留** | 上面第 2、5 項。這是這個計畫存在的理由 |
| **3.2 批次特徵 Window functions** | **由分析鏡像取代** | `lag`／`lead`／`Window` 的 SQL 語法在 Postgres 與 DuckDB 幾乎相同，而同類彙總在鏡像上是 **7 ms**（[0001](0001-analytical-mirror-duckdb.md)）。Spark 在這一段只帶來 JVM 啟動成本 |
| **3.3 MLlib 訓練與 backtest** | **不遷移** | 見下 |

## 3.3 是最明確的一項

現況**已經**用 sklearn `HistGradientBoostingRegressor` 實作並運作中，規模是
**554 個特徵列、7 次 rolling-origin 回測**。改用 MLlib `GBTRegressor` 會：

1. 為一個放得進試算表的資料集帶進 driver + 2 executors（設計文件自估 ~2.5 GB）
2. 產生**第二種模型格式**，而 `model_run` 血緣與 `forecast_gate` trigger 都繞著現在這個格式建
3. 換掉一個**正在正確擋下發布**的閘門實作——那是平台目前最有價值的機制之一

MLlib 的價值在「模型訓練資料放不進單機」。554 列不是那個情況。

## 連帶的資源決定

`platform/k8s/verify_cluster.sh:85` 斷言「每個 agent ≥ 1 GiB（放得下一個 Spark executor）」。
3.1 若要跑，`Spark-Design.md` 自己已建議 `k3d cluster stop`——**兩者本來就不同時跑**，
所以這條斷言的理由要改寫成叢集自身的需求，不是為 Spark 預留。

## 哪些是量測、哪些是判斷（不要混為一談）

- **量測**：3.2 由鏡像取代——彙總 7 ms vs Postgres 2.6 s。重跑 `platform/analytics/benchmark.sh`。
- **量測**：現況模型是 sklearn，特徵 554 列、回測 7 次（`platform/statusdag/dag.py` 的現場探測）。
- **判斷，無法量測**：3.1 的學習價值。根據是 `Spark-Design.md` 自述的目的（「殺雞用牛刀成立，**目的是練習**」）與串流語意在 K8s 上會重現的論證。**不要把它當成量測結果引用。**

## 觸發重審

- 事實表或事件流超過單機記憶體（第 1 項才會變成需要）
- 中醫大個人級資料接入後，訓練資料量級改變（3.3 才需要重看）

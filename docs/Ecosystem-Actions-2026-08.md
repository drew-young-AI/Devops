---
type: plan
title: 生態系掃描的可執行結論
description: "What was measured, what was adopted, what was rejected and why -- DuckDB mirror, the Spark verdict, and the agent-operations layer mapped onto prompt/context/harness/loop/graph."
tags:
  - decisions
  - duckdb
  - spark
  - agent-operations
timestamp: 2026-08-27T00:00:00+08:00
---

# 生態系掃描的可執行結論

前一份（`Ecosystem-Scan-2026-08.md`）是量測。這一份是**決定**：採用什麼、拒絕什麼、以及每一項的理由。

---

## 一、DuckDB：實測後已採用並上線

實測 `surveillance_fact` 6,503,799 列，兩次獨立執行一致：

| 查詢 | Postgres | DuckDB→PG | DuckDB→Parquet | 倍數 |
|---|---:|---:|---:|---:|
| 全國時間序列 | 2,585 ms | 5,593 ms | **7.8 ms** | **331×** |
| 地區排行 top 20 | 2,296 ms | 5,399 ms | **5.4 ms** | **425×** |
| 疾病×年齡層樞紐 | 2,688 ms | 6,103 ms | **7.2 ms** | **373×** |
| 全表彙總 | 2,702 ms | 5,688 ms | **6.7 ms** | **403×** |
| **單點（走索引）** | **0.9 ms** | 5,495 ms | 5.1 ms | pg 勝 5.7× |

**兩個否定結論同樣重要：**

1. **`postgres_scanner` 實測比 Postgres 本身還慢兩倍**（5.4–6.1s vs 2.3–2.8s）。這是維運上最誘人的選項——不用副本——但它把列拉過連線再算。**實測否決了我原本會偏好的方案。**
2. **不取代 Postgres。** 走索引的點查詢 Postgres 快 5.7 倍。Postgres 仍是真實來源。

**已實作**：`platform/analytics/`，`run.sh build | check | refresh | query`，已排進排程器（daily，`refresh` 在已最新時只花 0.8s）。

**這一層真正的風險不是速度，是新鮮度。** 快會讓人信任它，所以悄悄過期的鏡像比慢而正確的查詢更糟。鏡像帶著建構水位（`max(ingest_runs.id)` + `max(fetched_at)` + 事實表列數），**不符就拒絕回答**——不是回答加註記，註記會被當成數字旁邊的裝飾讀過去。四種突變全部驗證過（水位落後、列數不符、時間戳過期、parquet 缺檔），10/10。

---

## 二、Spark：我上一輪的建議是錯的，因為我沒讀設計文件

我上一輪說「明確殺掉 Spark 計畫」。**那是在沒讀 `Spark-Design.md` 的情況下說的**，把它當成生產資料處理決策來評估。文件第 4 節白紙黑字寫著：

> 「殺雞用牛刀」成立，**目的是練習**，並且讓 pilot 頭尾串起來。

以學習載體評估，結論完全不同。分三段看：

| 段落 | Spark 提供什麼 | 判斷 |
|---|---|---|
| **3.1 Structured Streaming** | watermark、event-time window、stream-static join、Kafka consumer group／partition | **保留。** 文件指出 consumer group 正是「blue/green 對串流任務語意錯誤」的根源，而**那個問題會在 K8s 上再次出現**。這是單機引擎教不了的東西 |
| **3.2 批次特徵 Window functions** | `lag`／`lead`／`Window` | **不需要 Spark。** Postgres 與 DuckDB 的 SQL window function 語法幾乎相同，而鏡像現在跑同類查詢是 **7 ms** |
| **3.3 MLlib 訓練與 backtest** | `GBTRegressor` | **不要遷移。** 你們**已經**用 `HistGradientBoostingRegressor`（sklearn）實作並運作中 |

**3.3 是最明確的一項。** 現況 554 個特徵列、7 次 rolling-origin 回測。改用 MLlib 會：

- 為一個放得進試算表的資料集帶進 driver + executor（~2.5 GB）
- 產生**第二種模型格式**，而現有的 `model_run` 血緣與閘門 trigger 都繞著現在這個格式建
- 換掉一個**已經在正確擋下發布**的閘門實作——那是平台目前最有價值的機制之一

**建議：把 Spark 計畫改寫成只涵蓋 3.1**，明確記錄 3.2 由鏡像取代、3.3 維持 sklearn。並移除 `verify_cluster.sh:85` 那條「每個 agent ≥ 1 GiB（放得下 Spark executor）」的斷言理由——若 3.1 要跑，文件自己已建議 `k3d cluster stop`，兩者本來就不同時跑。

---

## 三、DataOps 監控：接受「加更多監控」，但要接在對的地方

你說 pipeline monitor 與 autonomous pipeline 可以做。同意，但要說清楚它們**補的是哪個洞**，否則會變成疊在既有 CHECK 約束上的第二套真相。

現況：血緣是 `CHECK` 約束（39 批次全數收斂），資料**品質**在寫入時就擋住。這一層不需要監控——約束不會失敗，它只是拒絕。

**約束擋不住的三件事**，就是監控該去的地方：

1. **新鮮度**——來源該更新而沒更新。約束看不到「沒發生的事」。指標：每個 `data_source` 的 `max(fetched_at)` 年齡。
2. **分佈漂移**——資料合法但變了（某縣市通報量掉一半）。約束只看格式與守恆，不看分佈。
3. **執行健康**——批次跑多久、拒絕率趨勢。`ingest_runs` 已經記了 `rows_accepted`／`rejected`／`inserted`，**目前沒有變成指標**。

三者都能寫進既有的 Prometheus textfile collector（`dag.prom` 那條路），**不需要新服務**。這是「加監控但 ops 不增加」的做法。

「Autonomous pipeline」則建議**先不做**：實測 `autonomous data pipeline` 名稱命中 812 個 repo，而 `dataops` 這一年最紅的自癒管線是 **4 星**。宣傳量與實作量差兩個數量級，這一格目前買不到成熟的東西。

---

## 四、DevOps：witr 和其他，什麼值得裝

上一份只列了 repo 沒給建議，這裡補上。**判準是「它解掉一個我們真的踩過的問題嗎」**，不是星數。

### 值得，且成本低

**`headroom`**（67,784★，Apache-2.0，Python，2026-01 建立）
「壓縮 tool 輸出、log、檔案、RAG chunk 再送進 LLM。**JSON 少 60–95% token**，答案相同。函式庫 / proxy / MCP server。」

**這是這份清單裡最該裝的一個**，理由是你們的形態：平台用 agent 輔助管理，而**證據全是 JSON**（`evidence/**/*.json`）。agent 每次要理解平台狀態就得讀這些檔案，JSON 少 60–95% token 直接決定 agent 一次能掌握多少平台。它是函式庫不是服務，沒有東西要維運。

**`witr`**（21,713★，Apache-2.0，Go，單一 binary）
「Why is this running? 把任何 process、port、container、檔案追回到啟動它的東西。」

**對應到你們踩過的真實問題**：C9 曾被降級，因為「`jobs.conf` 有一筆，但 launchd 根本沒有那個 agent」——`status.sh` 看得到工作記錄新鮮度，看不到「這個 process 是誰啟動的」。你們用 `XPC_SERVICE_NAME` 解掉了那個特定案例；witr 解的是**下一個還不知道的案例**。單一 binary、無服務、無狀態。

### 值得評估，但有明確觸發條件

**`dagu`**（3,810★，GPL-3.0，Go）
「單一 binary、**無資料庫**、跑得動在有限硬體上。Airflow / Cron / Job Scheduler 的替代品。宣告式 YAML 疊在你的腳本上。」

你們的排程器是 launchd + `run_job.sh` + 鎖檔，測試 30 項全綠，**能用**。但有一個現在就存在的缺口：**工作之間的依賴是隱含的**。`mirror` 應該在 ingest 之後跑、`stagereport` 應該在 `dag` 之後跑——現在兩者都只是「設同樣的週期，希望順序對」。dagu 讓依賴變成宣告。

**觸發條件**：出現第三組順序相依的工作，或出現一次「因為順序錯而產出誤導結果」的事件。**現在不要換**——換掉一個 30 項測試護著的能用系統，成本高於收益。

**授權注意**：GPL-3.0。當成外部 binary 呼叫沒問題，但這個 repo 是 public，值得先確認立場。

### 不建議

**`langfuse`**（33,809★）——LLM evals + observability + prompt management。
**你們現有的實作在這個規模比它更合適。** `review.py` 已經有 `inputs_digest`（固定順序組裝後雜湊）、`system_digest`（prompt 本身的雜湊）、`temperature=0`。langfuse 要一整套服務（TypeScript + Postgres + 通常還要 Clickhouse）來提供你們**大部分已經有**的能力。

**`temporal` / `restate`**（durable execution）——你們的「loop」是 13 個排程工作，不是分散式工作流。

---

## 五、prompt / context / harness / loop / graph 的維運，逐項對照

你指出這一層才是重點。把五個概念對到平台現況：

| | 生態系規模 | 你們現在有什麼 | 判斷 |
|---|---:|---|---|
| **prompt** | `prompt-engineering` 16,792<br>`prompt-management` 308<br>`prompt-versioning` **40** | `system_digest` + `inputs_digest` + `temperature=0` | **已超前。** 但缺 eval set |
| **context** | `context-engineering` 2,818 | 無 | **缺口。** headroom 補 |
| **harness** | `agent-framework` 2,395<br>`agentops` 199 | `run_job.sh`（工作的 harness） | **部分。** 缺 agent 動作的軌跡 |
| **loop** | `durable-execution` 564 | launchd 計時器 + 鎖檔 | **部分。** 無依賴圖、無可恢復性 |
| **graph** | `workflow-engine` 1,647 | `statusdag/dag.py`（節點、邊、影響傳播） | **已超前** |

### 最能說明問題的一個數字

`prompt-engineering` **16,792** 個 repo，`prompt-versioning` **40** 個。**419 倍。**

這和 DataOps 那個 138 倍是同一種形狀：**所有人都在做這件事，幾乎沒有人在維運這件事。** 你們反而屬於那 40 個那一側——prompt 的雜湊、固定順序組裝、determinism 可事後檢驗，都已經有了。

### 真正的缺口是 eval，不是 prompt 管理

現況能偵測**非確定性**（相同 `inputs_digest` 出現不同結論 = 可偵測的失敗）。但**不能偵測品質退化**：改了 `SYSTEM_PROMPT` 之後，`system_digest` 會變、determinism 檢查照樣通過，而複審是變好還是變壞**沒有任何機制回答**。

這正好接回 §MLOps 那個結論——你們的未解問題屬於 `evaluation`（5,610）而不是 `mlops`（10,403）。**兩個地方都缺同一樣東西：一組已知答案的題目。**

**建議的下一步（未實作，等你決定）**：一組 5–10 個「已知該被抓到」的 commit 當成 golden set，`SYSTEM_PROMPT` 變更時重跑，記錄抓到幾個。這是自己寫 50 行的事，不需要 langfuse。

### `llmreview` 目前是 SUPERSEDED，這是活的缺口

階段燈號顯示 `llmreview` 狀態為「輸入來自已退役的 Compose 路徑；待接上 Kubernetes 產物」。**在接回去之前，上面所有 prompt/eval 的討論都是關於一個沒在跑的元件。** 這件事的優先順序高於採用任何新工具。

---

## 六、誠實標記

- DuckDB 數字是本機 `surveillance_fact` 實測，兩次一致。**其他每一個工具都沒有安裝或測試過**，判斷根據的是描述、授權、規模與對應到的既有問題。
- Spark 3.1 的價值（串流語意學習）**無法量測**，是根據設計文件自述的目的所做的判斷。
- `dagu` 的 GPL-3.0 對 public repo 的影響**未經法務確認**。

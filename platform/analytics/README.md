---
type: platform-adapter
title: 分析鏡像（DuckDB + Parquet）
description: "A read-only Parquet mirror of the pilot database, 300-425x faster on aggregations, which refuses to answer when its watermark disagrees with the live database."
tags:
  - analytics
  - duckdb
  - dashboard
timestamp: 2026-08-27T00:00:00+08:00
---

# 分析鏡像（DuckDB + Parquet）

**這一層存在的理由是一組實測數字，不是因為 DuckDB 很紅。**

## 量測（2026-08-27，`surveillance_fact` 6,503,799 列，兩次獨立執行一致）

| 查詢 | Postgres | DuckDB→Postgres | DuckDB→Parquet |
|---|---:|---:|---:|
| 全國時間序列（折線圖） | 2,585 ms | 5,593 ms | **7.8 ms** |
| 地區排行 top 20（長條圖） | 2,296 ms | 5,399 ms | **5.4 ms** |
| 疾病×年齡層 樞紐（熱圖） | 2,688 ms | 6,103 ms | **7.2 ms** |
| 全表彙總 group by geo | 2,702 ms | 5,688 ms | **6.7 ms** |
| **單點時間序列（走索引）** | **0.9 ms** | 5,495 ms | 5.1 ms |

彙總類快 **300–425 倍**。2.6 秒與 7 毫秒不是「比較快」，是儀表板能不能做即時查詢的分界。

## 三個結論，兩個是否定的

1. **不要用 `postgres_scanner`。** 實測比它包起來的 Postgres **還慢兩倍**（5.4–6.1s vs 2.3–2.8s），因為它把列拉過連線再算。這個選項在維運上最誘人（不用副本），實測否決。
2. **不要拿 DuckDB 取代 Postgres。** 走索引的單點查詢 Postgres 快 **5.7 倍**（0.9ms vs 5.1ms）。Postgres 仍是真實來源與交易處理。
3. **要的是唯讀分析鏡像。** Parquet 40 MB（Postgres heap 819 MB，壓縮 20 倍），重建 8.8 秒。

## 這一層最大的風險不是速度，是新鮮度

**一個快而悄悄過期的鏡像，比一個慢而正確的查詢更糟。** 快會讓人信任它。

所以鏡像**必須帶著它是從什麼建出來的**：`max(ingest_runs.id)`、`max(fetched_at)`、以及事實表列數。
`query.py` 每次查詢前先比對 Postgres 的當前水位——**不符就拒絕回答**，不是回答加註記。
註記會被忽略，拒絕不會。

## 用法

```
platform/analytics/setup.sh          # 建立隔離環境（一次）
platform/analytics/run.sh build      # 重建鏡像 + 寫 manifest
platform/analytics/run.sh check      # 只檢查新鮮度，rc 0=新鮮 1=過期 78=未建立
platform/analytics/run.sh query "SELECT ..."

```

`fact` 與 `period` 是查詢中可用的表名。

## 為什麼不放進 git

Parquet 是衍生資料（40 MB），任何時候都能由 Postgres 重建，所以 gitignore。
**manifest 進 git**：它記錄鏡像是從哪個水位建的，那是稽核軌跡不是衍生資料。


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`setup.sh`](setup.sh) | 一次性 | 建立分析鏡像用的隔離環境 | venv 放在 `platform/analytics/` 下，**不用 host Python、也不共用**：這層釘住引擎版本，浮動的引擎版本＝浮動的數字 |
| [`analytics/run.sh`](run.sh) | 每次重建鏡像 | 入口，重建 Parquet 鏡像並可跑基準 | 資料庫密碼從執行中的容器**進環境變數**，**絕不進命令列**——`ps` 會把它給機器上每一個程序看 |


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到（能力必須是**該列的主詞**）。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`benchmark.sh`](benchmark.sh) | 需要重驗 ADR-0001 的數字時 | 重現決策紀錄 0001 的量測 | **一個指令、零參數**：要先設三個環境變數的重跑指令是沒有人會照做的重跑指令，然後那個數字就會被憑印象重估 |

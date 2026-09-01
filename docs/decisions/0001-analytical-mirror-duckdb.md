---
type: explanation
title: 分析查詢走 DuckDB + Parquet 鏡像，點查詢維持 Postgres
description: "Measured 300-425x speedup on aggregations and a 5.7x Postgres win on indexed point lookups; the mirror is adopted for one and explicitly not for the other."
tags:
  - decision
  - duckdb
  - postgres
  - dashboard
timestamp: 2026-08-27T00:00:00+08:00
decision:
  id: 1
  status: accepted
  date: 2026-08-27
  measured: true
  rerun: platform/analytics/benchmark.sh
---

# 0001 分析查詢走 DuckDB + Parquet 鏡像，點查詢維持 Postgres

## 決定

**大量彙總**（儀表板、時間序列、排行、樞紐）走 `platform/analytics/` 的 Parquet 鏡像，用 DuckDB 查。
**單點檢索**（走索引的特定 geo／disease／期間）維持直接查 Postgres。
Postgres 仍是唯一的真實來源；鏡像是唯讀、衍生、可拋棄的副本。

**這不是「換掉資料庫」。是依查詢形態分流。**

## 量測（2026-08-27，`surveillance_fact` 6,503,799 列，三次獨立執行一致）

| 查詢形態 | Postgres | DuckDB→PG | DuckDB→Parquet | 結論 |
|---|---:|---:|---:|---|
| 全國時間序列（折線圖） | 2,585 ms | 5,593 ms | **7.8 ms** | 鏡像快 **331×** |
| 地區排行 top 20（長條圖） | 2,296 ms | 5,399 ms | **5.4 ms** | 鏡像快 **425×** |
| 疾病×年齡層樞紐（熱圖） | 2,688 ms | 6,103 ms | **7.2 ms** | 鏡像快 **373×** |
| 全表彙總 group by geo | 2,702 ms | 5,688 ms | **6.7 ms** | 鏡像快 **403×** |
| **單點時間序列（走索引）** | **0.9 ms** | 5,495 ms | 5.1 ms | **Postgres 快 5.7×** |

Parquet 40 MB（Postgres heap 819 MB，壓縮 20 倍），重建 8.8–9.2 秒。

**重跑**：`platform/analytics/benchmark.sh`（單一指令，無參數，約 90 秒）。

## 為什麼這樣分

彙總要掃很多列、只取少數欄——欄式儲存 + 向量化執行正是為此而生，而且 40 MB 全部放得進記憶體。
點查詢只碰少數列——B-tree 索引直接定位，欄式沒有優勢，反而多付了開檔與 schema 解析的固定成本。

**2.6 秒與 7 毫秒不是「比較快」**，是儀表板能不能做即時查詢的分界：2.6 秒的查詢一定要先預算好，
7 毫秒的可以讓使用者自由拉條件。

## 被否決的選項

**`postgres_scanner`（DuckDB 直讀 Postgres，不用副本）——實測否決。**
維運上最誘人：沒有副本要同步、沒有新鮮度問題。但實測 **5.4–6.1 秒，比它包起來的 Postgres 還慢兩倍**，
因為它把列拉過連線再算。所有查詢都停在 ~5.4 秒的地板，包括只回傳幾列的 Q5——它每次都重讀。

**用 DuckDB 取代 Postgres——否決。** 點查詢慢 5.7 倍，且沒有交易與約束（血緣的 `CHECK`、閘門的 trigger 都在 Postgres）。

## 代價，以及代價怎麼被控制住

副本會過期，而**快會讓人信任它**——所以悄悄過期的鏡像比慢而正確的查詢更糟。

鏡像帶著建構水位（`max(ingest_runs.id)`、`max(fetched_at)`、事實表列數）。
查詢前先比對 Postgres 現況，**不符就拒絕回答**，不是回答加註記——註記會被當成數字旁邊的裝飾讀過去。
四種失效各驗證過一次（水位落後、列數不符、時間戳過期、Parquet 缺檔），`test_analytics_mirror.sh` 10/10。

## 觸發重審的條件

- 事實表超過約 1 億列（40 MB 會變幾 GB，記憶體假設不再成立）
- 出現需要**寫入**的分析工作流（鏡像唯讀，寫入必須回 Postgres）
- Postgres 版本升級後彙總效能大幅改變——**先重跑 `benchmark.sh` 再談**

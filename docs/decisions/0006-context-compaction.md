---
type: explanation
title: 不採用 headroom，也不自建等價壓縮
description: "Measured 32% token reduction on this repository's evidence, not the advertised 60-95%."
tags:
  - decision
  - agent
  - context
timestamp: 2026-08-29T00:00:00+08:00
decision:
  id: 6
  status: accepted
  date: 2026-08-29
  measured: true
  rerun: platform/docs/context_cost.sh
---

# 0006 不採用 headroom，也不自建等價壓縮

## 決定

**不裝 `headroom`，也不自己實作一份等價的 JSON 壓縮。** 量測後它解的不是我們的問題。

同時記下**真正的問題是什麼**，以及什麼條件下要回頭處理。

## 為什麼會考慮它

`headroom`（67,784★，Apache-2.0，函式庫而非服務）宣稱把 JSON 送進 LLM 前壓掉
**60–95% token，答案相同**。這個平台用 agent 輔助管理，證據全是 JSON
（`evidence/**/*.json`），所以這個宣稱若成立，直接決定 agent 一次能掌握多少平台。

## 量到什麼

用**實際讀這個平台的那個模型的 tokenizer**（本機 MLX Qwen3.6-35B-A3B-4bit），
對本 repo 的證據檔做無損欄位化（同構物件陣列 → 一份鍵名 + 位置列），不摘要、不丟欄位：

| 範圍 | 檔數 | 原始 | 壓縮後 | 減少 |
|---|---:|---:|---:|---:|
| 全部證據 | 1,325 | 753,639 | 512,787 | **32.0%** |
| agent 實際會開的那幾份 | 4 | 11,392 | 6,862 | **39.8%** |

重跑：`platform/docs/context_cost.sh`

**32%，不是 60–95%。** 差距不是宣稱造假，是形態不同：那個數字來自大型、高度重複的
payload（API 回應、log dump）。這裡的證據檔平均 570 token，小且異質，
重複鍵名本來就不多。

## 為什麼即使 32% 也不做

**因為 12,000 token 不是問題。** 壓縮要解的是「agent 裝不下平台狀態」，
而 agent 實際讀的那一包只有 11,392 token。省下 4,530 token 沒有改變任何一件
agent 做得到或做不到的事。**為一個沒有咬人的限制加一層轉換，是純成本。**

而且轉換本身有代價：`__cols` / `__rows` 形式**人類讀起來更差**。
證據檔的用途不只餵模型，也給人在事故當下打開。

## 真正的問題在別的地方

同一次量測順手數出來的分布，才是重點：

| 目錄 | 檔數 |
|---|---:|
| `evidence/observability` | **1,215** |
| `evidence/security` | 60 |
| 其餘全部 | 50 |

`evidence/observability` 是**同一支健康探針每 15 分鐘寫一個檔**，16 天累積 1,215 個，
468,006 token，結構完全相同。沒有保留策略，一年會到約 28,000 個。

**沒有任何 agent 會讀 1,215 個檔。** 它會讀一兩個然後外推——
而「讀了兩個就結論全體健康」正是 grounding gap 的定義，只是穿著證據的外衣。

這件事在 2026-08-29 當場證實了：`WidespreadGeoDrift` 這條告警規則載入後**每個週期都
評估失敗**，探針每 15 分鐘忠實地把 `UNKNOWN` 寫進證據，連續 11 小時，
而燈號板同時顯示 `prometheus ok`。證據是齊的，沒有人讀。

**壓縮 32% 不會讓任何人讀那 1,215 個檔。**

## 所以吸收了什麼

吸收的是**性質**，不是套件——與 `docs/Harness-Engineering-Notes.md` 對
`deepseek-harness` 的立場一致：

1. **「agent 讀得到」是設計條件，不是事後最佳化。** 落地成三件已完成的事：
   `probe_prometheus` 把規則健康接進燈號板（探針早就偵測到了，燈號板才是人會讀的地方）；
   `dashboard_audit.py` 讓「查不到東西的圖表」在測試時就紅；
   README 成為單一總表，且每個連結與網址都有測試。
2. **同構的時間序列證據應該可查詢，不是可堆積。** 這是 ADR-0001 已經做過的同一件事
   （大量彙總走欄式，單點走 B-tree），只是換一種資料。

## 什麼時候回頭

任一條成立就重新評估，並**先重跑量測再決定**：

- `evidence/` 超過 10,000 檔，或單次 agent 讀取超過 50,000 token
- 出現第二個「證據齊全但沒人讀」的事件
- headroom 之外出現針對**小型異質 JSON** 的量測（不是針對大型 payload 的）

## 明確不做

- 不對 `evidence/` 做保留刪除。刪掉的是可追溯性，而可追溯性是 README 第二節的整個重點。
  收斂要用彙總，不是用 `find -mtime -delete`。
- 不裝 `headroom` 當服務或 MCP。即使日後採用，也只會用函式庫形式。

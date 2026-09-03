---
type: explanation
title: 不導入 ELK——那一格是 Loki 在填，不是 Prometheus
description: "The conclusion is right and the usual reason is wrong, because Prometheus stores no logs and Loki is what fills that slot."
tags:
  - decision
  - observability
  - logs
  - loki
timestamp: 2026-09-02T00:00:00+08:00
decision:
  id: 11
  status: accepted
  date: 2026-09-02
  measured: true
  rerun: platform/observability/loki_coverage.py
  supersedes: []
---

# 0011 不導入 ELK——那一格是 Loki 在填，不是 Prometheus

## 決定

**不導入 ELK／Elasticsearch。** 這個結論維持
[`docs/Plan-detail.md`](../Plan-detail.md) §0D 原本的判斷，不變。

## 但常見的那個理由是錯的，而錯法很具體

會被說出口的理由通常是「**Prometheus 和 Grafana 已經有了**」。
**Prometheus 不存 log。** 它存的是時間序列的數字樣本，
標籤基數一高就會付出記憶體代價——把日誌行塞進標籤正是它最壞的使用方式。
**Grafana 不存任何東西**，它是查詢介面。

所以如果 ELK 那一格真的靠 Prometheus + Grafana，**那一格是空的**，
而且會在「需要回頭查昨天那一行 log」的那天才發現。

**填那一格的是 Loki**，它在這個平台上已經跑著、而且**確實在收**：

| 量測 | 值 |
|---|---:|
| 已接收日誌行（tenant `platform`） | **71,289** |
| 串流數 | **111** |
| 已接收位元組 | **14,260,653** |
| 保留期（`platform` / `restricted`） | **168h / 72h** |

重跑：`python3 platform/observability/loki_coverage.py`。
**在這筆決策之前，沒有任何東西檢查過這件事**——`docker ps` 說 Loki 是 Up，
compose 宣告了兩個租戶，`config.alloy` 宣告了寫入時遮罩，
ingress 守衛拒絕曝露 Loki。那四件都是**關於設定的陳述**，沒有一件是「有 log 進來過」的證據。
這是這個平台反覆出現的那個形狀：**登記為存在，但不執行。**

## 為什麼是 Loki 而不是 ELK

| 面向 | Loki | Elasticsearch |
|---|---|---|
| 索引 | 只索引**標籤**，日誌本體壓縮存放 | 全文倒排索引 |
| 資源 | 與 Prometheus 同量級 | JVM heap 通常以 GB 起跳；這台是 MacBook |
| 查詢介面 | **與 metrics 同一個 Grafana**，同一時間軸並排 | Kibana，第二套 UI 與第二套權限模型 |
| 多租戶 | `X-Scope-OrgID`，Loki 在每個請求上強制 | 需另行設計 |

第三列是被低估的一項：**排障時真正省時間的不是搜尋能力，是把 metric 的尖峰和
同一秒的 log 並排在同一條時間軸上。** 兩套 UI 就沒有那條時間軸。

## 誠實的代價（這是重審觸發條件，不是免責聲明）

Loki 是**標籤索引，不是全文索引**。`|=` 過濾是掃描壓縮區塊，不是查倒排索引。
在需要**跨大量歷史做任意全文關聯**（SIEM 的典型工作）時，Elasticsearch 會贏，
而且不是小贏。**現在不需要那個，不代表以後不需要。**

## 順帶查到的兩件事（都是量測，不是推論）

**1. `restricted` 租戶在生產上從未收過任何一條串流。**
它被合成容器端到端驗證過一次（見 `Plan.md` 的 log 資料治理段落：真實格式 PII →
儲存為 `[REDACTED_TWID]` → 從 `platform` 租戶查 0 筆 → 無 header 一律 401），
之後就再也沒有真實流量。**這是正確的狀態，不是故障**——目前沒有服務宣告自己是 restricted。
所以 `loki_coverage.py` **報告它、但不因它失敗**：一個設計上就是紅的檢查，
最後會變成沒人看的檢查。

**2. `station2-twin` 宣告了 `platform.data_class: platform`，而沒有這個類別。**
路由規則只在**完全等於** `restricted` 時把容器留在 restricted 租戶，
internal 管線是它的**精確補集**。這個分割是可證明窮盡的——那正是它安全的原因，
**也正是打錯字看不見的原因**：無法辨識的值不會報錯，它會落進
**受眾較廣、保留期較長**的那個租戶（168h，不是 72h）。

那個 label 上方的註解寫著「明確設定而不用預設值，因為未標記的服務會靜默落到錯的租戶」——
**而它用的那個值造成的正是那件事**。已改為 `internal`，
並由 `loki_coverage.py --check` 擋住任何不在 `{internal, restricted}` 內的值。
驗證放在檢查腳本而不是路由規則裡，因為加進路由規則會破壞補集性質，
而補集性質是這個分割可證明的基礎。

## 觸發重審

- 出現真正的 SIEM 需求：跨數月歷史的任意全文關聯、合規稽核查詢
- 醫院既有企業標準就是 Elastic（那時的問題是對接，不是選型）
- Loki 的標籤基數或查詢延遲成為排障瓶頸（`loki_coverage.py` 的數字是基線）

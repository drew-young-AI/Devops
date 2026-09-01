---
type: explanation
title: Prometheus 開放區網，且明示接受它沒有認證
description: "The listener is read-only (measured), has no authentication (accepted), and this record exists so the trade stays a decision rather than becoming an accident nobody remembers making."
tags:
  - decision
  - security
  - lan
  - prometheus
timestamp: 2026-08-27T00:00:00+08:00
decision:
  id: 3
  status: accepted
  date: 2026-08-27
  measured: true
  rerun: platform/tests/test_network_exposure.sh
---

# 0003 Prometheus 開放區網，且明示接受它沒有認證

## 決定

平台從全部 loopback 改為三個服務區網可達：階段燈號（`:18085`）、Grafana（`:13000`）、
**Prometheus（`:19090`）**。Alertmanager、Loki、node-exporter、nginx TLS vhost 維持 loopback。

**Prometheus 沒有認證，這是明示接受的風險**，決定者為平台擁有者，理由是「大家一起承受」。
記在這裡，讓它保持為一個決定，而不是三個月後沒人記得怎麼來的設定。

## 量測（不是推論）

- `--web.enable-lifecycle` 與 `--web.enable-admin-api` 皆未啟用 → **唯讀**
- 實測 `POST /-/reload` → 403、`POST /-/quit` → 403、admin 刪除序列端點拒絕且資料完好
- `test_network_exposure.sh` 每次測試重量一次，10 項斷言

**重跑**：`platform/tests/test_network_exposure.sh`

## 剩餘暴露

區網上任何人可讀取平台全部指標：服務名稱、節點狀態、資料筆數、模型分數。
**不可**讀取日誌內容（Loki 仍 loopback），**不可**靜音告警（Alertmanager 仍 loopback——
它的 API 能寫，而能靜音告警的人可以讓一次中斷變成隱形的）。

## 一個必須先講的限制

**Grafana RBAC 的強度等於最弱的對外端點。** 被設成 Viewer 的人只要直接打 `:19090`，
就拿得到 Grafana 不給他看的同一批指標。在這個前提下，角色區隔是**介面分工，不是存取控制**，
不可當成安全邊界向長官陳述。完整路徑見 [Access-Control.md](../Access-Control.md)。

## 這個測試自己踩過的坑

第一版用 mDNS 名字（`70.local`）探測，回報每個 loopback-only 服務都「可達」。
名字同時解析到 `::1`，curl 挑了 loopback，**整趟探測沒離開本機**——它要證明的那些拒絕從頭到尾沒被測過。
現在強制 IPv4 + 區網位址，而且**先證明探測方法真的連得上，才准相信任何一個「拒絕」**。

## 觸發重審

- 要做真正的權限區隔時（第 0 步是 Prometheus 移回 loopback 或放到需驗證的代理後面）
- 這台機器接上非受信任網段時

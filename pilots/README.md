---
type: overview
title: Pilot 服務總覽
description: "What pilots are for: validating the platform, never representing product requirements."
tags:
  - pilot
  - entry-point
timestamp: 2026-08-09T01:15:06+08:00
---
# Pilot Services

目前 Pilot：`station2-twin`（有狀態）。

`station1-hello`（無狀態 HTTP）已於 2026-08-19 退役。它的工作是把部署主線
走通一次：build → SAST → Trivy → SBOM → deploy → blue/green promote →
rollback，全部驗證過，證據保留在 `../evidence/_retired/station1-hello/`。
它做不到的事情正是它退役的理由——無狀態服務無法驗證備份、還原、schema
遷移與憑證輪替，而那些才是有狀態服務真正會出事的地方。

**退役同時暴露了一個缺口**：station2-twin 已經跑了好幾天，Prometheus 卻
完全沒有抓它——監控整段時間都是綠的，因為它盯著的是那個已經不重要的 Pilot。
儀表板對著錯的服務顯示「一切正常」，比沒有儀表板更糟。已修正。

目前狀態（station2-twin）：readiness 契約、migration gate（expand/contract）、
Vault 動態資料庫憑證、四個公衛 feed 共 4,390,947 列事實資料、Prometheus/
Grafana/告警規則皆已驗證。**blue/green 尚未接上**——它的 compose 把資料庫與
應用綁在同一份檔案，第二個顏色會撞到同一個 host port 與同一個具名 volume，
拆分見 `../docs/Backlog.md`。

這裡放用來驗證 DevOps 平台的 POC、Pilot 與測試服務。

每個 Pilot 都可以有自己的：

- Dockerfile
- compose.yaml
- application code
- tests
- service-specific README

但必須遵守 [../NEW_SERVICE_GUIDE.md](../NEW_SERVICE_GUIDE.md) 的服務契約與安全基線。

Pilot 成功不代表產品成功，只代表平台能夠對該服務完成建置、測試、掃描、部署、監控與回滾驗證。

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

目前 Pilot：**station2-PublicHealth**（2026-09-19 更名；識別字仍是 `station2-twin`，理由見 [ADR-0022](../docs/decisions/0022-a-display-name-is-not-an-identifier.md)）（有狀態）。

`station1-hello`（無狀態 HTTP）已於 2026-08-19 退役。它的工作是把部署主線
走通一次：build → SAST → Trivy → SBOM → deploy → blue/green promote →
rollback，全部驗證過，證據保留在 `../evidence/_retired/station1-hello/`。
它做不到的事情正是它退役的理由——無狀態服務無法驗證備份、還原、schema
遷移與憑證輪替，而那些才是有狀態服務真正會出事的地方。

**退役同時暴露了一個缺口**：station2-PublicHealth 已經跑了好幾天，Prometheus 卻
完全沒有抓它——監控整段時間都是綠的，因為它盯著的是那個已經不重要的 Pilot。
儀表板對著錯的服務顯示「一切正常」，比沒有儀表板更糟。已修正。

目前狀態（station2-PublicHealth）：readiness 契約、migration gate（expand/contract）、
Vault 動態資料庫憑證、四個公衛 feed、Prometheus/Grafana/告警規則皆已驗證。

**資料量不寫在這裡，因為寫下來的數字會過期而讀起來不會。** 這一行原本寫
「4,390,947 列」，2026-09-10 實測是 7,167,314 列——差了 280 萬列，而中間沒有任何
一步會告訴你它不再是真的。要現在的數字就跑：

```bash
platform/db/pilot_db.sh psql -c \
  "select 'surveillance_fact',count(*) from surveillance_fact
   union all select 'demographic_fact',count(*) from demographic_fact"
```

**blue/green 跑在 Kubernetes 上，不在 Compose 上**（2026-09-19 更正：這段原本寫
「blue/green 尚未接上」，那句話在 K8s 轉向之後就不再成立，而它讀起來像整個平台
沒有藍綠部署）。現況分兩邊講：

- **Kubernetes（`k3d devops-lab`）已接上**：`station2-twin-blue` 與
  `station2-twin-green` 兩份部署同時在跑，Service 指向其中一個顏色，
  切換與回滾由 [`platform/k8s/station2-publichealth/deploy.sh`](../platform/k8s/station2-publichealth/deploy.sh)
  執行，守衛是 [`platform/k8s/station2-publichealth/test_bluegreen.sh`](../platform/k8s/station2-publichealth/test_bluegreen.sh)。
  要看現在流量在哪一個顏色：
  `kubectl --context k3d-devops-lab -n station2 get svc station2-twin -o jsonpath='{.spec.selector}'`
- **Compose 那一份仍是單色**，理由沒有變：它把資料庫與應用綁在同一份檔案，
  第二個顏色會撞到同一個 host port 與同一個具名 volume。拆分登記在
  [`../docs/Backlog.md`](../docs/Backlog.md)。轉向 K8s 的理由見
  [ADR-0010](../docs/decisions/0010-kubernetes-target-runtime-k3s.md)。

這裡放用來驗證 DevOps 平台的 POC、Pilot 與測試服務。

每個 Pilot 都可以有自己的：

- Dockerfile
- compose.yaml
- application code
- tests
- service-specific README

但必須遵守 [../NEW_SERVICE_GUIDE.md](../NEW_SERVICE_GUIDE.md) 的服務契約與安全基線。

Pilot 成功不代表產品成功，只代表平台能夠對該服務完成建置、測試、掃描、部署、監控與回滾驗證。

---

## 目前的 Pilot

- [`station2-publichealth/`](station2-publichealth/README.md) — 疾病監測數位孿生。服務、ingest 批次、
  migrations、mlops 都在這個目錄底下。

在 2026-09-02 之前這個檔案沒有連到它。目錄裡只有一個 Pilot 的時候，
「大家都知道在哪」是成立的；等到有第二個，沒有人會回頭補這條連結，
而那時候缺的就不只一條。

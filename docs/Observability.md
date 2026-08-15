---
type: explanation
title: 可觀測性與確定性健康判定
description: Observability stack and the deterministic health verdict contract, including why exit 3 (unknown) is distinct from healthy.
tags:
  - observability
  - monitoring
timestamp: 2026-08-15T20:00:54+08:00
---
# Observability

實作與驗證細節見 `platform/observability/README.md`。

## Local stack

- Grafana: dashboard and alert entry point.
- Prometheus: metrics, time series, alert rule evaluation.
- Alertmanager: alert grouping, deduplication, silencing, inhibition.
- Loki: container logs.
- Alloy: Docker log collection.

## Deterministic health verdict

`platform/observability/check_health.sh` 是「服務好壞」的單一可重現答案，
供排程 agent 或人類呼叫。門檻不在腳本裡，而在版控的
`platform/observability/prometheus/alerts/*.yml`。

Exit code 契約：`0` HEALTHY／`1` DEGRADED／`2` CRITICAL／
`3` UNKNOWN（**監控本身壞掉，健康狀態無法判定**）。

`3` 是這支腳本存在的理由：壞掉的 Prometheus 回報「零個告警」，健康的
Prometheus 也回報「零個告警」，兩者對天真的檢查程式完全無法區分，而天真的
檢查程式會把兩者都判成「正常」——監控在最需要它的時候靜默地 fail open。
因此腳本會先證明「確實有東西在監看」（Prometheus 可達、規則數 > 0、規則
評估無錯、已接上 Alertmanager、Alertmanager 可達），才願意把空的告警清單
解讀為好消息。

## Required views

- Platform progress: pipeline, artifact, security gate, deploy and rollback status.
- Runtime health: up/down, CPU, memory, restart, latency, errors and disk.
- Pilot evidence: test result, image digest, logs, metrics and failure events.

Production later adds authentication, TLS, alert routing, retention and HA storage.

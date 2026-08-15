---
type: plan
title: MLOps / LLMOps 導入順序
description: Intended sequence for MLOps and LLMOps capability, and what the current MLX endpoint is and is not.
tags:
  - mlops
  - llmops
  - planning
timestamp: 2026-08-11T20:05:56+08:00
---
# Future MLOps and LLMOps

This is deferred. Keep interfaces, do not install the full platform now.

- MLflow: tracking, artifacts, model registry and lineage.
- Airflow: scheduled and cross-system batch DAGs.
- Kubeflow: Kubernetes-native ML pipelines after Kubernetes exists.
- LLMOps: version model/prompt/tool/evaluation artifacts, run regression and safety gates, observe latency/tokens/cost, then require human approval for promotion.

Current MLX endpoint is only an automation actor for code, CI, API, diff and monitoring checks.

## 具體模型類型（2026-08-11 補充，來自實際職務範疇）

以下不是新的交付項目，是讓上面抽象的 MLflow/LLMOps 規劃有明確對象，出現在
`docs/Future-DataOps.md` 的職務範疇說明中：

- 疾病風險預測、預後分析、治療成效評估
- 病人分群
- 臨床試驗媒合
- 臨床決策支援
- AI Agent / LLM 應用（跟現有 `127.0.0.1:9000` MLX endpoint 是同一條線，
  但 Agent/應用本身的部署對象是這裡列的模型類型，MLX 目前仍只是
  automation actor，不是這些模型的 serving endpoint）

這些模型的訓練/驗證/準確度評估屬於研究工作本身，不是 `platform/` 的範圍；
`platform/` 要提供的是它們的**部署、版本控管、audit trail**——跟現有
`platform/compose/`、`platform/security/` 的 evidence-driven 模式是同一套
邏輯，只是套用對象從容器映像換成模型 artifact。詳見 `docs/Future-DataOps.md`
「What belongs in this platform vs. what doesn't」。

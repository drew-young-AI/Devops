---
type: overview
title: DevOps 平台總覽
description: "Entry point: what this platform is, its directory boundaries, and how platform/ pilots/ and evidence/ relate."
tags:
  - devops
  - platform
  - entry-point
timestamp: 2026-08-11T20:05:56+08:00
---
# DevOps Platform Workspace

## 新視窗接續工作

開始前請先閱讀：

1. [Plan.md](Plan.md) 的 `Handoff / Current Status`
2. [NEW_SERVICE_GUIDE.md](NEW_SERVICE_GUIDE.md)
3. [docs/Architecture.md](docs/Architecture.md)
4. [docs/IaC.md](docs/IaC.md)
5. [docs/Network.md](docs/Network.md)
6. [docs/Security.md](docs/Security.md)
7. [docs/Pilot-Validation.md](docs/Pilot-Validation.md)、[docs/Human-Usability-Review-Checklist.md](docs/Human-Usability-Review-Checklist.md)
8. [docs/Future-ML-LLMOps.md](docs/Future-ML-LLMOps.md)、[docs/Future-DataOps.md](docs/Future-DataOps.md)（延後範圍，但架構設計需考量）

目前正在建造的是「單一 Mac 上的縮小版企業 DevOps 控制面」，不是實際產品，也不是完整企業 HA 環境。

目前主線：

```text
External Git source
  -> CI/CD
  -> OpenTofu / resource contract
  -> Network / NGINX / HTTPS
  -> Docker Compose deployment
  -> Security
  -> Grafana / Prometheus / Loki
  -> Human approval
  -> rathole Public URL experiment
```

如果需求與 Plan 衝突，先停下來提出差異，不要自行擴大工具或環境範圍。

這個目錄只管理 DevOps 平台與其驗證範例，必須區分平台本身與被測的 POC/Pilot。

```text
Devops/
├── Plan.md
├── README.md
├── platform/
│   ├── ci/             # 共用 CI/CD template 與 pipeline policy
│   ├── compose/        # 平台元件的 Compose 定義
│   ├── nginx/          # Reverse proxy 與 routing template
│   ├── security/       # scan、SBOM、signing、policy
│   ├── observability/  # metrics、log、trace 基礎設定
│   └── runbooks/       # 平台維運與故障處理
├── pilots/
│   └── station1-hello/ # 被測服務，不是 DevOps 平台元件
└── evidence/           # 測試輸出、報告與驗證紀錄
```

## 邊界規則

- `platform/` 不得依賴特定 Pilot 的業務程式。
- `pilots/` 可以使用 platform，但不得把 Pilot 的需求反向寫成平台規則。
- `evidence/` 只保存可追溯的測試證據，不放 Secret、token 或完整敏感 payload。
- `Plan.md` 定義平台能力與品質門檻，不代表任何 Pilot 的產品需求。

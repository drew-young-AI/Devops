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
9. [docs/Backlog.md](docs/Backlog.md)——遞延項目，**每一項附「現在做 vs 等 K8s」判定**
10. [docs/Kubernetes-Readiness.md](docs/Kubernetes-Readiness.md)——什麼帶得走、什麼被取代、什麼完全沒碰過

**給主管閱讀**：[docs/System-State.html](docs/System-State.html)（機制盤點與擴充／收斂建議）。

主管簡報（架構圖／流程圖／現況燈號）是**依需求生成的衍生產物，不入庫**——
來源是 `Plan.md`、`STAGE_REVIEW.md` 與各 `platform/*/README.md`。需要時請 AI
依當下狀態重新生成，不要保留過期的簡報檔（過期的架構圖比沒有更糟）。

目前正在建造的是「單一 Mac 上的縮小版企業 DevOps 控制面」，不是實際產品，也不是完整企業 HA 環境。

目前主線：

```text
External Git source
  -> CI/CD
  -> OpenTofu / resource contract
  -> Network / NGINX / HTTPS
  -> Docker Compose deployment（blue/green + rollback）
  -> Database migration gate（expand/contract、checksum、單一 transaction）
  -> Security（Trivy / Gitleaks / Semgrep SAST / ZAP DAST / SBOM / Cosign）
  -> Grafana / Prometheus / Loki / Alertmanager
  -> LLM evidence（本地 MLX，不具 release 阻擋權）
  -> Human approval
  -> Tailscale ingress（取代原 rathole 方案）
```

**Public URL 已解決**：原本卡在「需要人類決定雲端供應商」的 rathole/Cloudflare
方案不再需要。所有服務綁 127.0.0.1，Tailscale 直接可達 loopback，
`tailscale serve` 不必開 router port 也不必雲端帳號。見
[platform/ingress/README.md](platform/ingress/README.md)。

如果需求與 Plan 衝突，先停下來提出差異，不要自行擴大工具或環境範圍。

這個目錄只管理 DevOps 平台與其驗證範例，必須區分平台本身與被測的 POC/Pilot。

```text
Devops/
├── Plan.md               # 計畫與 Handoff / Current Status（權威現況）
├── README.md
├── STAGE_REVIEW.md       # 階段性 review
├── NEW_SERVICE_GUIDE.md  # 新服務接入契約
├── platform/
│   ├── ci/             # 共用 CI/CD template 與 pipeline policy
│   ├── compose/        # 部署 adapter（develop + production-like blue/green）
│   ├── db/             # migration gate（expand/contract、checksum、交易）
│   ├── nginx/          # Reverse proxy 與 routing template
│   ├── ingress/        # Tailscale 對外暴露 + 每目標暴露天花板
│   ├── vault/          # Secret 管理、identity、稽核軌跡、rotation
│   ├── security/       # Trivy / Gitleaks / Semgrep / ZAP、SBOM、Cosign
│   ├── observability/  # Prometheus / Grafana / Loki / Alloy / Alertmanager
│   ├── llm-review/     # 本地 MLX 複審（產出證據，不具 release 阻擋權）
│   ├── backup/         # 備份、還原演練、覆蓋率檢查、異地同步
│   ├── scheduler/      # launchd 排程（日曆觸發 + 執行來源溯源）
│   ├── statusdag/      # 狀態 DAG（燈號）
│   ├── valuestream/    # 價值流看板
│   ├── docs/           # OKF 文件規範與符合性檢查
│   ├── iac/            # OpenTofu skeleton、Checkov、OPA policy
│   └── tests/          # 平台自身的測試套件
├── pilots/
│   └── station2-twin/  # 有狀態：PostgreSQL + 公衛監測 digital twin
│                       # （station1-hello 於 2026-08-19 退役）
└── evidence/           # 測試輸出、報告與驗證紀錄
    └── _retired/       # 已退役服務的證據，移出探針的 glob 範圍
```

## 邊界規則

- `platform/` 不得依賴特定 Pilot 的業務程式。
- `pilots/` 可以使用 platform，但不得把 Pilot 的需求反向寫成平台規則。
- `evidence/` 只保存可追溯的測試證據，不放 Secret、token 或完整敏感 payload。
- `Plan.md` 定義平台能力與品質門檻，不代表任何 Pilot 的產品需求。

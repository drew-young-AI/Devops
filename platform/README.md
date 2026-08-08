# Platform 元件

目前平台完成到：local CI + local observability + Git-triggered CI（GitHub Actions）+ IaC skeleton（OpenTofu，provider-neutral contract）+ local HTTPS/NGINX adapter + develop deployment adapter。Production-like promotion（blue/green + 人工核准 + rollback）與 Public URL 尚未完成，詳見根目錄 `Plan.md` 的 handoff status。

這裡只放可被多個 Pilot 共用的 DevOps 元件，不放特定服務的業務程式。

```text
platform/
├── ci/              # pipeline contract、local runner、共用 CI template
├── observability/   # Prometheus、Grafana、Loki、Alloy
├── iac/             # OpenTofu skeleton、Checkov、OPA policy（provider-neutral）
├── nginx/           # reverse proxy、local HTTPS、routing template（見 nginx/README.md）
├── compose/         # develop deployment adapter（見 compose/README.md）；production-like 尚未實作
├── security/        # Trivy、Gitleaks、SBOM、Cosign、policy（尚未建立）
└── runbooks/        # deploy、rollback、incident、restore（尚未建立）
```

Platform 的修改必須考慮所有 Pilot，不得為了單一 Pilot 直接放寬共用安全門檻。

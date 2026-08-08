# Platform 元件

目前平台完成到：local CI + local observability。Git-triggered CI、IaC、deployment adapter、HTTPS 與 Public URL 尚未完成，詳見根目錄 `Plan.md` 的 handoff status。

這裡只放可被多個 Pilot 共用的 DevOps 元件，不放特定服務的業務程式。

```text
platform/
├── ci/              # pipeline contract、local runner、共用 CI template
├── observability/   # Prometheus、Grafana、Loki、Alloy
├── security/        # Trivy、Gitleaks、SBOM、Cosign、policy
├── compose/         # 平台元件的 Compose adapter
├── nginx/           # reverse proxy 與 routing template
└── runbooks/        # deploy、rollback、incident、restore
```

Platform 的修改必須考慮所有 Pilot，不得為了單一 Pilot 直接放寬共用安全門檻。

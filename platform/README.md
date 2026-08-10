# Platform 元件

目前平台完成到：local CI + local observability + Git-triggered CI（GitHub Actions）+ IaC skeleton（OpenTofu，provider-neutral contract）+ local HTTPS/NGINX adapter + develop/production-like deployment adapter（blue/green + rollback）+ Vault secret management + secret rotation policy + container security scan gate（Trivy）+ SBOM + Cosign 簽章（SBOM 與 container image 皆已簽章）+ Gitleaks history scan + Registry promotion（GHCR）。所有目前已知可本機自主完成的項目皆已完成；唯一剩餘項目 Public URL（rathole/Cloudflare Tunnel）需要人類決定雲端供應商才能繼續，詳見根目錄 `Plan.md` 的 handoff status。

這裡只放可被多個 Pilot 共用的 DevOps 元件，不放特定服務的業務程式。

```text
platform/
├── ci/              # pipeline contract、local runner、共用 CI template
├── observability/   # Prometheus、Grafana、Loki、Alloy
├── iac/             # OpenTofu skeleton、Checkov、OPA policy（provider-neutral）
├── nginx/           # reverse proxy、local HTTPS、routing template（見 nginx/README.md）
├── compose/         # develop + production-like (blue/green) deployment adapter（見 compose/README.md）
├── vault/           # HashiCorp Vault Community、secret migration（見 vault/README.md）
├── security/        # Trivy container scan gate、SBOM、Cosign SBOM 簽章、Gitleaks history scan（見 security/README.md）
└── runbooks/        # deploy、rollback、incident、restore（尚未建立）
```

Platform 的修改必須考慮所有 Pilot，不得為了單一 Pilot 直接放寬共用安全門檻。

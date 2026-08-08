# Enterprise DevOps Miniature Plan

## 0.1 Handoff / Current Status

> 本節是跨視窗交接紀錄。新執行緒應先讀本節、`README.md` 與 `docs/`，再採取任何動作。

### 已完成

- [x] 建立 DevOps 與 Pilot 的目錄邊界。
- [x] Station 1：Hello World container、health、non-root、resource limit、graceful shutdown。
- [x] Station 2：local CI，包含 compile、unit/contract test、container build、image metadata。
- [x] Local observability：Grafana、Prometheus、Loki、Alloy。
- [x] Prometheus 已抓取 Station 1 `/metrics`。
- [x] Loki 已收集 Station 1 Docker logs。
- [x] Grafana 已建立 DevOps Overview dashboard。
- [x] 已建立新服務接入文件 `NEW_SERVICE_GUIDE.md`。
- [x] 已將 Plan 拆分為 Architecture、IaC、Network、Security、Observability、Pilot Validation 與 Future MLOps/LLMOps 文件。
- [x] GitHub source of truth：https://github.com/drew-young-AI/Devops（public repo，PAT-based push，無 secret 提交）。
- [x] Git-triggered CI：`.github/workflows/iac-validate.yml`（push 觸發，fmt → validate → Checkov → plan → tfsec → evidence），已驗證綠燈（見 `PHASE1_COMPLETION_REPORT.md`）。
- [x] OpenTofu IaC skeleton：`platform/iac/`，provider-neutral contract（AWS/GCP/Azure adapter 以註解預留，不 apply）、30+ 已驗證變數、Checkov + OPA/Conftest policy。State governance 僅文件化契約（local state 為 Phase 1 預設，尚未接 MinIO/cloud backend）。
- [x] Local HTTPS + NGINX adapter：`platform/nginx/`，mkcert TLS、反向代理到 station1-hello、rate limit、security headers、correlation ID、結構化 JSON log。端到端驗證見 `platform/nginx/README.md`「Verified End-to-End」，含 Loki 實際查詢結果。
- [x] Develop Compose deployment adapter：`platform/compose/deploy.sh`（build/deploy/status/teardown），獨立 Compose project + network、環境專屬 env file 注入、build 與 deploy 分離（deploy 絕不重build）。
- [x] Production-like blue/green + rollback：`deploy.sh promote|rollback`。Develop-validation gate（拒絕未在 develop 驗證過的 image）、blue/green 雙色（port 18081/18082）、NGINX 流量切換（`nginx -s reload`）、真人互動確認（`read -p` 輸入 `PROMOTE`/`ROLLBACK`，無 `--yes` 旁路）。端到端驗證見 `platform/compose/README.md`「Verified End-to-End」，含用 NGINX access log 的 `upstream_addr` 欄位證明流量真的切換（非只改了 state 檔案）、以及測試過程中發現並修正一個 exit code 誤報 bug。

### 尚未完成的主要交付鏈

- [ ] Registry promotion 與 immutable artifact flow。
- [ ] Vault migration、Secret rotation 與 Gitleaks history scan。
- [ ] Cloud trial VM + rathole Public URL experiment。
- [ ] Optional Cloudflare Tunnel adapter。
- [ ] Pilot technical validation 與 Human Platform Usability Review。

### 已鎖定決策

```text
Cloud provider：不選定，使用 provider-neutral contract
IaC：OpenTofu 為主，Checkov/OPA/Conftest 作 policy
Runtime：Docker Engine + Docker Compose
Observability：Grafana + Prometheus + Loki + Alloy
Public URL 主方案：Cloud trial VM + rathole + NGINX
Public URL 快速方案：Cloudflare Tunnel adapter
Local ingress：NGINX + local HTTPS
Secret：HashiCorp Vault Community；.env 只作 migration source
MLX：127.0.0.1:9000，LLM automation actor，不是 deployment target
Kubernetes：未來 adapter，目前不導入
MLOps/LLMOps：保留接口，延後擴充
```

### 目前不應做的事

- 不要把 Pilot 程式放進 `platform/`。
- 不要在目前 Mac 上假裝具備 multi-node HA、真實 F5、CDN 或 production capacity。
- 不要先安裝 Kubernetes、Argo CD、Kubeflow 或 Airflow。
- 不要把 Cloudflare hosted tunnel 的結果當成自建企業網路能力。
- 不要把明文 `.env` 直接提交 Git、image、artifact、log 或 prompt。
- 不要使用個人全權限 token；不得要求使用者貼出 token。

### 下一個建議動作

```text
1. [x] 選定 GitHub Free 或外部 GitLab Free
2. [x] 建立 external Git source of truth
3. [x] 建立 OpenTofu skeleton 與 provider-neutral resource contract
4. [x] 加入 Checkov policy validation
5. [x] 建立 local HTTPS + NGINX adapter
6. [x] 建立 develop deployment adapter
7. [x] 建立 production-like blue/green + 人工核准 + rollback
8. [ ] 建立 rathole Public URL experiment  <- NEXT
```

## 1. 定位

本專案在單一 MacBook 上建立縮小版企業 DevOps 控制面，不假裝具備多節點 HA、真實 VPC、F5、CDN 或 production capacity。

```text
Code
  -> Infrastructure
  -> Network
  -> Security
  -> Deployment
  -> Observability
  -> Human Approval
```

Pilot 只用來驗證平台，不代表產品需求或產品效果已完成。

## 2. 範圍

### 本階段完成

- [ ] GitHub Free 或外部 GitLab Free source control。
- [ ] OpenTofu IaC validation、plan、policy 與 state governance。
- [ ] provider-neutral Cloud resource planning。
- [ ] local network architecture、NGINX、local HTTPS 與 F5/WAF/CDN contract simulation。
- [ ] CI/CD、container registry、security gates、artifact promotion。
- [ ] develop / production-like 最小隔離、blue/green 與 rollback。
- [ ] Grafana、Prometheus、Loki、audit 與 evidence。
- [ ] Pilot 的 technical deployment、test、failure path 與 recovery evidence。
- [ ] Human Platform Usability Review。

### 本階段延後

- [ ] 實際 Cloud resource apply。
- [ ] 多節點 HA、真實 F5/WAF/CDN 與大型流量。
- [ ] Kubernetes、Argo CD、Kubeflow、Airflow。
- [ ] MLOps/LLMOps 完整平台；只保留未來 integration contract。
- [ ] 產品 PRD、產品 UX 與業務效果驗收。

## 3. 明確技術決策

| 領域 | 決策 |
|---|---|
| Cloud provider | 不選定；採 provider-neutral reference architecture |
| IaC | OpenTofu 為主，Checkov/OPA/Conftest 作 policy validation |
| Source control | 外部 GitHub Free 或 GitLab Free，不在 Mac 部署 GitLab CE |
| Runtime | Docker Engine + Docker Compose |
| Observability | Grafana + Prometheus + Loki + Alloy |
| Local ingress | NGINX + local HTTPS |
| Secret | HashiCorp Vault Community；`.env` 只作 migration source，不作正式 Secret store |
| Object storage | MinIO，可作 S3-compatible artifact/model/backup/state blob store |
| Kubernetes | 未來 deployment adapter，不是目前 runtime |
| MLX | `127.0.0.1:9000` 的 LLM automation endpoint，不是 deployment target |
| Public URL experiment | 主方案：Cloud trial VM + rathole + NGINX；可選 Cloudflare Tunnel adapter；不暴露 MLX endpoint |

## 4. 兩環境最小隔離

Mac 資源有限，develop 與 production-like 不長期同時執行。必要隔離只有：

- [ ] 不同 Compose project 與 network。
- [ ] 不同 environment config 與 Secret reference。
- [ ] Production-like 只能 promotion develop 已驗證的同一個 image digest。

需要同時啟動時才配置不同 port；stateful volume 只有服務需要時才建立。production-like 預設停止，以節省 CPU、memory、disk。

## 5. Git 與 Token 原則

- [ ] GitHub Free 或 GitLab Free 擇一作為 source of truth。
- [ ] 不使用個人全權限 token；使用最小 scope、短期 token、fine-grained PAT、deploy key 或 OIDC。
- [ ] Token 不進 repository、`.env`、Docker image、artifact、log 或 prompt。
- [ ] GitHub Actions/GitLab CI 只取得必要的 registry、CI、issue 或 read/write scope。
- [ ] Production promotion 與 Secret policy 需人工核准。

## 6. 執行順序

```text
P0  Secret migration 與硬體/resource baseline
P0  External Git source + CI integration
P0  OpenTofu skeleton + provider-neutral resource contract
P0  Local network/NGINX/HTTPS contract
P1  Security gates + registry + artifact promotion
P1  Develop deployment + production-like rollback
P1  Pilot technical validation + usability review
P2  Cloud adapter / F5 / WAF / CDN implementation
P3  Kubernetes adapter
P4  MLOps / LLMOps expansion
```

## 7. 完成定義

```text
可建置 -> 可掃描 -> 可部署 -> 可驗證 -> 可監控 -> 可回滾
```

細節與歷史決策見：

- [Architecture.md](docs/Architecture.md)
- [IaC.md](docs/IaC.md)
- [Network.md](docs/Network.md)
- [Security.md](docs/Security.md)
- [Observability.md](docs/Observability.md)
- [Pilot-Validation.md](docs/Pilot-Validation.md)
- [Future-ML-LLMOps.md](docs/Future-ML-LLMOps.md)
- [Plan-detail.md](docs/Plan-detail.md)

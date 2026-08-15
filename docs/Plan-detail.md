---
type: plan
title: 平台計畫細節（站別）
description: Full station-by-station plan with acceptance criteria, hardware capacity gating, and Kubernetes migration preconditions.
tags:
  - planning
  - stations
  - detail
timestamp: 2026-08-15T20:00:54+08:00
---
# Enterprise Application and LLM Delivery Platform Plan

> 目標：建立一套可套用於 Python、Node.js、Java、Go、.NET 等技術棧的企業級容器開發、交付、部署與資安標準。

## 0. 本階段範圍界線

目前階段只建造 DevOps 系統與平台落地能力，不開發任何實際產品需求，也不進行產品 PRD、UX 或業務效果驗收。

### In Scope：本階段要完成

- [ ] Git repository、branch protection 與版本策略。
- [ ] CI/CD pipeline 與 develop/production 兩環境。
- [ ] Container build、registry、artifact promotion 與 rollback。
- [ ] Docker Compose、NGINX、HTTPS、Secret、弱掃與 audit。
- [ ] 藍綠部署、health check、smoke test 與 deployment evidence。
- [ ] Observability、Runbook、backup/restore 與故障演練。
- [ ] 以 MLX endpoint 作為自動化檢查與平台整合的測試對象。

### Out of Scope：本階段不做

- [ ] 不開發實際業務產品或產品功能。
- [ ] 不定義正式產品 PRD。
- [ ] 不做最終 UX、使用者體驗或業務價值驗收。
- [ ] 不把 MLX model output 當成產品正確性驗收。
- [ ] 不因 MLX 而建立正式對外 AI 產品入口。
- [ ] 不在平台尚未驗證前導入不必要的 Kubernetes 複雜度。

### 平台階段的完成定義

本階段的成功只表示：

```text
可建置 -> 可掃描 -> 可部署 -> 可驗證 -> 可監控 -> 可回滾
```

產品需求、實際體驗與業務結果留到後續產品開發階段，由人類負責 PRD 與最終驗收。

## 0AA. 縮小版企業平台定位

本專案不是把整個企業平台塞進一台 MacBook，而是保留企業級的控制面、契約與證據鏈，縮小執行面的規模。

### 本機保留的企業能力

- [ ] IaC module、resource contract、plan/apply approval 與 state governance。
- [ ] Cloud resource planning、tagging、cost、RTO/RPO 與 environment contract。
- [ ] Network architecture、DNS、TLS、LB、WAF、firewall、route 與 east-west policy。
- [ ] CI/CD、artifact promotion、security gates、observability、audit 與 rollback。
- [ ] Human approval、LLM automation delegation、runbook 與 evidence chain。

### 本機刻意縮小的執行面

- [ ] 單一 Mac host，不能宣稱 multi-node HA。
- [ ] 單一或少量 Pilot，不能推論 multi-application capacity。
- [ ] 低流量與短時間測試，不能推論 production throughput。
- [ ] Local-only endpoint 與 Compose adapter，不能宣稱真實 VPC、F5 或 CDN 已上線。
- [ ] Production-like 流程模擬，不能宣稱真正 production resilience。

### 目前優先順序

```text
P0  IaC 與資源規劃
P0  Network architecture 與安全邊界
P0  CI/CD、artifact、security、observability、approval
P1  Develop / production-like deployment 與 rollback
P2  Cloud provider adapter、F5/WAF/CDN 實際整合
P3  MLOps / LLMOps 擴充
```

MLOps 與 LLMOps 保留接口與未來擴充位置，但目前不應主導平台設計，也不應為了它們提前導入 Kubeflow、Airflow 或 Kubernetes。

## 0A. 本機硬體與資源資格審查

在開始建置前，先確認本機是否能同時承載 MLX inference、Docker、CI runner、觀測工具與 develop 平台。硬體規格只能作為初步資格，仍需用實際模型與 workload benchmark 做 Go/No-Go 判定。

### 已觀測環境

| 資源 | 目前狀態 | 初步判定 |
|---|---|---|
| Machine | MacBook Pro，Apple M5 Pro | ARM-native，符合 MLX 方向 |
| CPU | 18 cores（6 Super、12 Performance） | 足以支援平台服務與本機測試，仍需觀察並行負載 |
| Memory | 64 GB unified memory | 可作 PoC；模型、Docker VM 與其他程序需設定上限 |
| Storage | 約 470 GiB 可用 | 目前可作 PoC，但需保留模型、image、cache、log 與 backup 空間 |
| MLX model | 目前模型目錄約 18 GB | 磁碟可容納，實際 unified memory 峰值需 benchmark |
| Runtime | `/Users/drew/ENV/localLLM/bin/python` | 使用隔離 Python runtime |
| Endpoint | `127.0.0.1:9000` | local-only LLM automation endpoint |
| Container CLI | Docker CLI 已存在 | 必須另外確認 Docker daemon 與 VM 資源配置 |

### 開工前硬體 Gate

- [ ] 確認 Docker daemon 可正常執行 image build、run、volume 與 network。
- [ ] 確認 Docker Desktop/engine 的 CPU、memory、disk image 上限與實際使用量。
- [ ] 確認 MLX model cold start、warm start、peak unified memory、tokens/sec 與 p95 latency。
- [ ] 確認 MLX 運行期間 Docker build、CI test、NGINX、Vault、監控工具不造成 memory pressure 或 swap thrashing。
- [ ] 設定 model、Docker、image、log、cache 與 backup 的 storage quota。
- [ ] 保留至少一個明確的磁碟安全水位，低於水位時停止下載 image/model 並告警。
- [ ] 設定 CPU、memory、storage、並發與 timeout 的 baseline。
- [ ] 執行 30 至 60 分鐘 soak test，確認沒有 OOM、memory leak、過熱降頻或 endpoint 不穩定。
- [ ] 確認本機不是 production host；production 需另有符合 SLA、backup、權限與網路要求的執行環境。

### 初步 Go/No-Go

目前硬體可進入 PoC 的「條件式 Go」：Apple Silicon、18 核心、64 GB unified memory、約 470 GiB 可用磁碟，足以開始平台驗證。但在完成 Docker daemon、Docker resource limits、MLX memory/latency benchmark 與 soak test 前，不得宣稱已具備 production capacity。

## 0B. 實驗策略：最大廣度、最小負荷

本階段採用 breadth-first thin-slice，而不是先建立高負荷或完整高可用平台。每個站別只啟動驗證該控制目的所需的最少程序，完成證據與失敗處理後才進入下一站。

原則：

- [ ] 一次只增加一個平台能力，避免無法定位故障來源。
- [ ] 每個站別使用單一服務、低併發、短測試與明確 timeout。
- [ ] 優先驗證 interface、權限、證據、rollback 與異常路徑，不先追求 throughput。
- [ ] 能用 local process 驗證的項目，不先啟動額外 container。
- [ ] 每站保留 test result、log、resource snapshot 與結論。
- [ ] 發現問題時先修正平台契約，再擴大測試範圍。
- [ ] 所有容器設定 CPU、memory、PID、storage 與 log limit。
- [ ] 高併發、高可用、故障切換與大規模 mesh 仍是目標能力，但不在第一輪以大量流量驗證。
- [ ] 第一輪使用 hello world 與最小 mock dependency，完整覆蓋交付、資安、網路、觀測、權限與回滾路徑。
- [ ] 低負荷不代表低廣度；每個控制點至少要有成功、失敗與恢復案例。

## 0C. 站別驗證順序

### Station 0：硬體與基礎環境

- [ ] 確認 Docker daemon、Compose、network、volume 與 registry access。
- [ ] 確認 MLX endpoint 可啟動、停止、重啟與回報錯誤。
- [ ] 建立硬體、記憶體、磁碟與 process baseline。

### Station 1：最小服務容器

- [x] 建立一個無外部依賴的 hello/health service。
- [x] 驗證 Dockerfile、非 root、health check、stdout log 與 graceful shutdown。
- [x] 使用單一 container、單一 replica、最低資源限制。
- [x] 證據：`pilots/station1-hello/README.md`、Compose build log、endpoint smoke test、container inspect 與 graceful shutdown log。
- [x] 修正一次真實缺陷：signal handler 的 shutdown 交握，避免 timeout 後被強制終止。

### Station 2：CI 基線

- [ ] Git commit 觸發 lint、unit test、container build；目前先以 local runner 等價驗證，待 Git 平台接入後補上 webhook。
- [x] 保存 test result、image tag、commit SHA、image digest 與 pipeline log；證據位於 `evidence/station1-hello/`。
- [x] Pipeline 使用 `set -euo pipefail`，任一必要 stage 失敗即停止後續步驟；首次執行已發現並修正 artifact path 初始化錯誤。
- [x] Local CI 已通過：compile、3 項 unit/contract tests、container build、image metadata。

### Station 3：安全基線

- [ ] 加入 Gitleaks、Trivy、SBOM 與最小 SAST。
- [ ] 使用一個刻意引入的測試漏洞驗證 gate 能阻擋 release。
- [ ] 驗證 scan report 不包含 Secret 明文。

### Station 4：Develop deployment

- [ ] 自動部署單一服務至 develop。
- [ ] 驗證 configuration、Secret reference、health、smoke test 與 rollback。
- [ ] 保持 develop 與 production 兩套隔離設定，不建立固定 staging。

### Station 5：MLX automation integration

已建置：`platform/llm-review/`（見該目錄 README）。

- [x] 由 LLM endpoint 執行 code、Git diff、API test 或 pipeline report 檢查。
- [x] 只允許讀取與低風險、可逆操作（只讀 git diff 與 `evidence/*.json`，
      不寫入任何服務狀態；唯一的寫入是新增一個 evidence 檔）。
- [x] 產出 `LLM-generated evidence`，不產出 Human Acceptance
      （verdict 不影響 exit code；`promote` 顯示後仍要求真人確認）。
- [x] 驗證 LLM unavailable、timeout、錯誤輸出與人工 review 路徑
      （5 種降級情境真實注入測試，非推論）。

### Station 6：Production-like release

- [ ] 使用 develop 已驗證的同一個 image digest。
- [ ] 執行 approval、change record、production blue/green、smoke test 與 rollback。
- [ ] 使用最低限度的 NGINX、HTTPS、audit 與監控配置。

### Station 7：觀測與故障演練

- [ ] 收集 request、error、latency、CPU、memory、restart 與 deployment metrics。
- [ ] 測試 container crash、MLX unavailable、Secret unavailable、registry unavailable。
- [ ] 每個故障都必須有告警、診斷證據、恢復動作與結果。

### Station 8：負荷擴展前的停止點

- [ ] 完成所有站別的低負荷驗證後，才開始 baseline、load、stress 與 soak test。
- [ ] 未完成前述站別，不進行大模型高併發或長時間壓測。
- [ ] 任何新增工具都必須對應一個已識別的控制缺口，不為了工具數量而增加資源負擔。

### 後續非功能測試：保留但延後執行

- [ ] 高併發：確認 request throughput、p95/p99 latency、queue、connection pool 與 rate limit。
- [ ] 高可用：確認 process restart、container replacement、host failure、入口切換與資料服務故障。
- [ ] 彈性：確認 retry、circuit breaker、backoff、idempotency 與 graceful degradation。
- [ ] 大規模 mesh：在服務數量與硬體條件足夠後，才評估 service mesh、distributed tracing 與 east-west policy。
- [ ] 壓測報告必須標示硬體、模型、版本、併發、資料量、測試時間與限制，不將 hello world 結果推論為 production capacity。

## 0D. 最小觀測組合

本地與 develop 階段採用以下組合：

```text
GitLab CI/CD UI -> pipeline、job、artifact、approval
Grafana         -> 統一 dashboard 與告警入口
Prometheus      -> numeric metrics、time series、alert rules
Loki            -> container logs
```

- [x] Prometheus、Grafana、Loki、Grafana Alloy 的 Compose 定義位於 `platform/observability/`。
- [x] Station 1 提供 `/metrics`，Prometheus target 已驗證為 `up`。
- [x] Alloy 可從 Docker socket 收集 Station 1 logs，Loki query 已驗證可取得 log stream。
- [x] Grafana 已載入 Prometheus、Loki datasource 與 DevOps Overview dashboard。
- [ ] GitLab 接入後補上 pipeline status、test result、security gate 與 artifact panel。
- [ ] Production 階段再加入 authentication、TLS、retention policy、alert routing 與 HA storage。

目前不導入 ELK、Argo CD 或 Kubernetes。ELK 留給大量全文 log、SIEM 或既有企業標準；Argo CD 留給 Kubernetes GitOps；兩者不是目前 Compose 觀測基線的必要元件。

## 0E. Kubernetes 評估：目前延後，不是否定

Kubernetes 適合企業級多服務平台，但目前這個 PoC 的主要目標是驗證 DevOps 控制鏈，不是驗證 Kubernetes 本身。兩者應分開。

| 面向 | 目前 Docker Compose | Kubernetes |
|---|---|---|
| 啟動成本 | 低，單一主機即可 | 高，需要 cluster、control plane、node、CNI、storage 與 ingress |
| 本機資源 | 適合目前 Mac 的低負荷廣度測試 | 會額外消耗 VM、memory、disk 與背景元件資源 |
| 部署模型 | Compose、NGINX、script 可直接理解 | Deployment、Service、Ingress、ConfigMap、Secret、RBAC、Policy |
| 藍綠部署 | 需自行實作 upstream/selector 切換 | 可用 Argo Rollouts 等工具標準化 |
| GitOps | 目前由 CI/CD pipeline 驅動 | Argo CD 可持續 reconcile Git 與 cluster 狀態 |
| 觀測 | Prometheus/Grafana/Loki 可直接使用 | 仍需 Prometheus/Grafana/Loki，另增加 cluster/node/pod 維度 |
| 高可用 | 單機只能模擬，不能提供真正 host HA | 可提供多 node、自動重排與服務自癒，但仍需正確設計 |
| 維運複雜度 | 低 | 高，包含升級、RBAC、network policy、storage、backup 與安全修補 |
| MLX host endpoint | 可由 host process 保持 local-only | 不適合直接假設可使用 macOS Metal，需另有 ARM/Metal runtime 設計 |

### 為何目前不適合直接導入 Kubernetes

- [ ] 現在只有一個低負荷 Pilot，尚未有足以證明 Kubernetes 必要性的服務數量或部署頻率。
- [ ] 目前最重要的未知數是 CI、Secret、artifact、observability 與人機權限交握，不是容器編排。
- [ ] Mac 上的 Kubernetes 通常需要額外 Linux VM，會稀釋 MLX、Docker 與監控的資源預算。
- [ ] 若現在導入，測試結果可能混入 Kubernetes 配置問題，降低 DevOps 控制鏈的可診斷性。
- [ ] Argo CD 只能解決 Kubernetes GitOps，不會替代 CI、security scan、Prometheus、Grafana 或 Loki。

### 導入 Kubernetes 的明確門檻

只有符合下列任一組條件，才啟動 Kubernetes PoC：

- [ ] 服務數量、部署頻率或團隊數量已超過 Compose 可治理範圍。
- [ ] 需要多 node 高可用、自動擴縮、rolling/canary 或多租戶隔離。
- [ ] 已有可支援 Kubernetes 的 Linux/ARM cluster、storage、ingress、registry、backup 與 identity。
- [ ] 已完成 Compose 版本的 CI、security、observability、rollback 與 runbook 驗證。

導入順序應為：

```text
Docker Compose platform contract
  -> Kubernetes manifests / Helm
  -> Kubernetes deployment validation
  -> Argo CD GitOps
  -> Argo Rollouts progressive delivery
```

## 0F. Docker 到 Kubernetes 的可搬遷契約

目前使用 Docker Compose，不代表把架構寫死在 Compose。Pilot 與 platform 元件必須遵守可搬遷契約，未來有 Kubernetes 時只替換 deployment adapter，不重寫 application contract。

### 應保持平台無關

- [ ] Application 只依賴 HTTP/API、environment configuration、Secret reference 與 service DNS。
- [ ] 每個服務提供 liveness、readiness、metrics、version 與 graceful shutdown。
- [ ] Image 使用 immutable digest、非 root、固定 base image 與 ARM-compatible build。
- [ ] Log 只輸出 stdout/stderr，不依賴本機檔案路徑。
- [ ] State 放在外部 database、object storage 或明確的 persistent volume contract。
- [ ] CPU、memory、PIDs、storage 與 timeout 以服務規格描述，不只寫在 Compose。
- [ ] CI pipeline、security scan、SBOM、signing 與 artifact promotion 不依賴 Compose 指令。

### 目前只限 Docker Compose

- [ ] `docker compose up`、Compose project name 與 local volume naming。
- [ ] `127.0.0.1` host port mapping。
- [ ] `host.docker.internal`，只能作本機 MLX host endpoint adapter。
- [ ] Docker socket mount 給 Alloy 的本機 log collection 方式。
- [ ] Compose `depends_on`、`restart` 與單機 resource limit 的語意。

這些項目必須隔離在 `platform/compose/` 或 local development adapter，不得被 application 程式碼依賴。

### 未來 Kubernetes 對應

| Compose / Platform | Kubernetes 對應 |
|---|---|
| Compose service | Deployment / StatefulSet |
| Compose network service name | Kubernetes Service / DNS |
| `environment` | ConfigMap / Secret reference |
| `healthcheck` | livenessProbe / readinessProbe |
| `ports` | Service / Ingress |
| `mem_limit`, `cpus` | resources.requests / resources.limits |
| volume | PersistentVolumeClaim 或外部 storage |
| `restart` | Controller reconciliation |
| Compose blue/green | Service selector、Argo Rollouts |
| local CI promotion | Registry promotion + Argo CD sync |
| Docker logs | stdout/stderr + cluster log collector |

### MLX 特殊邊界

MLX `127.0.0.1:9000` 是目前 Mac 上的 local user endpoint，不應直接搬成 Kubernetes workload。未來若需要 Kubernetes application 呼叫 MLX，必須另建：

- [ ] 可被 Kubernetes 存取的 inference endpoint 或 adapter。
- [ ] ARM/Metal/GPU runtime capability 驗證。
- [ ] NetworkPolicy、authentication、timeout、quota 與 fallback。
- [ ] 模型 artifact、cache、版本與硬體綁定策略。

在上述條件未完成前，Kubernetes migration 只搬移一般 application 與 platform service，不搬移 MLX host runtime。

## 0G. DevOps 平台尚未閉合的交付鏈

目前完成的是 local CI、Pilot container 與 observability。以下項目仍是 DevOps 平台的必要缺口：

### Platform delivery chain

- [ ] GitLab Community Edition 或選定 Git 平台的自架服務。
- [ ] Git repository、protected branch、Merge Request 與權限模型。
- [ ] GitLab Runner 或等效受控 CI runner。
- [ ] Container Registry 與 immutable artifact promotion。
- [ ] Develop environment 的自動部署。
- [ ] Production-like environment 的獨立 Compose project、設定與 Secret policy。
- [ ] Production approval、change evidence 與 release record。
- [ ] Blue/Green deployment、traffic switch、smoke test 與 rollback。
- [ ] NGINX reverse proxy、HTTPS、local Public URL simulation。
- [ ] F5/WAF integration contract；本機先用 NGINX adapter 模擬，不宣稱已完成 F5。
- [ ] Platform backup、restore、runbook 與 cleanup policy。

### Pilot validation chain

Pilot 不是只要 container 能啟動，而是要實際通過完整交付與運行驗證：

- [ ] 由 Git commit 觸發 CI。
- [ ] 由 CI 執行 lint、unit、contract、container、security 與 artifact checks。
- [ ] 自動部署至 develop。
- [ ] 由 API、smoke、E2E 或指定測試驗證服務行為。
- [ ] 由 Prometheus、Grafana、Loki 驗證運作狀態與診斷能力。
- [ ] 執行 timeout、dependency unavailable、container crash、rollback 等失敗測試。
- [ ] 產生 test result、image digest、log、metrics、incident evidence。
- [ ] 人類確認 Pilot 的實際效果與需求符合度。

目前的 Pilot 完成度應標記為：

```text
Container validation       PASS
Local CI baseline           PASS
Observability baseline      PASS
Git-triggered CI            NOT_CONNECTED
Develop auto-deploy         NOT_COMPLETED
Production-like deployment  NOT_COMPLETED
Blue/Green rollback         NOT_COMPLETED
Pilot effect validation     NOT_COMPLETED
```

## 0H. Pilot 實際落地與效果驗收

### Deployment evidence

每個 Pilot 必須能回答：

- [ ] 哪一個 commit 產生這個 image。
- [ ] 這個 image 的 digest 是什麼。
- [ ] 部署到哪一個環境、何時、由哪個 pipeline 執行。
- [ ] 使用了哪一份 configuration 與 Secret reference。
- [ ] 部署前後 health、smoke、metrics 與 logs 是否正常。
- [ ] 如果失敗，如何 rollback 到上一個 digest。

### Technical effect validation

技術驗收由自動化與 LLM 協助，人類審核證據：

- [ ] API status、schema、錯誤碼與 timeout。
- [ ] 服務啟動、readiness、graceful shutdown。
- [ ] 依賴故障與降級行為。
- [ ] CPU、memory、disk、restart、latency、error rate。
- [ ] Security scan、Secret scan、image metadata 與 SBOM。
- [ ] 部署、切換、回滾與恢復時間。

### Human effect validation

這不是 DevOps pipeline 自動判定的項目，必須由人類確認：

- [ ] Pilot 是否真正完成預期用途。
- [ ] 實際操作是否符合你的工作方式。
- [ ] 輸出是否足以支援決策或後續產品開發。
- [ ] 監控頁面是否能讓你快速理解現況。
- [ ] 錯誤與 rollback 流程是否可被人類理解與操作。

LLM 可以提交 technical evidence，但不可把 technical PASS 宣稱為 product effect PASS。

### Pilot status lifecycle

```text
CREATED
  -> BUILT
  -> SECURITY_CHECKED
  -> DEPLOYED_DEVELOP
  -> TECHNICALLY_VERIFIED
  -> HUMAN_EFFECT_REVIEW
  -> APPROVED_PILOT
  -> PRODUCTION_LIKE
  -> ROLLED_BACK / RETIRED
```

## 0I. Platform Engineering 與 Infrastructure as Code

DevOps 平台不能只管理 application image，也必須能以版本控制管理執行環境。基礎設施變更必須先 plan、review、approval，再 apply。

### 工具基線

- [ ] OpenTofu：IaC engine，管理 network、VM、DNS、firewall、load balancer 與 storage。
- [ ] Ansible：host baseline、OS hardening、package policy 與維運操作。
- [ ] Packer 或 image factory：建立可追溯的 VM/container host image。
- [ ] OPA/Conftest：對 IaC、Dockerfile、Kubernetes manifest 執行 policy check。
- [ ] GitLab CI：執行 `fmt`、`validate`、`plan`、security scan 與受控 `apply`。

### State 與環境

- [ ] IaC state 不放在 repository，使用加密、鎖定、版本保留的 backend。
- [ ] develop 與 production 使用相同 module，不同 variable 與 state。
- [ ] Cloud credential 使用 OIDC/workload identity，不保存長期 access key。
- [ ] 每個 apply 都保存 plan、commit SHA、操作者、approval 與結果。
- [ ] Infrastructure drift 需要定期偵測與報告。

目前本機階段先以 local IaC validation、Compose resource contract 與 network policy 文件驗證，不假裝已建立真正 Cloud infrastructure。

## 0J. Cloud Resource Planning

雲端規劃先建立 provider-neutral contract，避免直接綁定單一 Cloud：

```text
Organization / Account
  -> Region / Availability Zone
  -> VPC/VNet
  -> Public / DMZ / Application / Data / Management subnet
  -> Load Balancer / WAF / CDN
  -> Compute / Container Platform
  -> Database / Cache / Queue / Object Storage
  -> Monitoring / SIEM / Backup
```

每個資源必須定義：

- [ ] Owner、environment、application、cost center、data classification tag。
- [ ] CPU、memory、storage、network bandwidth 與 scaling limit。
- [ ] Availability、backup、RTO、RPO 與 retention。
- [ ] Region、AZ、subnet、route、security group 與 egress policy。
- [ ] 預估成本、預算告警與資源閒置清理。
- [ ] 建立、修改、升級、回滾與刪除流程。

## 0K. Network Engineering 與 Traffic Path

### 網路層級

```text
User / Client
  -> DNS / CDN
  -> WAF / DDoS protection
  -> F5 或 Cloud Load Balancer
  -> NGINX / Ingress
  -> Application service
  -> Data / Queue / External API
```

### 工具與責任

| 層級 | 工具或類型 | 責任 |
|---|---|---|
| DNS | Route 53、Azure DNS、Cloud DNS、Bind | name resolution、health routing |
| CDN | CloudFront、Azure Front Door、Cloud CDN、Cloudflare | cache、edge TLS、DDoS、edge routing |
| WAF/LB | F5、Application Gateway、ALB、NGINX | TLS、load balance、WAF、health check |
| Reverse proxy | NGINX | path routing、header、rate limit、upstream |
| Router | Cloud route table、VyOS、FRRouting、企業 router | routing、subnet、BGP/OSPF 視環境需要 |
| Firewall | Cloud firewall、pfSense、FortiGate、Palo Alto | north-south、east-west、egress policy |
| Network policy | security group、NACL、Kubernetes NetworkPolicy | workload isolation |
| Diagnosis | tcpdump、dig、curl、mtr、ss、Wireshark | DNS、TCP、TLS、HTTP、packet path |

### 網路驗證

- [ ] DNS resolution、TLS SNI、certificate chain 與 Host header。
- [ ] Client IP、`X-Forwarded-For`、request ID 與 protocol preservation。
- [ ] Firewall allow/deny、egress、east-west segmentation。
- [ ] Timeout、retry、connection pool、idle timeout、body size 與 rate limit。
- [ ] Load balancer health check 與 backend drain。
- [ ] F5/NGINX/Cloud LB 的責任不重疊且可追蹤。
- [ ] 使用最小權限 firewall rule，禁止以 `0.0.0.0/0` 解決未知連線問題。

本機階段使用 loopback、Compose network 與 NGINX local adapter；真正 VPC/VNet、router、firewall、CDN 與 F5 於 Cloud/企業網路環境再以 IaC 落地。

## 0L. ML Workflow Orchestration

不要同時安裝 Kubeflow、MLflow、Airflow。它們不是同一層：

| 工具 | 主要責任 | 何時導入 |
|---|---|---|
| MLflow | experiment tracking、model artifact、model registry、lineage | 第一個 ML workflow 就可導入 |
| Airflow | batch/scheduled DAG、資料流程與跨系統任務 | 有排程、批次與資料依賴時導入 |
| Kubeflow Pipelines | Kubernetes-native ML pipeline execution | 已有 Kubernetes 與多步驟 ML pipeline 時導入 |
| Kubernetes Jobs | 短期 containerized batch job | 需要 K8s execution，但尚未需要完整 Kubeflow 時 |

### 建議演進

```text
MLX / local experiment
  -> MLflow Tracking
  -> Model artifact + checksum
  -> Evaluation gate
  -> Model Registry alias: candidate
  -> Human approval
  -> Model alias: champion
  -> Inference deployment
```

- [ ] 每次 run 記錄 code SHA、dataset version、model base、parameters、metrics、hardware 與 output artifact。
- [ ] Model registry 使用 version、lineage、evaluation report、approval 與 rollback alias。
- [ ] Model artifact 不進 Git，不由 application image 隨意攜帶。
- [ ] Batch workflow 先由 GitLab CI 或 shell contract 驗證，再依需求導入 Airflow。
- [ ] Kubeflow 只有在 Kubernetes runtime、GPU scheduling、multi-user pipeline 與 lineage 需求成立後導入。

MLflow 的 Tracking 可記錄 parameters、metrics、code version 與 artifacts；Model Registry 可管理版本、lineage、alias 與部署前後的模型生命週期。[MLflow Tracking](https://mlflow.org/docs/latest/tracking) [MLflow Model Registry](https://mlflow.org/docs/latest/ml/model-registry/workflow)

Airflow 適合將任務以 DAG 表達，負責排程、依賴與跨系統 workflow；Kubeflow Pipelines 則直接將 pipeline component 執行成 Kubernetes workload。[Airflow architecture](https://airflow.apache.org/docs/apache-airflow/stable/core-concepts/overview.html) [Kubeflow Pipelines](https://www.kubeflow.org/docs/components/pipelines/concepts/pipeline/)

## 0M. LLMOps 整合模型

LLMOps 不是另起一套與 DevOps 平行的工具，而是將 LLM 特有的 artifact、evaluation、observability、safety 與 human approval 接入既有 CI/CD。

### LLMOps 控制面

```text
Prompt / Tool / Model Definition
  -> Git version control
  -> CI lint + policy + eval dataset
  -> Model/API/Prompt evaluation
  -> Security and privacy gate
  -> Registry / approved alias
  -> Develop deployment
  -> Trace / metrics / logs / feedback
  -> Human approval
  -> Production-like promotion
```

### 必須版本化的對象

- [ ] Model identifier、revision、quantization、runtime 與 hardware。
- [ ] System prompt、prompt template、tool schema 與 policy。
- [ ] Evaluation dataset、expected output、judge rubric 與 threshold。
- [ ] Retrieval index、embedding model、chunking 與 metadata schema。
- [ ] Guardrail、PII masking、content policy、rate limit 與 fallback。
- [ ] Model routing、provider endpoint 與成本上限。

### LLM CI/CD gate

- [ ] Prompt/schema lint。
- [ ] Secret scan 與 prompt data classification。
- [ ] Offline evaluation：correctness、format、refusal、safety、grounding。
- [ ] Regression comparison against current champion。
- [ ] Latency、token usage、error、timeout 與 cost baseline。
- [ ] Tool permission、prompt injection、data exfiltration 與 authorization test。
- [ ] Model/prompt change 只能 promotion，不直接覆蓋 production。

### LLM runtime observability

- [ ] request ID、model revision、prompt version、tool call、latency、tokens 與 error class。
- [ ] Prompt/response 內容預設不進一般 log，敏感內容需遮罩或獨立受控保存。
- [ ] Grafana 顯示 availability、p95 latency、tokens/sec、error rate、quota 與 cost estimate。
- [ ] Loki 保存結構化事件，不保存明文 secret 或不必要的完整 prompt。
- [ ] LLM unavailable 時有 fallback、queue、circuit breaker 與人工接管。
- [ ] LLM 只能操作獨立 service identity 授權的 Git 與 Secret Manager metadata/action API，不可讀取 secret value。

### 企業級原則

- [ ] Build once、evaluate once、promote immutable model/prompt bundle。
- [ ] Technical evaluation 與 human product acceptance 分離。
- [ ] Model registry alias 變更必須可審計、可回滾。
- [ ] 所有 LLM 自動操作留下 evidence，不得自動宣稱 Human Acceptance。
- [ ] 以 risk tier 決定人工核准：讀取/分析可自動化；寫入、外部副作用、不可逆動作需 approval。
- [ ] 供應商、模型、資料集、prompt、工具與輸出形成完整 lineage。

### 本專案的 LLMOps 導入順序

```text
現在：MLX endpoint + Git/CI/API/metrics/log review
  -> MLflow Tracking for model/runtime metadata
  -> Evaluation dataset and regression gate
  -> Prompt/tool policy repository
  -> LLM trace and cost dashboard
  -> Human approval and model alias promotion
  -> 需要時再導入 Airflow
  -> Kubernetes 成立後才評估 Kubeflow
```

每個站別的完成格式：

```text
Objective
Test Setup
Expected Result
Actual Result
Evidence
Failure Path
Rollback / Cleanup
Decision: PASS | FAIL | BLOCKED
```

## 1. 目標與成功條件

- [ ] 任一服務可以由 Git commit 建立可追溯的 container image。
- [ ] CI 能自動執行測試、程式碼掃描、依賴掃描與 image 弱掃。
- [ ] CD 能部署至 develop 與 production，兩者使用隔離的設定、Secret、網路與資料。
- [ ] Production 支援藍綠部署、健康檢查與自動或人工回滾。
- [ ] 對外服務具備 Public URL、HTTPS、WAF、負載平衡與網路分區。
- [ ] Secret、憑證與私鑰不進入 Git、image 或 pipeline log。
- [ ] 每次正式部署均有審計紀錄、版本、操作者與回滾方式。
- [ ] 具備 log、metrics、trace、告警與部署後驗證。

## 2. 建議落地路線

## 2A. 兩環境模型

本方案只保留兩個長期環境：`develop` 與 `production`。測試不另建長期環境，而是在 CI pipeline、短期 container 或 develop 中完成。

| 環境 | 目的 | 部署方式 | 資料與權限 |
|---|---|---|---|
| develop | 整合測試、DAST、驗收與部署演練 | Merge 後自動部署 | 測試資料、較寬鬆但受控的開發權限 |
| production | 正式服務 | Approval 後藍綠部署 | 真實資料、最小權限、獨立 Secret |

兩環境模型的風險與補強：

- [ ] develop 不得使用 production database 或 production Secret。
- [ ] CI 必須在合併前完成 unit、integration、SAST、SCA、image scan。
- [ ] develop 必須使用接近 production 的 Docker image、NGINX、TLS 與部署方式。
- [ ] production 必須保留 approval、audit log、smoke test 與 rollback。
- [ ] 若未來變更風險升高，再以短期驗收環境或 Kubernetes namespace 補足，不預先建立固定 staging。

### Phase 1：標準化單一服務

- [ ] 建立 Git repository 結構與分支策略。
- [ ] 建立各語言 Dockerfile 範本。
- [ ] 建立 `.dockerignore`、health endpoint 與非 root runtime。
- [ ] 建立 container registry 與 immutable image tag。
- [ ] 以 Git commit SHA 作為 image tag，不依賴 `latest`。

### Phase 2：導入 CI/CD

- [ ] CI：lint、unit test、integration test。
- [ ] CI：SAST、SCA、secret scan、IaC scan。
- [ ] CI：build image、container test、SBOM、image vulnerability scan。
- [ ] CD：自動部署 develop，production 需通過 approval gate。
- [ ] CD：production 使用 approval gate。
- [ ] CD：部署後執行 smoke test 與 health verification。

### Phase 3：正式網路與藍綠部署

- [ ] 建立 Public DNS、F5/WAF、DMZ、NGINX 與 application subnet。
- [ ] 建立 Blue/Green deployment contract。
- [ ] 確認流量切換、health check、timeout、retry 與 client IP 傳遞規則。
- [ ] 建立 rollback runbook。
- [ ] 驗證 database migration 的向前相容策略。

### Phase 4：企業資安與可觀測性

- [ ] 導入 Vault、Azure Key Vault、AWS Secrets Manager 或等效工具。
- [ ] 建立 TLS 憑證簽發、輪替與撤銷流程。
- [ ] 建立 DAST、網路弱掃與定期滲透測試流程。
- [ ] 建立集中式 log、metrics、trace 與告警。
- [ ] 建立 SBOM 保存、image signing 與供應鏈追蹤。

### Phase 5：平台化與擴展

- [ ] 服務數量或部署頻率達到門檻後評估 Kubernetes。
- [ ] 建立 Helm/Kustomize、Ingress、namespace、RBAC 與 NetworkPolicy。
- [ ] 導入 GitOps 與多環境配置管理。
- [ ] 建立內部 service template 與 golden path。

## 3. CI/CD 工具選型

CI/CD 確實有成熟的套裝工具，不需要自行從零開發 pipeline engine。應選擇一套主平台，再搭配掃描與部署工具。

| 類型 | 方案 | 適用情境 | 建議 |
|---|---|---|---|
| 全整合平台 | GitLab CI/CD | Git、Registry、Pipeline、Security 可集中管理 | 優先推薦 |
| Microsoft 生態 | Azure DevOps | Azure、企業 AD、Boards、Repos、Pipelines | 若企業已使用 Azure，優先考慮 |
| GitHub 生態 | GitHub Actions | GitHub repository、雲端服務、開源整合 | 團隊已使用 GitHub 時適合 |
| Jenkins | Jenkins | 既有企業環境、複雜客製流程 | 不建議新專案從零開始，維運成本較高 |
| 企業平台 | Red Hat OpenShift Pipelines | OpenShift 與 Kubernetes 企業平台 | 已採用 OpenShift 時使用 |
| 部署控制 | Argo CD | Kubernetes GitOps | 導入 Kubernetes 後使用 |
| 發布控制 | Argo Rollouts | Kubernetes 藍綠、Canary、漸進式發布 | Kubernetes 階段使用 |

### 建議的第一套組合

若尚未被既有企業平台綁定，建議採用：

```text
GitLab
├─ Git Repository
├─ GitLab CI/CD
├─ GitLab Container Registry
├─ GitLab Secret / Environment Protection
└─ Runner

搭配
├─ Trivy：container 與 filesystem 弱掃
├─ Semgrep 或 SonarQube：SAST / code quality
├─ Gitleaks：secret scan
├─ Syft：SBOM
├─ Cosign：image signing
├─ Docker Compose：初期部署
└─ NGINX + F5：入口與流量切換
```

這是「套裝平台加專用工具」的組合。GitLab 負責流程編排，Trivy 等工具負責特定安全檢查，Docker Compose 或 Kubernetes 負責執行環境。

## 4. CI Pipeline 標準

```text
Merge Request
  -> Lint / Format
  -> Unit Test
  -> Integration Test
  -> SAST / SCA / Secret Scan
  -> Docker Build
  -> Container Test
  -> Image Scan
  -> SBOM
  -> Sign Image
  -> Push Immutable Image
```

品質門檻：

- [ ] Critical vulnerability：禁止建立 release。
- [ ] High vulnerability：需修補或有正式風險接受紀錄。
- [ ] 測試失敗：禁止合併。
- [ ] Secret scan 命中：立即阻擋並撤銷該 secret。
- [ ] Image 必須以 digest 或不可變 tag 部署。

## 5. CD Pipeline 與藍綠部署

```text
Approved Image
  -> Deploy Green
  -> Readiness Check
  -> Smoke Test
  -> DAST / API Verification
  -> Approval Gate
  -> F5/NGINX Traffic Switch
  -> Observe
  -> Retain Blue for Rollback
```

### 藍綠部署要求

- [ ] Blue 與 Green 使用相同設定契約。
- [ ] Green 在切流前不可接收正式流量。
- [ ] 切流前驗證 health、API、資料庫連線與關鍵業務流程。
- [ ] 切流後監測錯誤率、延遲、5xx、資源用量與業務指標。
- [ ] 回滾只需將 upstream 或 service selector 切回 Blue。
- [ ] Blue 保留至觀察窗口結束，不能切流後立即刪除。

### Database migration

採用 expand-and-contract：

```text
新增結構 -> 部署相容程式 -> 回填資料 -> 切換讀寫 -> 移除舊結構
```

禁止在藍綠切換前直接刪除舊欄位或改變既有欄位語意。

## 6. 執行環境演進

### 初期：VM + Docker Compose

適合單一或少量服務。組件為 Linux VM、Docker Engine、Compose、NGINX、F5。

### 中期：多 VM 或集中式容器平台

適合多個服務但尚未需要 Kubernetes 的組織。先標準化 image、pipeline、部署與監控。

### 後期：Kubernetes

當服務數量、部署頻率、可用性或自動擴縮需求超過 Compose 管理能力，再導入 AKS、EKS、GKE、OpenShift 或自建 Kubernetes。

Kubernetes 階段新增：

- [ ] Helm 或 Kustomize。
- [ ] Ingress 與 NetworkPolicy。
- [ ] Namespace 與 RBAC。
- [ ] Argo CD GitOps。
- [ ] Argo Rollouts 藍綠或 Canary。
- [ ] Pod security、resource quota 與 autoscaling。

## 7. 企業網路與對外服務

```text
Internet
  -> Public DNS / CDN
  -> F5 / WAF
  -> DMZ / NGINX
  -> Application Subnet
  -> Database / Cache / Queue Subnet
```

- [ ] Public IP 只配置於必要入口。
- [ ] Application 不直接暴露 public IP。
- [ ] VNet/VPC 分為 public、DMZ、application、data、management subnet。
- [ ] 使用 security group、firewall 與 Network ACL 限制 east-west traffic。
- [ ] 明確定義 F5 與 NGINX 的 TLS termination、health check、timeout、retry 與 real client IP 責任。
- [ ] 對外 URL、內部 DNS 與服務名稱分離管理。

## 8. 資安基線

### P0：目前 MLX 設定檔的 Secret remediation

目前啟動鏈會 source `/Users/drew/ENV/mlx_llm_server.env` 與 `/Users/drew/.env`。設定檔內容不可進 Git、image、pipeline artifact、螢幕截圖或一般 log。若其中任何 token 曾被暴露或共享，必須視為已洩漏並立即撤銷、輪替。

- [ ] 從可版本控制與可共享的設定檔移除所有明文 token。
- [ ] 將 token 移入 Vault Community 或其他受控 Secret Manager。
- [ ] 以短期 credential、AppRole、OIDC 或受限 service identity 取代長期 token。
- [ ] 為每個 provider 分別輪替 credential，不能只更換檔名或重新包裝同一組 token。
- [ ] 建立 secret scan，檢查 Git history、working tree、CI log 與 artifact。
- [ ] 對 Secret Manager 設定 audit log、rotation、backup、restore 與最小權限。
- [ ] 服務啟動時只注入必要 secret，禁止整份 `.env` 傳入所有 container。

### Container 與供應鏈

- [ ] 使用可信任且固定版本的 ARM-compatible base image。
- [ ] Multi-stage build，runtime image 不含 compiler 與測試工具。
- [ ] 使用非 root 使用者。
- [ ] Image scan、SBOM、image signing 與 registry audit。
- [ ] 定期重建 image 以吸收 OS security patch。

### HTTPS 與密鑰

- [ ] 使用 TLS 1.2 以上，優先 TLS 1.3。
- [ ] 私鑰與 secret 不進 Git、Dockerfile、image 或 pipeline log。
- [ ] 使用 Vault、Key Vault 或雲端 Secret Manager。
- [ ] 實施最小權限、rotation、access audit 與環境隔離。
- [ ] 建立憑證到期告警與自動更新。

### 弱掃與測試

- [ ] SAST：原始碼。
- [ ] SCA：第三方套件。
- [ ] Secret scan：Git 與 pipeline。
- [ ] IaC scan：Terraform、Dockerfile、Kubernetes YAML。
- [ ] Container scan：image OS 與套件。
- [ ] DAST：develop 的實際 HTTP/API 服務，production 以低風險驗證與監控為主。
- [ ] Network scan：主機、網段與暴露服務。
- [ ] 定期滲透測試與重大版本前安全驗收。

## 9. 可觀測性與驗收

- [ ] Log 輸出 stdout/stderr，集中收集並保留 correlation ID。
- [ ] Metrics 至少包含 request count、error rate、latency、CPU、memory、restart。
- [ ] Trace 追蹤跨服務請求。
- [ ] Deployment dashboard 顯示版本、image digest、操作者與結果。
- [ ] 藍綠切換前後保存 smoke test 與監控證據。
- [ ] 發生錯誤時可由告警連到 rollback runbook。

## 10. 第一個 PoC 的範圍

先使用一個非關鍵服務驗證完整鏈路：

- [ ] GitLab repository。
- [ ] 一個 Python 或 Node.js API。
- [ ] Dockerfile、health endpoint、Compose deployment。
- [ ] GitLab CI：test、Trivy、Gitleaks、SBOM。
- [ ] Develop、Production 兩環境。
- [ ] NGINX reverse proxy。
- [ ] Blue/Green container。
- [ ] HTTPS certificate。
- [ ] 部署後 smoke test 與 rollback。
- [ ] 完成一份部署、回滾與事故處理 Runbook。

## 11. 決策門檻

正式選型前需要確認：

- Git 平台：GitLab、GitHub 或 Azure DevOps。
- 雲端或地端：Azure、AWS、GCP、院內資料中心或混合雲。
- 是否已有 F5、WAF、AD、Registry、SIEM、監控平台。
- 預計服務數量與每週部署頻率。
- 是否需要 Kubernetes 的高可用、自動擴縮與多租戶能力。
- 弱掃與稽核是否有既定企業工具或法規要求。

## 12. 最終建議

第一階段採用：

```text
GitLab CI/CD
+ GitLab Container Registry
+ Docker Compose
+ NGINX
+ 現有 F5/WAF
+ Trivy / Gitleaks / Syft / Cosign
+ Vault 或雲端 Secret Manager
```

待服務數量與部署治理需求明確後，再升級為：

```text
Kubernetes
+ Helm/Kustomize
+ Argo CD
+ Argo Rollouts
+ Ingress
+ NetworkPolicy
+ Centralized Observability
```

這樣可以先完成可運作的企業交付鏈，再以實際需求決定是否導入 Kubernetes，避免平台複雜度先於業務需求成長。

## 12A. 第一個 PoC：MLX Local Endpoint Model

第一個整合對象不是要被本平台部署的 MLX application，而是由 `/Users/drew/ENV/activate_mlx_llm.sh` 在 Apple Silicon host 啟動的 LLM user endpoint。平台應將它視為「人類使用者的等效消費者」：它會呼叫應用服務、觸發流程並產生請求，但不屬於 application deployment target。

目前已確認的 runtime facts：

- [ ] Python runtime：`/Users/drew/ENV/localLLM/bin/python`。
- [ ] 啟動方式：`python -m mlx_lm server`。
- [ ] 模型由 `MODEL_PATH` 指定，並非 Docker image 內建 artifact。
- [ ] 目前 bind address：`127.0.0.1`。
- [ ] 目前 endpoint port：`9000`。
- [ ] 目前設定包含 offline model loading，model cache 與 checksum 必須另行治理。

因此第一版架構應為：

```text
MLX LLM User Endpoint
  -> 127.0.0.1:9000
  -> Application / DevOps Service
  -> Database / External Service
```

`127.0.0.1:9000` 是 intentional local-only boundary，不應被轉成 Public URL，也不應預設接入 F5、WAF 或 production ingress。若 Dockerized application 需要呼叫它，才另外建立受控 adapter 或 host bridge；不能反過來要求 LLM endpoint 遵守一般 production application 的部署模型。

### 模型服務契約

- [ ] 提供 `/health/live`：程序仍在執行。
- [ ] 提供 `/health/ready`：模型已載入且可以接受推論。
- [ ] 提供 `/version`：回傳 application version、model identifier、model revision、image digest。
- [ ] 提供 OpenAPI 或等效 API schema。
- [ ] 每個 request 產生 correlation ID。
- [ ] Log 使用 structured JSON，不記錄 prompt、response、token 或敏感資料原文。
- [ ] 定義 request timeout、max input length、max output tokens 與 concurrency limit。
- [ ] 定義 model loading、out-of-memory、timeout、queue full 的錯誤碼。
- [ ] 使用 graceful shutdown，避免部署切換時遺失正在處理的 request。

### MLX 與 Apple Silicon 要求

- [ ] 使用 ARM-native image、Python runtime 與 MLX 套件，避免不必要的 x86 emulation。
- [ ] 明確記錄 MLX、Python、macOS/Linux、Metal 與 model format 版本。
- [ ] 模型權重不提交 Git、不打包進公開 image，改由受控 artifact 或 model storage 取得。
- [ ] 模型下載、cache、checksum 與來源必須可追蹤。
- [ ] 建立 cold start、warm start、tokens/sec、p50/p95 latency、peak memory 指標。
- [ ] 服務不可因 model loading 尚未完成而被標記為 ready。
- [ ] 定義單機 GPU/統一記憶體容量、最大模型大小與併發上限。
- [ ] 以 launchd 或等效 process supervisor 管理啟動、停止、重啟、log 與 exit code。
- [ ] 保持 endpoint bind 在 `127.0.0.1`，除非有明確的跨主機需求與網路安全設計。
- [ ] Application 呼叫 LLM 時，定義 prompt、response、timeout、retry、rate limit 與錯誤處理契約。
- [ ] 將 LLM 視為不穩定的外部依賴，建立 fallback、circuit breaker 與不可用時的降級行為。
- [ ] 不將 LLM endpoint 納入 application image、F5 upstream、public DNS 或 production blue/green target。
- [ ] 後續若要跨主機或容器化，必須另立 architecture decision record，不得直接修改 bind address。
- [ ] MLX inference runtime 暫時保留在 host service，不強行放入 Docker。

### 推論資料安全

- [ ] Develop 使用合成或去識別化資料。
- [ ] Prompt、response、模型輸出與 access token 不進一般 application log。
- [ ] API authentication、authorization、rate limit 與 request size limit 必須在 NGINX/F5 與 application 雙層驗證。
- [ ] 明確定義資料是否允許保留、是否允許進入 trace，以及 retention period。

## 12F. LLM Automation Delegation Contract

`127.0.0.1:9000` 代表一個受人類授權的自動化操作者。它的目的不是取代人類進行 PRD、產品體驗或最終驗收，而是在以下情境代替人類執行可驗證、可重複、低風險的工作：

- 人類暫時不在線時的例行檢查。
- Batch 任務的狀態確認與結果整理。
- Code、CI/CD、Git diff 與設定變更檢查。
- API test、contract test、smoke test 與 regression test。
- 效能、log、metrics、trace、錯誤率與資源用量監看。
- 產生報告、標記風險、建立 issue 或提出變更建議。

### LLM 可自動執行

- [ ] 讀取明確授權的 repository、diff、pipeline log、test report 與監控資料。
- [ ] 執行既定的 lint、test、security scan、API test 與 performance check。
- [ ] 依固定規則比對預期結果，標記 SUCCESS、FAIL 或 NOT_FOUND。
- [ ] 產生結構化報告，包含 commit SHA、image digest、測試版本、時間與證據連結。
- [ ] 建立 issue、comment、通知或待辦事項，但不得偽造人工核准。
- [ ] 執行可逆、低風險的重試、重新掃描或收集診斷資料。

### 必須由人類處理

- [ ] PRD 定義與需求取捨。
- [ ] 最終產品效果、實際使用體驗與業務驗收。
- [ ] 是否符合使用者真正需求的判斷。
- [ ] Production release approval。
- [ ] 不可逆資料變更、刪除、權限擴張或對外發布。
- [ ] Security risk acceptance、法規例外與重大 incident decision。
- [ ] LLM 產出的建議是否採用。

### 權限與交接

- [ ] LLM 使用獨立 service identity，不冒充人類帳號。
- [ ] 每個自動化任務限制 repository、branch、environment、tool 與 network scope。
- [ ] LLM 可以操作 Git，包括讀取 diff、建立 branch、commit、建立 Merge Request 與更新非 protected branch。
- [ ] LLM 可以操作 Secret Manager 的 metadata、policy、rotation workflow、reference 與狀態檢查。
- [ ] LLM 不得讀取、輸出、回顯、複製或寫入報告的 Secret value。
- [ ] Secret rotation 使用 Secret Manager 原生 rotation、外部 rotator 或人工核准流程，不讓明文 secret 經過 LLM prompt 或 log。
- [ ] LLM 不得自行修改 protected branch、核准自己的 merge request 或批准 production release。
- [ ] 所有結果標示為 `LLM-generated evidence`，不得標示為 `Human Acceptance`。
- [ ] 失敗、模糊或證據不足時必須回報 `BLOCKED` 或 `NEEDS_HUMAN_REVIEW`。
- [ ] 每次任務保存 prompt/task definition、commit、工具輸出、判斷與時間戳。
- [ ] 人類可從報告重新執行檢查、查看原始證據並覆寫或否決 LLM 建議。

### Git 與 Secret 操作矩陣

| 操作 | LLM | 人類核准 |
|---|---:|---:|
| 讀取 Git diff、log、非敏感設定 | 允許 | 不需要 |
| 建立 feature branch、commit、Merge Request | 允許 | Merge 前需要 review |
| 修改 protected branch | 禁止 | 允許 |
| 讀取 Secret metadata、expiry、rotation status | 允許 | 不需要 |
| 讀取 Secret value | 禁止 | 依企業政策限制 |
| 觸發既定 Secret rotation workflow | 允許 | 高風險環境需要核准 |
| 任意設定或覆寫 Secret value | 禁止 | 由受控 rotator 或人類執行 |
| 修改 production Secret policy | 禁止 | Security/Platform owner 核准 |

### 驗收邊界

LLM 的成功只代表「自動化檢查完成並產生證據」，不代表產品成功。正式完成條件必須拆成：

```text
LLM：Technical Verification Passed
  -> Human：PRD / Product / UX Acceptance
  -> Human：Production Release Approval
```

## 12B. 服務標準契約

所有非 MLX 服務也必須遵守相同平台契約：

- [ ] `/health/live`、`/health/ready`、`/metrics`、`/version`。
- [ ] OpenAPI 或其他可機器驗證的 API schema。
- [ ] Structured log、correlation ID 與 trace context。
- [ ] Graceful shutdown、timeout、retry、idempotency 與 error mapping。
- [ ] Docker image 使用非 root、固定 digest、resource limit 與 container health check。
- [ ] API、database、cache、queue 與外部服務的連線設定均可由環境配置注入。

## 12C. 版本與分支策略

```text
main
  -> production release source

develop
  -> develop environment source

feature/*
  -> Merge Request only

hotfix/*
  -> emergency production fix, followed by back-merge to develop
```

- [ ] 使用 Conventional Commits。
- [ ] 使用 Semantic Versioning 或明確的 release numbering。
- [ ] Image tag 至少包含 Git SHA，release image 另加受控版本 tag。
- [ ] Production 只能由 protected branch、release tag 或受控 promotion 觸發。
- [ ] Hotfix 必須回併 develop，避免環境分支漂移。
- [ ] Rollback 以 image digest 為準，不以重新 build 取代舊版。
- [ ] Release note 包含 API、model、database、configuration 與 security 變更。

## 12D. 容量、效能與成本管理

- [ ] 每個服務定義 CPU、memory、storage request/limit。
- [ ] MLX 定義 unified memory 上限、模型 cache 大小與最大併發。
- [ ] 記錄 request rate、queue depth、latency、error rate、tokens/sec 與 OOM 次數。
- [ ] 設定 log、image、model artifact、metrics 與 trace retention。
- [ ] Develop 可設定閒置停止、低資源模式或排程啟動。
- [ ] Production 依 SLO、尖峰流量與模型推論成本進行 capacity planning。
- [ ] 進行 baseline、load、stress、soak 與 recovery test。
- [ ] 所有性能結論都必須標示硬體、模型、量化格式、輸入長度與併發條件。

## 12E. Runbook 與演練

必須建立並實際演練：

- [ ] Develop 部署 Runbook。
- [ ] Production Blue/Green 與 rollback Runbook。
- [ ] MLX model download、cache、load failure 與 OOM Runbook。
- [ ] Model version rollback Runbook。
- [ ] Vault secret rotation 與 restore Runbook。
- [ ] TLS certificate renewal Runbook。
- [ ] Database backup、restore 與 migration rollback Runbook。
- [ ] F5/NGINX routing、health check 與 upstream failure Runbook。
- [ ] Registry、CI/CD、model storage unavailable Runbook。
- [ ] Security incident、資料誤記錄與 access token 外洩 Runbook。

演練紀錄必須包含：時間、操作者、前置條件、預期結果、實際結果、恢復時間、問題與改善項目。

## 13. 企業級兩環境原則

本文件雖然只定義 `develop` 與 `production`，但兩個環境均依企業級標準設計。環境數量少，不代表可以省略治理、稽核、資安與可用性控制。

### 13.0 Secret Manager 選擇

本方案採用「Key Vault 相容的抽象層」：應用程式與 pipeline 只依賴 secret path、identity 與 policy，不直接綁定特定廠商 API。

| 情境 | 實作 | 說明 |
|---|---|---|
| 不使用 Cloud、地端或本機 PoC | HashiCorp Vault Community | 可自架，提供 secret、policy、token、audit 與 rotation 基礎能力 |
| Azure Cloud | Azure Key Vault | Managed service，整合 Azure identity 與平台權限 |
| 混合環境 | Vault Community + Azure Key Vault | 透過統一 secret interface，依環境選擇 backend |

注意：Azure Key Vault 是 Azure 服務，不能直接安裝成一般地端軟體。若不使用 Cloud，Plan 中的「Key Vault」實作應指 HashiCorp Vault Community，而不是假設 Azure Key Vault 可離線執行。

- [ ] develop 與 production 使用不同 Vault mount、namespace 或 policy。
- [ ] CI/CD 使用短期 token、OIDC 或 AppRole，不在 repository 保存長期 root token。
- [ ] Secret 取用需要 identity、policy、audit log 與最小權限。
- [ ] Vault storage 加密、backup、unseal 與 restore 流程納入維運文件。
- [ ] Secret rotation 與憑證輪替必須先在 develop 演練，再套用 production。
- [ ] Application config、Secret reference 與 Secret value 分離保存。

### 13.1 Artifact promotion

- [ ] Image 只建置一次，不在 production 重新 build。
- [ ] develop 驗證通過後，promotion 同一個 image digest 至 production。
- [ ] Production 部署紀錄包含 commit SHA、image digest、SBOM、簽章與核准者。
- [ ] Registry 分隔 develop 與 production repository 或 namespace。
- [ ] Production registry 只允許受控 pipeline 讀取。
- [ ] 禁止使用 `latest`、人工重新打 tag 或直接在主機上 build image。

### 13.2 企業身分與權限

- [ ] 整合企業 IdP，例如 Microsoft Entra ID、Okta、Keycloak 或 LDAP。
- [ ] CI/CD 使用短期 token、OIDC 或 workload identity，不保存長期雲端金鑰。
- [ ] 開發者、Reviewer、Release Manager、平台管理者、Security Auditor 分離職責。
- [ ] Production deploy 採用 least privilege 與 separation of duties。
- [ ] 使用 RBAC、MFA、PAM/JIT privilege 與定期 access review。
- [ ] 所有管理與部署動作保留 audit log 並送入 SIEM。

### 13.3 Pipeline governance

- [ ] 共用 pipeline template 集中維護，服務 repository 不可任意繞過安全 stage。
- [ ] 使用 GitLab CI component、GitHub reusable workflow、Azure template 或 Jenkins shared library。
- [ ] Pipeline runner 使用隔離、短生命週期、不可保存敏感資料的執行器。
- [ ] Runner 依 develop、production、security job 分池並限制網路權限。
- [ ] Pipeline 定義需要 code review，禁止 production pipeline 由單人修改後立即生效。
- [ ] Pipeline 失敗、跳過安全檢查或人工 override 必須留下原因與核准紀錄。

## 14. 企業級工具分類

工具可替換，但每個控制目的都必須存在。

| 控制領域 | 常見工具 | 必須產出的證據 |
|---|---|---|
| Source control | GitLab、GitHub Enterprise、Azure Repos | commit、MR/PR、review、branch protection |
| CI/CD | GitLab CI、GitHub Actions、Azure Pipelines、Jenkins | pipeline log、artifact、approval |
| Registry | Harbor、GitLab Registry、ECR、ACR、GAR | image digest、retention、access log |
| Artifact | Nexus、JFrog Artifactory、GitLab Package Registry | package version、promotion history |
| SAST | Semgrep、SonarQube、Checkmarx、Fortify | code scan report、quality gate |
| SCA | Snyk、Mend、OWASP Dependency-Check、GitLab Dependency Scanning | dependency inventory、CVE status |
| Secret scan | Gitleaks、GitLab Secret Detection、TruffleHog | finding、revocation、處理紀錄 |
| Container scan | Trivy、Grype、Prisma Cloud、Aqua | image vulnerability report |
| SBOM | Syft、CycloneDX、SPDX | SBOM、版本與保存期限 |
| Image signing | Cosign、Notary v2、Harbor signing | signature、verification result |
| IaC | Terraform、OpenTofu、Ansible、Pulumi | plan、approval、state history |
| IaC security | Checkov、tfsec、Terrascan、KICS | policy result、exception record |
| Secrets | HashiCorp Vault Community；Azure 環境可替換為 Azure Key Vault | access log、rotation record |
| Network/WAF | F5、NGINX、FortiWeb、Cloud WAF | rule version、TLS、traffic log |
| Observability | Prometheus、Grafana、Loki、ELK、OpenTelemetry、Jaeger | metrics、log、trace、alert |
| SIEM | Microsoft Sentinel、Splunk、Elastic Security、QRadar | security event、correlation、retention |
| ITSM | ServiceNow、Jira Service Management、BMC | change、incident、approval、RCA |
| Quality test | Postman/Newman、JMeter、k6、Playwright、Selenium | API、load、E2E test result |
| Policy | OPA、Conftest、Kyverno、Gatekeeper | policy decision、exception |

企業不一定要全部採用，但每一列的控制目的都需要有明確 owner、工具與保存證據。

## 15. Infrastructure as Code 與配置管理

- [ ] VNet/VPC、subnet、route、firewall、F5、DNS 與 VM/container host 以 IaC 管理。
- [ ] Terraform 或 OpenTofu state 使用遠端、加密、鎖定與版本保留。
- [ ] IaC 變更必須經 plan、review、approval，再 apply。
- [ ] Develop 與 production 使用相同 module，不同 variable 與 state。
- [ ] Application config 與 Secret 分離；Secret 只引用外部管理服務。
- [ ] 使用 Ansible、Packer 或 image factory 建立一致的 host baseline。
- [ ] 設定 CIS benchmark、OS patch、時間同步、auditd 與 endpoint protection。

## 16. 企業測試金字塔

CI 不只驗證程式能否啟動，還要驗證服務交握與部署邊界。

- [ ] Unit test：函式與模組邏輯。
- [ ] Contract test：服務間 API schema、header、錯誤碼與版本相容性。
- [ ] Integration test：database、cache、queue、外部 API。
- [ ] Container test：image 啟動、權限、health check、signal handling。
- [ ] E2E test：關鍵使用者流程。
- [ ] DAST：HTTP、API、authentication、authorization 與輸入驗證。
- [ ] Performance test：latency、throughput、connection pool、資源上限。
- [ ] Resilience test：timeout、retry、circuit breaker、dependency failure。
- [ ] Deployment test：Blue/Green 切換、回滾、migration 與舊版相容性。

## 17. 交握介面防禦審查

每次 release 必須檢查跨層級交握，不只檢查單一服務：

```text
Client
  -> DNS
  -> F5 / WAF
  -> NGINX
  -> Container / Service
  -> Database / Queue / External API
```

- [ ] DNS、TLS SNI、Host header 與 certificate chain 一致。
- [ ] F5 傳遞 `X-Forwarded-For`、request ID 與 client protocol 正確。
- [ ] NGINX upstream timeout、retry、buffer 與 body size 符合 API 行為。
- [ ] Application readiness 不等於 dependency readiness，兩者分開處理。
- [ ] Database migration 與舊版 Blue instance 相容。
- [ ] Queue message schema 支援版本化與重複投遞。
- [ ] Timeout、retry、idempotency、circuit breaker 有明確規則。
- [ ] 每一個失敗路徑都有 log、metric、trace 與可操作的告警。

## 18. SRE、可用性與災難復原

- [ ] 為服務定義 SLA、SLO 與 SLI，例如 availability、p95 latency、error rate。
- [ ] 設定 error budget，超過門檻時暫停高風險變更。
- [ ] 建立 RTO、RPO、backup、restore 與 failover 需求。
- [ ] Database backup 加密、跨區或離線保存，並定期執行 restore test。
- [ ] 建立 F5、DNS、Registry、Secret Manager、CI/CD 故障替代程序。
- [ ] 建立 incident severity、on-call、escalation 與 communication matrix。
- [ ] 每次重大事件完成 RCA、corrective action 與追蹤期限。

## 19. ITSM 與正式上線流程

正式部署至少需要以下紀錄：

- [ ] Change request：目的、範圍、風險、窗口與回滾計畫。
- [ ] Release note：版本、變更項目、相容性與已知問題。
- [ ] Security evidence：弱掃、SBOM、dependency status 與例外核准。
- [ ] Approval：開發、測試、系統 owner 與 production release owner。
- [ ] Deployment evidence：image digest、時間、操作者、結果與監控截圖或連結。
- [ ] Post-deployment review：錯誤率、延遲、業務指標與 rollback decision。

## 20. 兩環境企業級驗收清單

### Develop

- [ ] 每次 merge 自動建置並執行完整 CI gate。
- [ ] 使用與 production 相同的 image build、NGINX、TLS 與部署方式。
- [ ] 可執行 API、E2E、DAST、效能與故障情境測試。
- [ ] 使用去識別化或合成資料。
- [ ] 可以演練藍綠部署與 rollback。

### Production

- [ ] 只能由受控 CD pipeline 部署。
- [ ] 使用 develop 已驗證的同一個 image digest。
- [ ] 需要 approval、change record 與完整 audit trail。
- [ ] 具備 F5/NGINX 藍綠切換、health check 與 rollback。
- [ ] 具備 24x7 或約定時段監控、告警與事故升級路徑。
- [ ] 完成 backup、restore、憑證輪替與 Secret rotation 演練。

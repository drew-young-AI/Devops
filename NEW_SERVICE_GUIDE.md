# 新服務接入 DevOps 指引

本文件用於下次建立新的 Python、Node.js、Java、Go、.NET 或其他 HTTP 服務時，將服務接入現有 DevOps 平台。

## 1. 先決定服務類型

先回答：

- 服務名稱與用途是什麼。
- 是 POC、Pilot、develop service，還是正式產品候選。
- 是否需要 database、cache、queue 或外部 API。
- 是否需要 Secret。
- 是否需要 CPU、GPU、特殊硬體或 persistent storage。
- 是否需要對外 Public URL。
- 是否需要由 MLX LLM 執行自動化檢查。

若只是驗證 DevOps，放在：

```text
pilots/<service-name>/
```

不要直接放入 `platform/`。

## 2. 建立最小服務契約

每個 HTTP service 至少提供：

```text
GET /health/live
GET /health/ready
GET /metrics
GET /version
```

並遵守：

- stdout/stderr structured log
- correlation ID
- graceful shutdown
- timeout 與錯誤碼
- 不在 log 輸出 Secret 或敏感 payload
- 可由 environment configuration 注入設定
- 不依賴本機絕對路徑

## 3. 建立必要檔案

```text
pilots/<service-name>/
├── README.md
├── Dockerfile
├── compose.yaml
├── .dockerignore
├── src/ 或 app/
├── tests/
└── config.example.env
```

不要提交：

- `.env`
- Secret value
- private key
- model token
- production configuration
- 大型 model weights
- runtime cache

## 4. Docker 要求

- [ ] 使用 multi-stage build，或明確說明為何不需要。
- [ ] 固定 base image 版本或 digest。
- [ ] 使用 ARM-compatible image。
- [ ] 使用非 root user。
- [ ] 加入 container healthcheck。
- [ ] 設定 CPU、memory、PID、storage 與 log limits。
- [ ] root filesystem 儘量 read-only。
- [ ] `cap_drop: ALL` 與 `no-new-privileges`。
- [ ] image tag 包含 Git SHA。

## 5. 測試要求

至少提供：

- unit test
- contract test
- health endpoint test
- container startup test
- smoke test
- graceful shutdown test

若服務需要外部依賴，再增加：

- integration test
- API test
- migration test
- failure and timeout test
- performance baseline

## 6. 接入 local CI

執行：

```sh
/Users/drew/ENV/Devops/platform/ci/run_local_ci.sh \
  /Users/drew/ENV/Devops/pilots/<service-name>
```

CI 預期流程：

```text
compile / lint
  -> unit / contract test
  -> container build
  -> image metadata
```

失敗時不得產生可 promotion 的 artifact。

## 7. 接入 develop

- [ ] 建立 develop-specific configuration。
- [ ] 使用測試或去識別化資料。
- [ ] Secret 只保存 Secret Manager reference。
- [ ] 由 Compose 或平台 deployment adapter 啟動。
- [ ] 通過 health、smoke、API 與 security gate。
- [ ] 加入 Prometheus scrape target。
- [ ] 確認 Grafana dashboard 與 Loki log 可查詢。

## 8. Production-like promotion

必須使用 develop 已驗證的同一個 image digest：

```text
Build once
  -> Test in develop
  -> LLM review (advisory evidence)
  -> Human review
  -> Promote same digest
  -> Blue/Green production-like
  -> Smoke test
  -> Human release decision
```

LLM 可以執行測試、diff review、scan、報告與低風險診斷，但不能代替人類進行 PRD、產品體驗或 production release approval。

上面流程中的 `LLM review` 由 `platform/llm-review/review.sh` 產出，只是餵給人類的 evidence：它的 verdict 不影響 exit code，`deploy.sh promote` 顯示它之後仍然要求真人輸入 `PROMOTE`。它讓人類的決策更有依據，不代替人類決策。詳見 `platform/llm-review/README.md`。

## 9. 未來 Kubernetes 搬遷檢查

服務可以搬遷 Kubernetes 的前提：

- [ ] 不依賴 `host.docker.internal`。
- [ ] 不依賴 Docker socket。
- [ ] 不依賴本機絕對路徑。
- [ ] 設定、Secret、volume 與 service discovery 已抽象化。
- [ ] healthcheck 可轉成 probes。
- [ ] CPU/memory 可轉成 requests/limits。
- [ ] log 只輸出 stdout/stderr。
- [ ] state 有外部 storage contract。

## 10. 完成時提交的證據

```text
Objective
Test Setup
Expected Result
Actual Result
Test Reports
Image Digest
Security Reports
Dashboard / Log Links
Failure Path
Rollback / Cleanup
Decision: PASS | FAIL | BLOCKED
```

## 11. 請 LLM 協助時的輸入格式

下次可以直接提供：

```text
請依 /Users/drew/ENV/Devops/NEW_SERVICE_GUIDE.md
建立一個 <service-name> 的 <language/framework> Pilot。

用途：<description>
依賴：<none/database/cache/queue/external-api>
是否需要 Secret：<yes/no>
是否需要 GPU 或特殊硬體：<yes/no>
是否對外提供 URL：<yes/no>
```

LLM 應先檢查範圍、資料與權限，再建立 Pilot，不應直接修改 platform contract。

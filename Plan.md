# Enterprise DevOps Miniature Plan

## 0.1 Handoff / Current Status

> 本節是跨視窗交接紀錄。新執行緒應先讀本節、`README.md` 與 `docs/`，再採取任何動作。
>
> **給主管／需要決定擴充或收斂的人**：先看 `docs/System-State.html`——十類機制的
> 現況盤點、逐項驗證狀態、以及「值得擴充／建議收斂」兩份依代價排序的清單。
> 分類依據 DORA 能力模型與 CNCF 平台工程成熟度模型，非自訂。

### 已完成

- [x] 建立 DevOps 與 Pilot 的目錄邊界。
- [x] Station 1：Hello World container、health、non-root、resource limit、graceful shutdown。
- [x] Station 2：local CI，包含 compile、unit/contract test、container build、image metadata。
- [x] Local observability：Grafana、Prometheus、Loki、Alloy。
- [x] Prometheus 已抓取 Station 1 `/metrics`。
- [x] Loki 已收集 Station 1 Docker logs。
- [x] Grafana 已建立 DevOps Overview dashboard。
- [x] 已建立新服務接入文件 `NEW_SERVICE_GUIDE.md`。
- [x] 已將 Plan 拆分為 Architecture、IaC、Network、Security、Observability、Pilot Validation、Future MLOps/LLMOps 與 Future DataOps 文件。
- [x] GitHub source of truth：https://github.com/drew-young-AI/Devops（public repo，PAT-based push，無 secret 提交）。
- [x] Git-triggered CI：`.github/workflows/iac-validate.yml`（push 觸發，fmt → validate → Checkov → plan → tfsec → evidence），已驗證綠燈。
- [x] OpenTofu IaC skeleton：`platform/iac/`，provider-neutral contract（AWS/GCP/Azure adapter 以註解預留，不 apply）、30+ 已驗證變數、Checkov + OPA/Conftest policy。State governance 僅文件化契約（local state 為 Phase 1 預設，尚未接 MinIO/cloud backend）。
- [x] Local HTTPS + NGINX adapter：`platform/nginx/`，mkcert TLS、反向代理到 station1-hello、rate limit、security headers、correlation ID、結構化 JSON log。端到端驗證見 `platform/nginx/README.md`「Verified End-to-End」，含 Loki 實際查詢結果。
- [x] Develop Compose deployment adapter：`platform/compose/deploy.sh`（build/deploy/status/teardown），獨立 Compose project + network、環境專屬 env file 注入、build 與 deploy 分離（deploy 絕不重build）。
- [x] Production-like blue/green + rollback：`deploy.sh promote|rollback`。Develop-validation gate（拒絕未在 develop 驗證過的 image）、blue/green 雙色（port 18081/18082）、NGINX 流量切換（`nginx -s reload`）、真人互動確認（`read -p` 輸入 `PROMOTE`/`ROLLBACK`，無 `--yes` 旁路）。端到端驗證見 `platform/compose/README.md`「Verified End-to-End」，含用 NGINX access log 的 `upstream_addr` 欄位證明流量真的切換（非只改了 state 檔案）、以及測試過程中發現並修正一個 exit code 誤報 bug。
- [x] Vault migration（P0 secret migration 收尾）：`platform/vault/`，HashiCorp Vault Community、file storage + 真實 init/unseal（非 `-dev` mode）、KV v2、GITHUB_TOKEN 已從 `.env` 遷移至 `secret/devops/github`（round-trip 以長度比對驗證，從未重印明文）、最小權限 policy 經 4 項邊界測試驗證（允許讀取自己範圍、拒絕 list engines/建立 policy/讀取範圍外路徑，皆為真實 403）。詳見 `platform/vault/README.md`。
- [x] Container security scan gate（Trivy）+ Gitleaks history scan：`platform/security/`。Gate policy 為「拒絕任何有修復方案的 CRITICAL/HIGH」（`--ignore-unfixed`，因為目前 base image 有 4 個 CRITICAL 但上游無修復方案，硬擋這些沒有意義）；已用較舊映像（python:3.9-slim，28 個可修復 CRITICAL/HIGH）驗證 gate 真的會擋。已接入 `deploy.sh build`：掃描失敗則不建立 `:dev` alias，連帶擋住 deploy/promote。Gitleaks 對全部 10 個 commit 掃描：no leaks found。詳見 `platform/security/README.md`。
- [x] SBOM 產出 + Cosign 簽章（SBOM 半部分完整，image 簽章待 registry）：`scan_image.sh` 產 CycloneDX SBOM（89 components）；`sign_artifact.sh` 用本地 key pair 簽章+驗證，已用竄改測試證明驗證真的會抓到（改一個 byte，驗證正確失敗）。**重要揭露**：Cosign v3 即使是 key-based 簽章，預設仍會把 hash+簽章+時間戳記發布到公開、永久、不可刪除的 Sigstore Rekor transparency log（未找到可關閉的 flag）；此行為在測試中途才發現，已如實告知使用者並取得同意才繼續。因此簽章預設關閉，需要 `SIGN_ARTIFACTS=1` 才會執行。過程中額外發現並修正兩個 bug：(1) SBOM 內容非 byte-stable（每次重新產生 serialNumber/timestamp 不同），原本以「檔名是否存在」判斷冪等性是錯的，已改為比對 bundle 內記錄的 digest 與目前檔案的實際 digest；(2) `.gitignore` 的 `*.pub` 全域規則誤傷了應該要公開的 Cosign 公鑰，已加 negation exception 修正（用 `git add -n` 而非 `git check-ignore` 驗證，因為後者在 negation 規則下的 exit code 容易誤導）。Image 本身簽章需要 registry（見下）。詳見 `platform/security/README.md`。
- [x] Secret rotation policy：`platform/vault/scripts/rotate_secret.sh`（輪替 + KV v2 版本歷史保留 rollback 能力）+ `check_rotation_due.sh`（依 90 天 policy 檢查是否逾期，與 `platform/iac/variables.tf` 的 `secret_rotation_interval_days` 對齊）+ `platform/vault/runbooks/rotate_github_token.md`（真正輪替 GitHub PAT 需要的人工步驟，因為產生新 PAT/撤銷舊 PAT 都需要 GitHub 本身）。用拋棄式測試 secret 完整跑過 rotate→驗證舊版本仍可讀→check_rotation_due 三種情境（正常/無記錄/逾期），未動用真正的 GITHUB_TOKEN（該 token 這個 session 還需要用來 push）。過程中發現並修正一個 bug：`vault kv metadata get` 不支援 `-field` flag。詳見 `platform/vault/README.md`「Secret Rotation」。
- [x] Registry promotion：`deploy.sh push`，push 到 GitHub Container Registry（`ghcr.io/drew-young-ai/`），已取得使用者同意。**重要教訓**：一開始用既有的 fine-grained PAT push 失敗（`permission_denied: ... does not match expected scopes`），一度誤判要去 fine-grained token 裡找 Packages 權限勾選——查證 GitHub 官方文件後確認 GitHub Packages **完全不支援 fine-grained PAT**，不論勾了什麼權限都一樣會失敗，只能用 classic PAT + `write:packages` scope。使用者提供新的 classic PAT（`GHCR_TOKEN`）後，已寫入 Vault 獨立路徑 `secret/devops/ghcr`（與 `secret/devops/github` 分開，因為是不同用途的憑證）。Push 成功，取得真正的 registry digest（非本機 buildx 偶爾產生的假 digest），package 可見度確認為 private（用 `gh api` 查證，非假設）。另發現並繞過 Docker Desktop credential store 在非互動環境下卡住的問題（改用暫時性 `DOCKER_CONFIG` 目錄，`trap RETURN` 確保用完即清）。詳見 `platform/compose/README.md`「Registry Promotion (GHCR)」。
- [x] Container image 本身的 Cosign 簽章：`deploy.sh push` 加上 `SIGN_ARTIFACTS=1` 時，對剛 push 的 digest 執行 `cosign sign`（複用 push 時已建立的 GHCR 憑證），同一套 Rekor 公開揭露（使用者已同意）。驗證：正確公鑰驗證通過；**故意用一組不相關的錯誤公鑰驗證同一張已簽章的 image，正確失敗**（`transparency log certificate does not match`），證明驗證機制是真的在檢查金鑰，不是走個形式。詳見 `platform/compose/README.md`「Verified」表格。

- [x] Station 5：MLX automation integration（`platform/llm-review/`）。本地 MLX endpoint（`127.0.0.1:9000`, `temperature=0`）讀取平台已產出的 deterministic evidence（build metadata、Trivy gate 結果、SBOM summary、develop 部署健康狀態、pilot 目錄 git diff），寫回結構化 review 至 `evidence/<pilot>/llm_review_<sha>_<ts>.json`。**核心約束**：產出 `LLM-generated evidence`，不產出 Human Acceptance——verdict **完全不影響 exit code**（`FAIL` 與 `PASS` 同樣 exit 0），`deploy.sh promote` 只「顯示」review 後仍照常要求真人輸入 `PROMOTE`，兩層機制確保 LLM 不會取得 release 阻擋權（`NEW_SERVICE_GUIDE.md` §8）。**確定性已實測非假設**：同一 `inputs_digest` 連跑 6 次，verdict+summary+findings 完全一致。5 種降級情境全部真實注入測試（endpoint down／timeout／回傳散文／回傳非法 verdict 值／回傳空 content，其中 3 種用 stub HTTP endpoint 觸發），降級時仍寫 evidence 檔（「沒複審」必須留痕，否則與「複審過且沒問題」無法區分）。過程中發現並修正 3 個 bug：(1) 系統 python3 為 3.9.6，`socket.timeout` **不是** `TimeoutError` 的別名（3.10 才是），導致所有 timeout 被誤分類；(2) 檔名只到秒精度，同秒內多次執行會靜默互相覆蓋；(3) `show_llm_review` 的 `ls | tail -1` 在 `set -euo pipefail` 下遇到「無 review」（最常見情況）會直接中止整個 promote。詳見 `platform/llm-review/README.md`。

- [x] Alerting + deterministic health verdict：`platform/observability/`。新增 Alertmanager（`127.0.0.1:19093`）、4 條版控中的 alert rule、以及 `check_health.sh`（排程 agent 的呼叫介面，exit code 契約：`0` HEALTHY／`1` DEGRADED／`2` CRITICAL／`3` UNKNOWN）。**同時補掉一個既有大洞**：production-like（blue/green）先前完全未被 Prometheus scrape——真正承載流量的環境是監控覆蓋率為零的那個，develop 反而full coverage。**exit 3 是這層的核心設計**：壞掉的 Prometheus 與健康的 Prometheus 都回報「零個告警」，天真檢查會把兩者都判成正常，監控於是靜默 fail open；因此腳本先驗證「確實有東西在監看」（Prometheus 可達／規則數 > 0／規則評估無錯／已接上 Alertmanager／Alertmanager 可達）才願意把空告警清單解讀為好消息。**驗證方式為真實注入故障非讀設定**：停掉 develop 容器 → 規則 71 秒後 firing 並帶正確 runbook 抵達 Alertmanager；再停掉 production-like blue → critical；全部復原 → HEALTHY，NGINX 兩個 vhost 皆 200。過程中發現並修正一個規則設計缺陷：`up == 0` 這種寫法會對 blue/green 中「刻意停放」的那一色永久 firing（實測已進入 pending），已改為 `sum(up{...}) == 0` 表達真正的中斷條件。另刻意不寫 CPU/memory/restart 規則——目前無 cAdvisor 產生這些指標，對不存在的指標寫規則會得到永遠不會 fire 的告警，讀起來像「一切正常」，比誠實承認缺口更糟。詳見 `platform/observability/README.md`。

- [x] 平台自身的測試與 CI：`platform/tests/`（5 個 suite、約 7 秒、`run_all.sh` 一鍵）+ `.github/workflows/platform-tests.yml`（`platform/**` 觸發）。此前平台**只有 `platform/iac/**` 有 CI**，而 630 行、決定什麼能進 production-like 的 `deploy.sh` 零自動化測試；唯一的 `tests/` 是 pilot 的。設計約束：不需要 Docker daemon／不需要 Prometheus／不需要 MLX／不需要網路（否則 CI 跑不動、也慢到沒人會跑）；**不為測試在生產程式碼開後門**——隔離靠把 `platform/` 複製到暫存目錄再呼叫副本，受測程式碼與出貨程式碼逐位元相同；只有在「現實無法按需製造該狀態」時才用 stub（例如「Prometheus 活著但零條規則」「Prometheus 活著但沒接 Alertmanager」對真實 Prometheus 根本做不出來，而這兩個正是會被誤讀成健康的狀態）。**第一次執行就抓到 3 個真 bug**：`usage()` 從未列出 `promote` 與 `rollback`；`deploy` 的拒絕訊息宣稱 promotion「not-yet-built」但它就在同一個檔案裡；`pipeline-contract.yml` 要求 `image_tag` 而全部 5 個 build evidence 用的都是 `image`（合約與生產者悄悄脫節——比沒有合約更糟，因為它讀起來像被遵守）。兩條最關鍵的斷言：`promote` 必須是被真正的 develop gate 擋下而非被 LLM verdict 擋下（否則有人日後把 verdict 改成阻擋性，不會有任何東西反對）；零條規則必須判為 `UNKNOWN` 而非 `HEALTHY`。詳見 `platform/tests/README.md`。

- [x] 身分機制（人員 RBAC + 工作負載身分，視為**同一個機制**）：`platform/vault/scripts/setup_identity.sh`（冪等）+ `verify_identity.sh`（14 項邊界斷言全過）。人與機器都在回答同一個問題——「此主體如何證明自己是誰、該身分能做什麼」——因此共用同一批 `policies/*.hcl`：人走 `userpass`，機器走 `approle`。拆成兩套系統正是兩者日後漂移、最後沒人能回答「誰能讀這個 secret」的原因。角色矩陣：`platform-operator`（可讀 secret 值，禁止建 policy／開 auth method）、`platform-viewer`（**只能讀 metadata，不能讀任何 secret 值**）、`workload-station1-hello`／`workload-dataops`／`ci-pipeline`（各自最小範圍）。**`platform-viewer` 是關鍵角色**：它讓「看得到這個 secret 存在、上次何時輪替」與「讀得到它的內容」成為兩種可強制執行的不同權限——KV v2 把兩者拆成 `secret/metadata/*` 與 `secret/data/*` 兩條 API 路徑，所以這不是慣例或 UI 設定，是 Vault 真的在檢查。這正是資料擁有者／稽核者需要的層級：能跑 `check_rotation_due.sh` 回答「這個憑證逾期了嗎」，但永遠讀不到憑證本身。`platform-admin` 刻意只給 `default` policy 而非 root——常駐的 root 等價人類帳號正是這個機制要消除的東西。**動態短期憑證：保留接縫、不啟用**（目前無資料庫可簽發，是決定不是疏漏）；接縫寫在 `policies/workload-station1-hello.hcl`，重點在於啟用那天**不會改變**的東西：AppRole、工作負載身分、認證方式、管理者全部不動，只有可讀路徑從靜態 `secret/data/...` 換成動態 `database/creds/...`。這個不對稱就是先做身分後做憑證的理由——**身分是難以事後補上的，憑證有效期只是一個旋鈕**。工作負載 token TTL 已實測為 1199 秒，短命身分今天就有，不必等動態憑證。詳見 `platform/vault/README.md`「Identity」。

- [x] 備份與還原（含**還原演練**）：`platform/backup/`。「有備份」是關於檔案存在的宣稱，「能還原」是完全不同且強得多的宣稱，而後者才是凌晨三點唯一有用的那個。演練三條規則：**絕不覆蓋正式系統**（獨立容器 + 拋棄式 volume，port 18299；只有摧毀正式環境才能演練的程序不是程序，是威脅，所以永遠不會被演練，所以永遠不會有用）、**還原前先驗完整性**（比對備份當下記錄的 sha256）、**證明資料可用而非僅存在**（解出 tar 完全無法證明 Vault 可用——演練用真實 unseal key 解封並讀回真實 secret）。9/9 通過，含「還原後 policy 數 ≥ 6」與「approle 仍在」兩項，因為天真的演練太容易過：用 root token 從半殘的 Vault 讀出一個 secret 看起來完全正常，而所有 policy 與 auth method 早已靜默遺失。**重要性質**：Vault 檔案儲存是加密的，所以備份檔安全，但也**單獨無用**——還原需要 `.init-output.json` 的 unseal key，備份刻意不含它；把兩者放進同一個壓縮檔會把安全的備份變成一個交出全平台機密的檔案。過程發現一個真 bug：unseal 迴圈只套用第一把金鑰就結束、Vault 停在 1/3 且**任何地方都沒有錯誤訊息**——`docker exec -i` 會接管呼叫者的 stdin，在 `while read` 迴圈裡把剩下兩把金鑰吃掉了。這正是演練存在的理由：一個看起來正確、執行無錯、卻靜默產出不可用系統的還原程序。詳見 `platform/backup/README.md`。
- [x] Log 資料治理（分級 → 遮罩 → 分流）：`platform/observability/`。**分級**：服務以 Docker label `platform.data_class` 自我宣告，宣告式且由服務擁有，而不是 Alloy 裡一份新增服務就過期的硬編碼清單；未宣告者一律 `internal`（安全的預設是**不**給予較廣受眾存取權）。**遮罩**：`loki.process` 在**寫入時**遮蔽，兩條管線都套用（PII 會漏進開發者當下在寫的那條 log，很少剛好是有人分類為敏感的那條）。寫入時而非查詢時是重點：查詢時過濾是一個「所有查詢的人都會記得套用」的承諾，而未遮蔽的識別碼一旦進入儲存，唯一真正的補救是重建整個 store——這是全平台唯一「晚做比做得不完美更貴」的機制，所以先出 v1 而不是之後出完整版。**v1 範圍誠實揭露**：3 種高信心樣式（台灣身分證、email、憑證型 token），**不會**抓到自由文字姓名、地址或非預期格式。**分流**：不同 Loki **租戶**而非只是不同 label——label 可被查詢者選擇不寫而繞過，租戶由 Loki 在每個請求上強制執行，指向 `platform` 的資料源在結構上不可能回傳 restricted 資料。保存期 platform 168h／restricted **72h**（敏感資料保存**更短**不是更長，敏感材料存在多久本身就是一種控制）。**端到端驗證方式是產生真實格式的 PII**：儲存內容為 `patient [REDACTED_TWID] contacted [REDACTED_EMAIL] token [REDACTED_TOKEN]`；同一容器從 platform 租戶查詢 0 筆；原始 PII 在兩個租戶皆 0 筆；無 `X-Scope-OrgID` header 一律 401。**磁碟防護兩層**：Loki limits 保護 Loki，Docker `json-file` 輪替才真正保護 host disk（Loki 的限制對容器寫爆 daemon 自己的 log 檔完全無能為力，而那會塞爆磁碟並拖垮包含監控在內的每個服務）。
- [x] Grafana 人員存取控制（補完 A 類）：`platform/observability/scripts/setup_grafana_identity.sh`。匿名存取已關閉——先前是全員 Viewer，這讓平台其他地方所有人員 RBAC 控制在「人們真正看資料的那個地方」完全失效。**這支腳本存在的理由是一個陷阱**：`GF_SECURITY_ADMIN_PASSWORD` 只在 Grafana **首次**初始化資料庫時生效，既有 `grafana-data` volume 會靜默忽略它、管理員帳密維持原樣。只設這個環境變數就收工**比什麼都不做更糟**：它把「所有人都是 Viewer」變成「任何人試一下全世界最好猜的憑證就是 Admin」，而設定檔讀起來像是已經鎖好了。實測確認 `curl -u admin:admin` 在設了變數之後仍然成功。腳本現在會用 `grafana cli admin reset-admin-password --password-from-stdin` 重設實際密碼，並**雙向驗證**：Vault 憑證可用、且 `admin:admin` 已失效。Vault 是真實來源，`.grafana.env` 只是可拋棄的遞送細節。
- [x] 價值流看板（H 類）：`platform/valuestream/board.py` → `docs/Value-Stream-Board.html`。**衍生式，絕不手動維護**：六欄全部由平台已產出的 evidence 推導，沒有卡片可拖。這是其他所有設計的出發點——需要有人記得更新的看板一週內就會悄悄失準，而失準的看板比沒有看板更糟，因為人們會相信它；在這裡「develop 已部署」就**等於** `deploy_develop_<sha>.json` 存在且健康，看板沒有辦法與現實不一致。**「待人工核可」是刻意獨立的一欄**：證據齊備、等待真人的工作與單純已部署是**不同狀態**，混為一談會藏住人工核可造成的佇列，而那正是 DORA「streamlining change approval」在講的瓶頸。WIP 限制超限即標示（DORA：用途是讓問題浮現，不是要求做更快）。Alertmanager 無法連線時「線上異常」欄回報**未知**而非零，並附橫幅說明空欄不代表沒有異常——與 `check_health.sh` exit 3 同一原則。詳見 `platform/valuestream/README.md`。

- [x] SAST + DAST（補上掃描的兩個空層）：`platform/security/scan_sast.sh`（Semgrep OSS，接進 `run_local_ci.sh` 第 2/6 階段）+ `scan_dast.sh`（OWASP ZAP baseline，部署後、promote 前）。**填補的洞**：此前所有掃描器都只看**產物**（Trivy／SBOM／簽章）、**基礎設施**（Checkov／OPA）或**歷史**（Gitleaks），沒有任何一個看應用原始碼，也沒有任何一個看執行中的系統。這讓兩整類問題隱形：今天寫下的 SQL injection 會通過所有既有 gate（映像沒 CVE、IaC 沒問題、沒提交 secret）；而缺失的安全標頭、外洩的版本橫幅、可達的除錯端點**不存在於任何檔案中**，是部署後系統的性質，再多原始碼分析也永遠找不到。**兩個 gate 都拒絕把空掃描當成乾淨**：Semgrep 的 `p/shell`／`p/bash` 根本不存在（皆 404），打錯字會導致掃 0 個檔案卻仍回報 0 findings——開發過程實際觀察到；ZAP 對無法連線的目標同樣產出無告警的報告。兩者現在都把「掃描量為零」判為 gate 失敗，`test_evidence_contract.sh` 另外斷言任何 PASS 紀錄都必須真的檢查過東西。**ruleset 釘選不用 `--config=auto`**（auto 在執行時上網解析規則，同一個 commit 今天過明天不過，破壞這些 gate 存在的意義：確定性回饋）。**DAST 門檻經實測校準為 MEDIUM 而非 HIGH**：被動掃描幾乎不會產生 HIGH（那需要主動攻擊流量），實測一個刻意缺標頭的頁面產生 3 個 MEDIUM 卻仍被 HIGH-only 判為 PASS——會放行那種目標的 gate 不是 gate。**雙向驗收**：SAST 對故意寫的注入漏洞 7 個 ERROR 擋下（exit 1）、ruleset 打錯字判為 FAIL；DAST 對缺標頭頁面 3 個 MEDIUM 擋下、對正式端點放行。**首次執行即驅動 3 項真實修正**：(1) GitHub Actions 把 `${{ }}` 直接插進 `run:` 腳本本體（GitHub 在 shell 看到之前就完成替換，含 shell 元字元的值會變成程式碼），同一步驟還只用 sed 跳脫雙引號來組 JSON，攻擊者可控的 commit message 含反斜線就會產生無效 JSON；(2) `curl | bash` 從**可變的 master 分支**安裝 tfsec——未驗證的遠端程式碼執行、可變來源、而且 tfsec 已被 Aqua 廢棄並併入平台本來就在用的 Trivy，三個問題疊在一個步驟；(3) NGINX 洩漏版本號且缺 CORP 標頭，兩者都不存在於任何原始碼（版本橫幅只是 nginx 預設值），ZAP 還拒絕 `same-site` 作為 CORP 的合格值，把我們推向 `same-origin`——對一個從不被跨來源嵌入的服務而言，那才是正確值。安裝走隔離路徑：Semgrep 用 `uv tool install`（非 `pip install`），ZAP 用 Docker，兩者皆 ARM 原生無 x86 模擬。詳見 `platform/security/README.md`。

- [x] 稽核軌跡（A 類收尾）：`platform/vault/scripts/setup_audit.sh`（冪等、自我驗證）+ `audit_query.sh`（稽核者介面）。此前平台能**執行**存取控制卻無法**舉證**：`verify_identity.sh` 證明的是什麼「可能」發生，稽核日誌記錄的是什麼「實際」發生——對稽核單位而言那是兩個問題，而他們問的是第二個。**必讀：Vault 稽核裝置是 fail-closed**，所有裝置都寫不進去時 Vault **停止服務所有請求**（它不執行記不下來的操作）。這是正確姿態也是可用性風險：稽核 volume 滿了就是 Vault 全面中斷，連帶部署停擺。兩項刻意的緩解：(1) 啟用**兩個**裝置（Vault 只要一個成功就繼續）——`file/` 寫入 `vault-logs` volume 作為真實紀錄並納入備份，`stdout/` 經 Docker→Alloy→Loki 可查詢並充當第二個 sink；(2) 用具名 volume 取代原本的 tmpfs。**修掉一個會以最糟方式失敗的設定**：`/vault/logs` 原是 4MB tmpfs，理由是「反正沒在用，Vault 預設寫 stdout」——啟用稽核的那一刻這句話就失效，而舊設定會讓稽核日誌**上限 4MB、每次重啟全部消失，同時 `vault audit list` 仍回報裝置健康**；會蒸發的稽核日誌比沒有更糟，因為它看起來像有覆蓋。**HMAC 保護經實測非假設**：`setup_audit.sh` 會讀一個已知 secret 再 grep 稽核日誌找該字面值，出現就讓 setup 失敗（`log_raw=true` 絕不可設，那會把稽核軌跡變成平台最大的明文機密庫）。**立即產出的價值**：稽核紀錄獨立佐證了 RBAC——`platform-viewer` 讀 value 被 DENIED、讀 metadata 被 allowed，白紙黑字證明該角色**在正式環境真的被擋下過**，而不只是測試說它會。做成查詢工具而非直接看日誌，是因為原始日誌是每請求約 2KB 的 JSON 且關鍵值全被 HMAC；把 `tail audit.log` 交給稽核者不是稽核能力，是一堆剛好含有答案的位元組。詳見 `platform/vault/README.md`「Audit Trail」。
- [x] `docker exec -i` stdin 陷阱：**同類缺陷第三次出現後升級為 build 會擋的檢查**（`platform/tests/test_static.sh`）。`docker exec -i` 會接管呼叫者的 stdin，在本平台造成三次事故，每次都靜默且偽裝成別的問題：(1) 還原演練的 unseal 迴圈只套用第一把金鑰就結束、Vault 停在 1/3 且**任何地方都沒有錯誤訊息**——docker 把迴圈剩下的輸入吃掉了；(2) `audit_query.sh` 每次查詢回傳零筆，因為 heredoc 才是 python 的 stdin、管線被丟棄；(3) `verify_identity.sh` 整套在 `policy write evil -` 卡死七分鐘（該指令的 `-` 表示從 stdin 讀取），無輸出無逾時。三次就不是巧合而是類別。現在每個 `docker exec -i` 都必須明確關閉 stdin（`</dev/null`）、明確重導入某物、或標記 `# stdin: intentional`，否則測試失敗；檢查本身也做過負向驗證（故意移除一處防護，確認會被抓到）。同時修掉三處潛伏未爆的同類寫法。

- [x] 排程與自動觸發（收掉最早提出的那個迴圈）：`platform/scheduler/`（8 個 launchd job）+ `platform/vault/scripts/rotate_audit_log.sh`。**兩層架構，且不可合併**：第 1 層是 launchd + 純腳本，**永遠不依賴任何 agent 在線**——若平台自己的監控只在 Claude session 開著時才運作，那平台在沒人使用時（也就是大部分時間、也正是最需要它盯著的時候）就是瞎的；第 2 層才是 agent，讀證據、關聯推理、提出診斷，那是腳本做不到而 LLM 真正加值的部分（`status.sh --json` 與 `evidence/scheduler/` 已備妥作為其輸入，但尚未有東西消費）。**用 launchd 而非 cron**：它會在重開機後恢復，並且**會補跑機器睡眠期間錯過的任務**——筆電上 cron 會直接跳過一整晚的備份而且不會說。**cadence 依「被監看的事物變化多快」而定**，不是齊頭式的每小時：health/board 15 分、audit/backup/dast 24 小時、sast/restore/rotation 7 天（sast 每週重掃未變動的原始碼唯一的意義是**上游規則更新後打中舊程式碼**）。**刻意永不排程任何需要人決定的指令**——`deploy.sh promote` 會等人輸入 `PROMOTE`，排程它等於順手刪掉 release gate，`test_scheduler.sh` 有斷言擋住。**wrapper 的每一部分都對應一種具體失效**：原子 `mkdir` 鎖（非 test-then-create 競態）、陳舊鎖自動打破（否則被砍掉的行程留下的鎖會**永久且靜默地**停用該 job，看起來就像它一直很忙）、逾時（卡住的 job 比失敗的更糟——它持有鎖，之後每次執行都被跳過而排程表看起來全綠）、每次執行都留證據、**只在狀態轉換時通知**（每 15 分鐘回報一次失敗會訓練人去靜音它，而被靜音的告警等於被停用的告警；復原也通知，因為失敗後的沉默與失敗持續中無法區分）、明確設定 `PATH`（launchd 幾乎不給環境，docker 與 uv 裝的 python3 都不在預設路徑，這是 launchd job 靜默什麼都沒做的頭號原因）。**`status.sh`——誰來監督監督者**：排程器無法監督自己，沒載入、plist 壞掉、PATH 錯誤，結果都不是警報而是沉默，而沉默正是健康系統的樣子；因此新鮮度由**消費端**檢查，超過兩倍間隔即成為可見的 `STALE`，而且**陳舊性凌駕記錄的狀態**——四天前回報 ok 的 job 不是 ok，是一個過期的宣稱。**通知預設只在本機**：通知承載的是一套處理醫療資料的系統的營運細節，推送到 Telegram 或 webhook 是有實質影響範圍的決定，屬於使用者而非可以順手繼承的預設；內建 sink 不離開本機（append-only JSONL + macOS 通知中心），設定 `NOTIFY_WEBHOOK` 才會外送。**稽核輪替**解掉唯一一個「持續惡化且失敗模式是全面中斷」的風險：Vault 稽核是 fail-closed，無界成長的日誌就是一場排定好的中斷；輪替用官方的 mv + SIGHUP 機制（實測 Vault 保持解封、持續服務、重開新檔），**封存永不刪除**（保存期是稽核單位的決定，憑猜測刪除是這裡唯一不可逆的錯誤），只壓縮並回報總量。**驗證方式是實際透過 launchd 觸發**，不是在自己 shell 裡跑：8 個 job 全部在 launchd 環境下成功執行（含需要 docker 的），逾時、鎖定、陳舊鎖、never-run、陳舊 ok、轉換通知全部測過，26 項斷言。**測試當場抓到我自己造成的一個真 bug**：加 `disown` 消除 "Terminated: 15" 雜訊時把 job 移出了 job table，`wait` 因此拿不到結束狀態，**所有 job 都記錄成功，包括 `false`**——排程器看起來完美無瑕而實際只會記 ok。改為由子 shell 自行寫出 exit code 檔案。詳見 `platform/scheduler/README.md`。

### 尚未完成的主要交付鏈

- [ ] Cloud trial VM + rathole Public URL experiment（Cloudflare Tunnel
      Quick Tunnel 已驗證可用作免費臨時方案，見 `STAGE_REVIEW.md` §7；
      固定網址/正式方案仍待雲端供應商決策）。
- [ ] Optional Cloudflare Tunnel adapter（具名 tunnel + 固定網址，需要
      使用者已有的網域或新申請一個，token 存放方式已在討論中確認）。
- [ ] **Pilot technical validation — graceful shutdown 未通過**：
      2026-08-11 實測（主機端快速輪詢 + 容器內部日誌兩種方法互相印證）
      發現 `/health/ready` 在 SIGTERM 後從未回應 503，直接從 200 跳到
      連線中斷，沒有可觀察的 draining 窗口。`app.py` 的程式碼邏輯看起來
      正確（`shutting_down` flag + threaded `server.shutdown()`），但實際
      行為沒有達到 README 宣稱的「graceful shutdown 時返回 503」。尚未
      決定要修正還是記錄為已知限制。
- [ ] **Human Platform Usability Review**：依 `docs/Pilot-Validation.md`
      定義，這項檢查「operator 能否理解 CI、dashboard、evidence、
      rollback」，本質上需要使用者本人操作，AI 無法代為完成。走查清單
      見 `docs/Human-Usability-Review-Checklist.md`（含每項工具的實際
      連結與點擊步驟，2026-08-11 逐項實測過才寫的）。

### 2026-08-11 發現並修正：Grafana dashboard 完全空白（真實 bug）

`platform/observability/grafana/dashboards/devops-overview.json` 的 5 個
panel 定義全部缺少 `datasource` 欄位、`id` 也是 `null`，導致整個
dashboard 頁面完全不渲染（不是「有 panel 但無資料」，是連 panel 框都
不出現）。這個 bug 存在的期間，`Plan.md`/`README.md` 一直宣稱「Grafana
已建立 DevOps Overview dashboard」——這個宣稱只驗證過底層資料存在
（Prometheus/Loki API 查得到），從來沒有實際打開瀏覽器看過畫面渲染
結果。用 kimi-webbridge 實際開瀏覽器截圖才發現。

**修正**：5 個 panel 補上明確的 `datasource: {type, uid}`（Prometheus
`PBFA97CFB590B2093` / Loki `P8E80F9AEF21F6940`）與唯一 `id`。重新截圖
驗證：5 個 panel 全部顯示真實資料（Requests=582、Errors=0、Up=1、
Request Rate 時序圖、Container Logs 即時日誌）。

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
8. [x] Vault migration（HashiCorp Vault Community，secret 遷移 + 最小權限驗證）
9. [x] platform/security/：Trivy container scan gate + Gitleaks history scan
10. [x] SBOM 產出 + Cosign SBOM 簽章（image 簽章待 registry；Rekor 公開揭露已取得使用者同意）
11. [x] Secret rotation policy（rotate_secret.sh + check_rotation_due.sh + runbook）
12. [x] Registry promotion（GHCR，`deploy.sh push`；classic PAT `write:packages`，見上的教訓）
13. [x] Container image 本身的 Cosign 簽章（`cosign sign`，非 `sign-blob`；`SIGN_ARTIFACTS=1`）
14. [ ] 建立 rathole Public URL experiment  <- 需要人類決定雲端供應商，暫停待決策
```

所有目前已知「本機可自主完成」的項目至此已全部完成。唯一剩餘項目 rathole Public URL experiment 需要使用者決定雲端供應商才能繼續。

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

- [x] GitHub Free 或外部 GitLab Free source control。
- [x] OpenTofu IaC validation、plan、policy 與 state governance（state governance
      僅文件化契約，local state 為 Phase 1 預設）。
- [x] provider-neutral Cloud resource planning（`platform/iac/providers.tf`，
      未 apply）。
- [x] local network architecture、NGINX、local HTTPS（F5/WAF/CDN contract
      simulation 仍是文件層級，未實作模擬）。
- [x] CI/CD、container registry、security gates、artifact promotion。
- [x] develop / production-like 最小隔離、blue/green 與 rollback。
- [x] Grafana、Prometheus、Loki、audit 與 evidence。
- [ ] Pilot 的 technical deployment、test、failure path 與 recovery evidence
      （2026-08-11 實測發現：graceful shutdown 未如預期在 SIGTERM 後回應
      503，見 §0.1 待處理項目——這項還不能打勾）。
- [ ] Human Platform Usability Review（定義上需要操作者本人審視 CI/
      dashboard/evidence/rollback，無法由 AI 代為完成）。

### 本階段延後

- [ ] 實際 Cloud resource apply。
- [ ] 多節點 HA、真實 F5/WAF/CDN 與大型流量。
- [ ] Kubernetes、Argo CD、Kubeflow、Airflow。
- [ ] MLOps/LLMOps 完整平台；只保留未來 integration contract（詳見
      `docs/Future-ML-LLMOps.md`，已補上具體臨床模型類型）。
- [ ] DataOps 完整平台（Warehouse/Lakehouse/多模態醫療資料、Databricks 或任何
      實際資料庫）；只保留未來 integration contract（詳見
      `docs/Future-DataOps.md`：資料種類對應、FHIR/OMOP/REDCap 整合、多人協作、
      MinIO vs Databricks Volumes 取捨）。**例外**：Vault `secret/dataops/*`
      namespace + `dataops-readonly` policy 已提前建置並驗證（4 項邊界測試，
      含跨 namespace 隔離），見 `platform/vault/README.md`「DataOps
      Namespace」——這是介面契約裡唯一已經從「紙上約定」變成「真的存在且測過」
      的部分，其餘（GHCR namespace、Observability 指標命名）仍是命名慣例，
      尚無實體可測試。
- [ ] 產品 PRD、產品 UX 與業務效果驗收。

### 本階段需提前處理的 gate（不是延後項目，是延後範圍裡的例外）

- [ ] **PHI/病人資料安全檢查**：`evidence/` 產出流程與 `scan_secrets.sh`
      （Gitleaks）目前只防 secret（token/key），不防 PHI（病歷號、身分證號
      等）。在任何真實醫療資料流過 pipeline 之前，必須先做一次明確的
      evidence/日誌管線 PHI 安全檢查並寫進 runbook——見
      `docs/Future-DataOps.md`「資料治理／PHI 安全」。這是本文件目前唯一
      一項「內容延後、但檢查點不能延後」的項目。

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
- [Future-DataOps.md](docs/Future-DataOps.md)
- [Plan-detail.md](docs/Plan-detail.md)

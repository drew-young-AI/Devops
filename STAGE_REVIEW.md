---
type: review
title: 階段性審查
description: Point-in-time assessment of platform stages; third review 2026-08-19 covers the dimensional data layer, four public-health feeds at three granularities, and the retirement of station1-hello.
tags:
  - devops
  - review
timestamp: 2026-08-19T12:00:00+08:00
---
# DevOps 平台階段性 Review

- **第三次 review：2026-08-19**（見文末 §10，涵蓋資料層、四個公衛 feed、
  官方地理代碼、stock/flow 語意、station1-hello 退役、送 GitHub 前的檢查）
- 第二次 review：2026-08-18（§9，ingress、有狀態 pilot、migration gate、
  公衛 twin、k3d 練習叢集）
- 第一次 review：2026-08-11（§1–§8）

> §1–§9 是**當時**的快照，刻意不回頭改寫。文中提到 station1-hello 的地方
> 記錄的是那個階段的真實狀態；它已於 2026-08-19 退役，見 §10.5。

本文件是目前實際建置狀態的快照，給討論下一步用。詳細規格與逐項驗證證據見
`Plan.md`（交接狀態權威來源）與各 `platform/*/README.md`。

---

## 1. 整體架構（已建置）

```mermaid
flowchart TB
    subgraph SRC["Source of Truth"]
        GH["GitHub<br/>drew-young-AI/Devops"]
    end

    subgraph CI["CI (GitHub Actions)"]
        CIW["iac-validate.yml<br/>fmt/validate/Checkov/plan/tfsec"]
    end

    subgraph LOCAL["本機 Mac：DevOps 控制面"]
        IAC["platform/iac/<br/>OpenTofu skeleton<br/>(provider-neutral, 未 apply)"]

        subgraph BUILD["platform/ci/ + platform/security/ + platform/compose/"]
            CILocal["run_local_ci.sh<br/>lint/test/docker build"]
            SCAN["scan_image.sh<br/>Trivy gate + SBOM"]
            SIGN["sign_artifact.sh / cosign sign<br/>(opt-in, Rekor 公開記錄)"]
            DEPLOY["deploy.sh<br/>build/push/deploy/promote/rollback"]
        end

        VAULT["platform/vault/<br/>HashiCorp Vault Community<br/>secret/devops/{github,ghcr}"]

        subgraph RUNTIME["執行環境"]
            DEV["station1-hello-develop<br/>:18080"]
            BLUE["productionlike-blue<br/>:18081"]
            GREEN["productionlike-green<br/>:18082"]
        end

        NGINX["platform/nginx/<br/>TLS 終止 + 反向代理<br/>dev :18443 / prod-like :19443"]

        OBS["platform/observability/<br/>Prometheus + Loki + Grafana + Alloy"]
    end

    REGISTRY["GHCR (私有)<br/>ghcr.io/drew-young-ai/station1-hello"]
    PUBLIC["Cloudflare Tunnel (Quick)<br/>*.trycloudflare.com<br/>已驗證可用，臨時性質"]

    GH --> CIW
    GH -.push 觸發.-> IAC
    CILocal --> SCAN --> DEPLOY
    DEPLOY --> REGISTRY
    SIGN -.簽 SBOM/Image.-> REGISTRY
    VAULT -.提供憑證.-> DEPLOY
    DEPLOY --> DEV
    DEPLOY --> BLUE
    DEPLOY --> GREEN
    NGINX --> DEV
    NGINX --> BLUE
    NGINX --> GREEN
    PUBLIC -.外部連線.-> NGINX
    DEV -.日誌/指標.-> OBS
    BLUE -.日誌/指標.-> OBS
    GREEN -.日誌/指標.-> OBS
```

**邊界規則**（未變）：`platform/` 不依賴特定 Pilot 業務邏輯；`pilots/` 可使用
platform 提供的能力。目前唯一 Pilot 是 `station1-hello`（Python stateless
hello world）。

---

## 2. Build → Deploy 流程（單一 Pilot 的完整生命週期）

```mermaid
flowchart LR
    A["build<br/>git sha 打 tag<br/>run_local_ci.sh"] --> B{"scan_image.sh<br/>Trivy gate<br/>拒絕可修復的<br/>CRITICAL/HIGH"}
    B -- FAIL --> X1["不建立 :dev alias<br/>擋住後續所有步驟"]
    B -- PASS --> C["建立 :dev alias<br/>產出 SBOM"]
    C --> D["push<br/>推到 GHCR<br/>記錄真正 registry digest"]
    D --> E{"SIGN_ARTIFACTS=1？"}
    E -- 是 --> F["cosign sign<br/>SBOM + image<br/>(公開 Rekor 記錄)"]
    E -- 否 --> G
    F --> G["deploy develop<br/>獨立 Compose project<br/>環境變數注入"]
    G --> H{"health check"}
    H -- 不健康 --> X2["DEPLOY FAILED"]
    H -- 健康 --> I["promote<br/>(需輸入 PROMOTE 確認)"]
    I --> J{"develop 驗證 gate<br/>是否有對應 sha 的<br/>健康 deploy 紀錄？"}
    J -- 否 --> X3["拒絕 promote"]
    J -- 是 --> K["啟動另一個 blue/green 顏色<br/>smoke test"]
    K --> L["翻轉 NGINX 流量"]
    L --> M["production-like 服務中"]
    M -.需要時.-> N["rollback<br/>(需輸入 ROLLBACK 確認)<br/>翻回舊顏色"]
```

**關鍵設計**：
- 每一步都寫 evidence（`evidence/<pilot>/*.json`），大檔案（Trivy 原始掃描、SBOM 原始檔）本機保留但 gitignore，只 commit 精簡摘要
- `promote`/`rollback` 是真人互動確認（`read -p`），沒有 `--yes` 旁路
- Blue/Green 用不同 host port（18081/18082），同一份 image，不重 build

---

## 3. Secret 流程

```mermaid
flowchart LR
    ENV["~/.env<br/>migration source only"] -->|一次性遷移| VAULT["Vault KV v2<br/>secret/devops/github<br/>secret/devops/ghcr"]
    VAULT -->|devops-readonly policy<br/>最小權限 token| PUSH["deploy.sh push<br/>讀 ghcr token"]
    ROTATE["rotate_secret.sh"] -->|寫入新版本| VAULT
    CHECK["check_rotation_due.sh<br/>90天 policy"] -.查詢.-> VAULT
    CHECK -.逾期.-> ALERT["需要外部排程觸發提醒"]
```

`secret/devops/github`（fine-grained，git push 用）與 `secret/devops/ghcr`
（classic + write:packages，registry push 用）刻意分開存放——兩組憑證用途不同，
即使背後是同一個 GitHub 帳號。

---

## 4. 目前完成狀態

| 層 | 元件 | 狀態 |
|---|---|---|
| Source control | GitHub repo | ✅ |
| CI | GitHub Actions（IaC 驗證） | ✅ |
| IaC | OpenTofu skeleton（provider-neutral，未 apply） | ✅ 契約完成，未接雲端 |
| 網路 | NGINX（本機 HTTPS，dev + prod-like 各一個 vhost） | ✅ |
| 部署 | Compose adapter（develop / blue-green / rollback） | ✅ |
| Secret | Vault（migration + rotation policy） | ✅ |
| 安全 | Trivy gate / Gitleaks / SBOM / Cosign（SBOM + image） | ✅ |
| Registry | GHCR（private） | ✅ |
| 觀測性 | Prometheus / Loki / Grafana / Alloy | ✅（Phase 0 既有） |
| Public URL（免帳號快速方案） | Cloudflare Tunnel Quick Tunnel | ✅ 已實測，端到端打通（見下方驗證記錄） |
| Public URL（固定網址/正式方案） | Cloudflare 具名 tunnel 或 rathole + Cloud VM | ⛔ 待決定：要不要固定網址、要不要雲端供應商 |
| Pilot 驗收 | Technical validation + Human Usability Review | ⛔ 需要人類親自使用評估 |
| K8s / MLOps | — | 刻意延後（Plan.md 明確排除本階段範圍） |
| **資料架構**（Warehouse/Lakehouse/DataOps） | — | 🗣️ 討論中，尚未動手，見第 8 節 |

**Public URL 驗證記錄（2026-08-11）**：`cloudflared tunnel --url https://127.0.0.1:18443`，
免帳號、免網域，數秒內取得 `*.trycloudflare.com` 網址。從外部 curl `/health/ready`、`/version`
皆正確回應，NGINX access log 直接看到外部 host header，證明完整鏈路（Cloudflare edge → 本機
NGINX → pilot 容器）真的打通。測完即關閉（Quick Tunnel 為臨時性質，不留無人看管的公網暴露）。

---

## 5. 目前的已知限制（誠實列出，不是藏起來）

- SBOM 簽章非 content-stable：Trivy 每次重新產生 SBOM 的 timestamp/serialNumber
  都不同，導致 `SIGN_ARTIFACTS=1` 幾乎每次 build 都會產生新的 Rekor 公開記錄
- Secret rotation 沒有自動提醒機制，`check_rotation_due.sh` 要靠外部排程觸發
- `push`/`promote` 之間沒有互相 gate（push 完不強制要求先 promote 過的 image
  才能 deploy，兩者目前是獨立步驟）
- 只有一個 Pilot（station1-hello），platform 的「多 Pilot 共用」假設還沒被
  第二個服務驗證過
- **Docker Desktop 重啟後，所有容器會全部停止，需要手動拉回**：Vault 需要重新
  `init_and_unseal.sh`（資料有保留，Cluster ID 不變，但每次都要重新解封）；
  develop/production-like/nginx 也要重新 `deploy`/`docker compose up`。目前
  沒有開機自動拉起的機制
- Kubernetes、MLOps/LLMOps、真實多節點 HA：明確排除在本階段外

---

## 6. 討論用的開放問題（DevOps 平台本身）

1. **下一個 Pilot** 要做什麼？（驗證「platform 是否真的可重用」的關鍵測試——
   資料架構的 Stage 1 Pilot 有機會直接扮演這個角色，見第 8 節）
2. **Registry promotion 的 gate** 要不要收緊——例如強制 `deploy develop` 前必須先
   `push` 過？
3. 要不要開始寫 `platform/runbooks/`（目前完全空）？deploy/rollback/incident
   的操作手冊现在都只存在於各 README 的敘述文字裡，沒有獨立的 runbook 格式
4. Docker Desktop 重啟後的手動拉起流程，要不要寫成一個 `platform/runbooks/restart_stack.sh`？

---

## 7. Public URL：免費方案結論

在還沒有 GCP/Azure/AWS 帳號之前，**Cloudflare Tunnel 已經是可行的免費方案**，
不需要等雲端供應商決策：

- **臨時測試**：Quick Tunnel（上面驗證過的），零帳號零網域，網址每次重啟會變
- **固定網址**：免費 Cloudflare 帳號 + 一個已有的網域，`cloudflared tunnel create`
  建立具名 tunnel——這個還沒做，要做隨時可以繼續
- rathole + Cloud VM 仍是 `docs/Network.md` 的主方案，但不是「現在唯一能用的
  路」——這點跟原本的規劃認知不同，值得更新 `docs/Network.md` 的優先序

---

## 8. 資料架構討論（Data Warehouse / Lakehouse / DataOps）

### 8.1 背景

老闆的命題：DataOps（含 Warehouse、Lakehouse、DataOps 本身）三個目的要一起考慮，
提到會用 Databricks，但沒給需求或規模。目前結論：**先有個開始，再擴充**，仿照
`station1-hello` 驗證 DevOps 平台骨架的同一套邏輯，去驗證資料架構骨架。

### 8.2 框架：兩個軸，不是一件事

- **軸一（資料放哪裡查）**：Data Warehouse（schema-on-write，BI 導向）vs Data
  Lake（schema-on-read，便宜但治理弱）vs Lakehouse（Delta Lake 統一兩者，
  Databricks 的核心賣點）。企業「被迫走兩套工具」的根源正是 Warehouse/Lake
  分離；Lakehouse 存在的理由就是解這個問題。
- **軸二（流程紀律）**：DataOps——pipeline 怎麼測試/版控/部署/回滾/核准，
  跟軸一選什麼儲存無關，是操作紀律不是產品。

**結論**：選 Databricks 做 Warehouse，Lakehouse（Delta Lake）是附帶的儲存層，
不用另外立項；DataOps 的「怎麼做」延伸現有 GitHub Actions + Vault + evidence
模式，不用 Databricks 原生 Workflows 當主控。

### 8.3 被推翻的方案：Databricks + ETL + Kafka + Redis + 戰情

討論過程中曾提出這個組合，已被推翻，理由留存：

- **和「三合一不切實際」的結論自相矛盾**：從 1 個平台變成 5 個工具，只是把
  複雜度換位置，不是減少
- **Kafka 必要性未證明**：沒有明確的高吞吐/多消費者串流場景，很可能是
  「聽起來先進」而非真需求；若資料其實是批次的，Dagster/Airflow 排程即可
- **Redis 用途未定義**：若只是快取 Databricks SQL 查詢結果，Databricks SQL
  本身已有查詢快取層，額外加 Redis 等於重現「兩份資料對不齊」的老問題
- **「戰情」名稱與架構延遲互相矛盾**：戰情室意涵秒級新鮮度，但 Lakehouse
  路徑天生是分鐘級延遲（micro-batch、compaction）；若真要秒級，需要完全
  不同的架構（Kafka Streams/Flink 直接寫入 Redis 或 ClickHouse/Druid），
  比原方案更複雜
- **便宜替代方案**：Redis Streams 本身可當輕量事件匯流排（不必額外裝
  Kafka）；戰情儀表板直接用**既有的 Grafana**（`platform/observability/`
  已在跑，加一個 Databricks SQL data source 即可，不必新建平台）

### 8.4 建議的分階段路線圖（尚未建置，討論用）

```mermaid
flowchart TB
    S0["Stage 0　目錄與邊界<br/>platform/iac/databricks/<br/>platform/dataops/<br/>pilots/dw-warehouse-poc/"]
    S1["Stage 1　最小 Pilot<br/>1 SQL warehouse + 1 catalog + 1 schema + 1 table<br/>Vault secret + CI workflow + evidence"]
    S2["Stage 2　develop/prod-like 對等物<br/>dev_catalog / prod_catalog<br/>真人確認才能 promote"]
    S3["Stage 3　治理對齊<br/>schema 變更 gate<br/>(Checkov 有無 Databricks 規則待查證)"]
    S4["Stage 4　第一個真實 ETL<br/>只有具體資料來源才啟動<br/>此時才決定 Dagster 等工具"]

    S0 --> S1 --> S2 --> S3 --> S4
```

**每個 Stage 都只做上一個 Stage 驗證過的東西 + 一小步**，不預先蓋大架構。
Stage 1 的唯一目的：驗證「Vault 存的 token 能不能讓 CI 對 Databricks 做
Terraform plan/apply」，不是做出有意義的資料模型。

### 8.5 Stage 1 如何接進現有架構（提案，尚未建置）

```mermaid
flowchart LR
    GH["GitHub repo<br/>（既有）"] -->|提案：新 workflow| CIW["databricks-validate.yml<br/>fmt/validate/plan"]
    CIW --> DBTF["platform/iac/databricks/<br/>databricks provider"]
    VAULT["platform/vault/<br/>（既有）"] -->|提案：新路徑 secret/devops/databricks| DBTF
    DBTF -->|Stage 1 apply| WH["Databricks SQL Warehouse<br/>+ 1 catalog + 1 schema + 1 table"]
    WH -.底層即是.-> DELTA["Delta Lake<br/>Lakehouse 儲存層，非另立專案"]
```

沿用既有的 provider-neutral IaC skeleton（`platform/iac/providers.tf` 本來就
留了雲端 provider 的註解區塊）、既有 Vault policy（`devops-readonly` 的
wildcard 直接涵蓋新路徑，不用改 policy）、既有 CI pattern（複製
`iac-validate.yml` 的 fmt/validate/plan 骨架）。**不會**直接套用
`platform/compose/deploy.sh` 那一整套，因為 Warehouse 是 managed cloud
service，沒有容器可以 build/push/swap——複用的是**模式**（evidence-driven、
develop-gate、真人核准），不是機制本身。

### 8.6 尚待查證/確認

- Databricks Free Edition 的 workspace-level REST API / CLI / Asset Bundles
  部署，官方文件沒有明確列在限制清單內，但也沒明確確認可用——需要實測
- Checkov 是否已有 Databricks 相關的 policy 規則可直接套用
- IBM 與 Databricks 的關係查證：**未找到 IBM「放棄」Databricks 的證據**，
  查到的相反——IBM 目前是 Databricks Gold partner，2026/8 前剛拿到新的
  Brickbuilder Specialization。IBM 有自己的競品 watsonx.data，2024 年
  IBM Think 上曾拿自家 Presto C++ 引擎對比 Databricks Photon（宣稱同效能
  60% 成本），這可能是「放棄」說法的來源——正確描述是「合作又競爭」，不是
  「放棄」

### 8.7 值得帶回去問老闆的問題

1. Warehouse 的消費者是誰——BI 分析師手動查，還是要接某個報表/儀表板？
   （決定 warehouse size、要不要額外快取層）
2. 資料來源是內部系統匯出，還是要接外部 API/資料庫？（決定 Stage 4 的 ETL 形狀）
3. 「老闆提到 Databricks」是已經有 license/帳號，還是也在評估中？
   （若還在評估，Stage 1 可以先用 Free Edition，不急著用掉正式 license 額度）

---

## 9. 第二次 Review（2026-08-18）

第一次 review 之後的十個 commit。這一輪的主題不是「加功能」，而是**發現既有
機制其實沒在運作**——三次都是「檢查通過、機制沒作用」的同一種形狀。

### 9.1 三個「看起來在運作、其實沒有」

| 機制 | 表面狀態 | 實際 | 怎麼發現的 |
|---|---|---|---|
| 排程（6 個日/週任務） | 全部「最近成功」 | **`runs = 0`，launchd 從未觸發過**，紀錄全是手動執行 | 追查 DAG 變紅 |
| 備份覆蓋率 | `BACKUP PASS` | station2-twin 的 volume **不在任何清單**，仍回報成功 | 建立第一個有狀態服務 |
| 測試套件自身 | `0 failed` | 兩個拼錯的 helper **靜默跳過**，斷言從未執行 | 自己打錯字 |

共同點：**清單、log 訊息、exit code 都無法回報自己缺什麼。** 修法一律是把
「宣稱」換成「觀測」——排程加執行來源溯源（`XPC_SERVICE_NAME`）、備份加
全域 volume 覆蓋率掃描、測試加未定義 helper 靜態掃描。

### 9.2 Public URL：卡住的是錯誤前提，不是缺決策

`Plan.md` 掛了數週的「rathole/Cloudflare 需要人類決定雲端供應商」——不需要。
所有服務綁 127.0.0.1，Tailscale 在 host 上直接可達 loopback。不開 router
port、不設 inbound 規則、不需要雲端帳號。

`platform/ingress/` 的設計重點是**暴露天花板**：依「靠什麼驗證」決定，不依
「名字聽起來多敏感」。prometheus / loki / alertmanager / vault 一律 `never`。
alertmanager 最尖銳——`/api/v2/silences` 是寫入端點，碰得到就能無聲關掉監控。

⚠️ 測試套件自己曾把 Vault 暴露到 tailnet 上（約兩分鐘，已移除並確認不可連）：
refusal 測試跑的是**正式設定**，而我為了驗證防護把 vault 天花板暫時提高，
於是套件真的執行了那個操作。現在測試跑在指向死埠的 fixture 上，正式設定只讀
不執行。

### 9.3 Station 2：有狀態服務與 migration gate

平台第一個有狀態服務（PostgreSQL）。關鍵設計是 **readiness ≠ liveness**：
Docker healthcheck 只打 `/health/live`，接 readiness 會讓資料庫一抖就重啟
所有 replica，而重啟修不好資料庫。

`platform/db/migrate.sh` 拒絕三件事，皆以注入驗證：套用後被修改的 migration
（checksum 不符）、未標記 `CONTRACT-PHASE` 的破壞性變更、半套用（單一 transaction）。

第二項的理由具體：blue/green 共用同一個資料庫，舊顏色還在服務時 `DROP COLUMN`
等於毀掉回滾目標——部署在最需要能倒回去的那一刻變成不可逆。

### 9.4 公衛 CDC 監測：pilot 的真實負載

疾管署 RODS 急診監測開放資料，109,907 列、2007→2026、22 縣市、**無 PHI**。

在此之前 station2-twin 只是「有 twin 之名的狀態儲存」。**twin 的第 4、5 要素
（模型、背離偵測）到這一步才存在**：歷史同週分布是模型，當期是觀測，兩者的
差距就是疫情訊號。方法用 historical limits（同 ISO 週 ±1、前 5 年、mean ± 2sd），
是公衛實務界既有方法，長官一句話能聽懂。

2026-W32 實測：2/22 縣市超出歷史上限（宜蘭 z=2.49、南投 z=2.16），嘉義市
z=1.07 未告警。**它不亂叫**，這是偵測器最重要的性質。

過程中的真實缺陷：疾管署伺服器**送錯中繼憑證**（leaf 的發行者與伺服器送出的
中繼是不同的 CA），瀏覽器靠 AIA 自動補抓所以看不出來。解法是釘住正確中繼，
不是 `verify=False`——這個 job 的輸出是「官方通報數字」。

### 9.5 目前完成狀態（相對 §4 的增補）

| 層 | 元件 | 狀態 |
|---|---|---|
| Ingress | Tailscale serve + 暴露天花板 | ✅ tailnet 已用；funnel 待 admin console 啟用 HTTPS |
| 資料庫 | PostgreSQL + migration gate | ✅ 四項注入驗證 |
| 有狀態 pilot | station2-twin | ✅ 四種 readiness 狀態實測 |
| 真實負載 | CDC RODS 公衛監測 | ✅ 11 萬列，冪等 ingest，證據鏈 |
| Twin 模型 | historical limits 背離偵測 | ✅ 2/22 告警 |
| 排程 | launchd 日曆觸發 + 來源溯源 | ⚠️ 已修正，**首次真實觸發待觀察** |
| K8s | k3d 3 節點 + Calico + kube-prometheus | ✅ 練習環境；NetworkPolicy 四向驗證 |
| 異地備份 | rclone crypt | ⏸ 機制完成，使用者決定保留討論 |

### 9.6 下一步

1. Spark 回放 pipeline（**誠實定位**：11 萬列不需要 Spark，它是 CYCH 自家
   急診即時 feed 的架構預演）
2. k3d 叢集重建（真 StorageClass + registry）→ pilot 上 K8s
3. Kubeflow Pipelines standalone
4. Vault 動態資料庫憑證（**建議插隊先做**——Vault 側設定與底層無關，
   100% 帶得走）

---

## 10. 第三次 Review（2026-08-19）— 資料層與 Pilot 汰換

這一階段的主題是**把資料當成一等公民**，以及**汰換掉不再有用的 Pilot**。
兩件事互為因果：station1-hello 已經把部署主線走完，剩下所有值得驗證的
問題都是有狀態的問題。

### 10.1 資料：從 11 萬列到 439 萬列，並且知道每一列的來歷

| | 第二次 review | 現在 |
|---|---|---|
| feed 數 | 1（RODS） | **4** |
| 空間粒度 | 縣市 | 縣市 / **鄉鎮** |
| 時間粒度 | 流行病學週 | 週 / 年 / **日** |
| 量測型別 | 只有 flow | flow + **stock**（且 schema 記錄是哪一種） |
| 地理鍵 | 自創（`tw-台中市`） | **內政部官方代碼**（22 縣市 / 365 鄉鎮 / 7,667 村里） |
| 事實列數 | 109,907 | **4,390,947** |

`cdc-tb-caremag`（結核病每日縣市鄉鎮管理中個案）是公開資料裡空間與時間
**同時最細**的一組。找到它的方法值得記下來：不是猜 URL，是對
`data.cdc.gov.tw` 的 CKAN API 列舉全部 73 個 dataset、逐一 `package_show`
再過濾。**先列舉再過濾，不要先假設再驗證。**

村里級的疫情 feed **不存在**（`Dengue_Daily.csv` 已下架）。所以維度建到村里、
事實只到鄉鎮——維度描述的是國家的行政區劃，不是今天剛好有哪些 feed。

完整的來源盤點、髒資料清單與每一個清理決定的理由，見
[`pilots/station2-twin/DATAOPS-LOG.md`](pilots/station2-twin/DATAOPS-LOG.md)。

### 10.2 這一階段抓到的三個缺陷，都是「安靜地錯」

**(1) 值衝突被當成重複列丟掉。** CareMag 有 187,724 列逐位元組相同的重複
（占 12%），去重是對的。但其中**一對鍵相同、值不同**：`舊中縣/豐原市` = 1
對上 `台中市/豐原區` = 24，同一天同一地。第一版去重只比對鍵，保留先遇到的、
丟掉另一個，**沒有任何訊息**。

最危險的地方：修掉之後**總列數完全沒變**，都是 4,085,772。任何基於筆數的
檢查都抓不到。現在的規則是「值相同 → 重複，計數後丟棄；值不同 → 衝突，
拒絕並具名印出」。不加總成 25，因為資料沒說這是兩群人還是一筆重述——
加總是猜測。

**(2) 監控盯著已經不重要的服務。** station2-twin 跑了好幾天，Prometheus
完全沒有抓它；監控整段時間都是綠的，因為它盯的是 station1-hello。
儀表板對著錯的服務顯示「一切正常」，比沒有儀表板更糟。

**(3) 事實表的自然鍵假設「一列一個數字」。** 舊鍵是
`(source, disease, geo, period, age, visit_type)`，這在每個 feed 只發布一個
計數時**碰巧**成立。CareMag 一列發布三個量測，第二、三個會 UPSERT 蓋掉第一個
——沒有錯誤、沒有違反約束、表面完全正常、三分之二的資料消失。`metric_id`
現在是自然鍵的一部分。

### 10.3 stock 不是 flow，而且 schema 現在說得出來

`管理中個案數` 是**存量**：那一天還在治療中的人數。`就診人次` 是**流量**。
存量沿時間加總是胡說——同一個病人會在他生病的每一天各被算一次，結核病療程
6–9 個月，天真的年度 `SUM` 高估約 200 倍。

舊 schema 沒有任何欄位記錄一個數字是哪一種，所以沒有任何東西能阻止那個查詢
被寫出來。`metric.measure_type` 把它變成資料的屬性；
`app/surveillance.py` 的 `MODELS` 把每個疾病綁定到唯一一組
(source, metric, time_level)，問 `?disease=tuberculosis` 得到 **HTTP 422**，
不是一個從 prevalence 算出來、看起來很有信心的 z-score。

### 10.4 expand/contract 走完一輪（004 → 007，約一週）

```
003  建 surveillance_observations      單一 feed、單一形狀
004  EXPAND：星型模型建在旁邊           兩張表並存，舊顏色照讀舊表
005  修第一次真實載入暴露的兩個鍵缺陷
006  改用官方地理代碼 + 加入 metric 維度
007  CONTRACT：舊表退場                 確認無人再讀之後
```

004 到 007 之間那段時間差就是紀律的全部意義。blue 與 green 共用一個資料庫；
若 004 就把舊表 drop 掉，那個「應該可回滾」的部署會親手毀掉回滾目標。
代價是多帶一張冗餘表幾天，換掉的是一場滾不回去的故障。

### 10.5 station1-hello 退役

它的任務完成了：build → SAST → Trivy → SBOM → deploy → blue/green promote
→ rollback 全部走通並留下證據（`evidence/_retired/station1-hello/`）。
無狀態服務驗證不了備份、還原、schema 遷移與憑證輪替，而那才是真正會出事的
地方。

退役是**連根拔除，不是留半截**：Prometheus job、告警規則、Grafana 面板、
nginx vhost、compose 環境、Vault policy 與 AppRole、ingress ceiling、
`recover.sh`、`statusdag`、CI 預設值全部改指 station2-twin 或據實移除。
`statusdag` 的 `probe_deploy` 原本硬寫死 station1 的證據路徑，會在 Pilot
消失後繼續回報它最後一次 promote 當成平台現況——比回報「不知道」更糟。

**沒有假裝還在的東西**：Prometheus 沒有 production-like 的 scrape job，
告警沒有 blue/green 規則，`recover.sh` 沒有選顏色的分支。station2-twin 的
compose 把資料庫與應用綁在一起，接不上 blue/green（見
`docs/Backlog.md` §2）。空著並寫明理由，好過留下永遠紅的目標與虛構的規則。

### 10.6 可重現性：載入器現在有自己的執行環境

先前 ingest 腳本是用「PATH 上剛好有的 python」跑的。那台主機的 python 是
3.9、沒有 psycopg，而要裝它就得污染主機——本機規則明文禁止。
**結果取決於你當時在哪個 shell 的管線不叫可重現。**

現在 `pilots/station2-twin/ingest/Dockerfile` 釘死 python 3.12 +
psycopg 3.2.3 + certifi，`run.sh` 在容器裡執行。地理參考資料是 repo 內的
**帶日期快照**（`reference/moi_admin_20260818.csv`，sha256 已記錄），
不是每次去打第三方 API——依賴即時 API 的載入器無法重現上個月的結果。

### 10.7 目前完成狀態

| 層 | 元件 | 狀態 |
|---|---|---|
| 資料來源 | 4 個 CDC feed，3 種粒度，2 種量測型別 | ✅ 4,390,947 列，重跑後列數不變 |
| 地理維度 | 內政部官方代碼（含 7,667 村里） | ✅ 鄉鎮代碼推導經雙向驗證 |
| 名稱對照 | `geo_alias` + crosswalk CSV | ✅ 10 筆宣告，皆附可查證理由 |
| 資料品質 | 重複 / 衝突 / 拒絕分開計數 | ✅ 全部寫入 `ingest_runs` |
| Schema | expand/contract 007 | ✅ gate 兩次正確擋下 |
| Vault | 動態資料庫憑證 | ✅ 6/6，含撤銷後確實被 postgres 拒絕 |
| 身分 | 人員 RBAC + 工作負載身分 | ✅ 14/14 邊界斷言 |
| 監控 | Prometheus / 告警 / Grafana | ✅ 改指 station2-twin，新增 schema 與 DB 錯誤面板 |
| Pilot | station2-twin | ✅ ready, schema=7, creds=vault |
| 測試 | 平台套件 + pilot 契約 | ✅ 32/0 suites、115/0 static、10/10 contract |
| blue/green | — | ❌ 無目標 Pilot（原因與判定見 Backlog §2） |

### 10.8 送上 GitHub 之前做過的事

- `git ls-files` 全文掃 token / 私鑰 / 密碼樣式 → **無**（命中的兩處是變數引用）
- `Plan.md` 洩漏 Tailscale 節點名與 tailnet 網域 → **已改寫**；私有網路的
  DNS 名稱不進 repo
- `.gitignore` 的 `evidence/*/_raw.*` 是**單層** pattern，把 pilot 證據移到
  `evidence/_retired/<pilot>/` 之後就失效了，四份原始掃描輸出（其中一份含
  每一行被比對到的原始碼）從「被忽略」變成「下次 `git add -A` 就進版控」→
  改為 `evidence/**/`。**依賴目錄深度的忽略規則，一次重整就會壞掉。**

### 10.9 下一步

1. **Kafka + Redis + Spark 回放**——使用者判定：資料尚未清洗完畢，先不動。
   `docs/Spark-Design.md` §7 的分期仍然有效，起點是「分解 + 往返檢查」。
2. 事實表無法承載 rate（`value INTEGER`），要接 `tb_town_inc_rate` 需要
   numeric 量測欄位。
3. 流行病學週 ↔ 曆法日期仍未確立（六種慣例都對不上 53 週年），週層級與
   日層級目前無法 join。
4. k3d 叢集重建（真 StorageClass + registry）→ pilot 上 K8s。

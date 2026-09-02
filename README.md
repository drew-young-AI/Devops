---
type: overview
title: DevOps 平台總覽
description: "Central index: where to look at the platform, where every kind of record lives, and the directory boundaries."
tags:
  - devops
  - platform
  - entry-point
timestamp: 2026-08-11T20:05:56+08:00
---

# DevOps Platform Workspace

縮小版企業 DevOps／DataOps／MLOps 控制面，跑在**兩台機器、兩種 CPU 指令集**上。
不是產品，也不是完整企業 HA 環境。

| 環境 | 機器 | 叢集 | 架構 | 角色 |
|---|---|---|---|---|
| **dev / SIT / UAT** | MacBook Pro M5 (`mac.local`) | k3d `devops-lab` | `linux/arm64` | 開發、整合測試、驗收測試 |
| **prod** | Ubuntu 26.04 (`ubu.local`) | k3s `ubu` | `linux/amd64` | 生產服務節點 |

**兩台的指令集不同，這不是細節。** Mac 上建出來的映像檔是 arm64-only，送到 Ubuntu
會通過 `docker save`、`ctr images import`、`kubectl apply` 全部步驟，直到 kubelet 才
以 `ErrImageNeverPull` 失敗——真正的原因 `no match for platform in manifest` 埋在沒人
看的 containerd log 裡。守衛是
[`test_image_arch.sh`](platform/tests/test_image_arch.sh)，細節見
[`platform/k8s/README.md`](platform/k8s/README.md)。

**這份 README 是總表。** 它只放指標（網址、位置、規則），細節一律留在各自的檔案裡——
把內容複製過來，三個月後就會有兩份互相矛盾的說法，而讀的人分不出哪份是真的。
`platform/tests/test_readme_index.sh` 會檢查這裡的每一個連結存在、每一個網址活著。

---

## 一、現在打開哪裡看

其他電腦連得到（區網，無需登入本機）。主機名由 `scutil --get LocalHostName` 決定，
不是寫死的——`PLATFORM_LAN_HOST` 曾停在一個舊主機名 `70.local`，那個名字根本不解析，
於是每一封告警信裡的連結都指向不存在的主機。

| 看什麼 | 網址 | 給誰 | 需要登入 |
|---|---|---|---|
|| **三線階段燈號** | http://mac.local:13000/d/platform-stages/ | 長官、人類 | Grafana 帳號 (詳見 platform/observability/README.md) |
|| **DataOps 管線** | http://mac.local:13000/d/dataops-pipeline/ | 資料負責人 | Grafana 帳號 (詳見 platform/observability/README.md) |
|| **服務總覽** | http://mac.local:13000/d/devops-overview/ | 維運 | Grafana 帳號 (詳見 platform/observability/README.md) |
| 階段報告（靜態、可離線轉寄） | http://mac.local:18085/Stage-Report.html | 長官 | 否 |
| **八張圖（三線平台圖譜）** | http://mac.local:18085/report/plates.offline.html | 長官、簡報 | 否 |
| 決策紀錄索引 | http://mac.local:18085/decisions/index.md | 全部 | 否 |
| 價值流看板 | http://mac.local:18085/Value-Stream-Board.html | 維運 | 否 |
| 管線狀態 | http://mac.local:18085/Pipeline-Status.html | 維運 | 否 |
| 原始指標查詢 | http://mac.local:19090/ | 工程 | **否（刻意，見 ADR-0003）** |

Grafana 是這裡**唯一會驗證身分**的服務，所以它是唯一適合放需要權限區隔的東西的地方。
Prometheus 開在區網且無認證，是明示接受的取捨，不是疏漏——
[ADR-0003](docs/decisions/0003-prometheus-lan-exposure.md) 記了理由與代價。
Alertmanager、Loki、node-exporter **刻意留在 loopback**，由
[`test_network_exposure.sh`](platform/tests/test_network_exposure.sh) 每次跑測試時驗證。

機器讀的入口：[`docs/Stage-Report.json`](docs/Stage-Report.json)（schema `stage-report/1`）。

**沒有網路的場合**（火車上、醫院會議室、防火牆後面）：八張圖直接開檔案，
不需要伺服器也不需要網路——[`docs/report/plates.offline.html`](docs/report/plates.offline.html)。
頁面左上角有「匯出八張 SVG」，可以拖進 Keynote / PowerPoint。
它與線上版由**同一份來源**產生，用法與那三個只有開瀏覽器才找得到的坑見
[`docs/report/README.md`](docs/report/README.md)。

「三線階段燈號」最下面一列（2026-09-01 新增）回答的不是「現在健不健康」，
而是**「壞了多久，以及那段時間我們到底有沒有在看」**：涵蓋率、最長連續中斷、
無紀錄空窗次數。第一次計算就找到一段 **73.7 小時的監測中斷**——證據每 15 分鐘
寫了三天、約 200 份，沒有人打開過。
見 [ADR-0009](docs/decisions/0009-health-rollup-not-retention.md)。

---

## 二、紀錄放在哪裡

追溯的失敗模式不是「忘記決定什麼」，是**「找不到數字怎麼來的」，於是憑印象重估**——
而重估是穿著量測外衣的猜測。所以每一種紀錄都有一個位置和一條規則。

| 紀錄種類 | 位置 | 規則 |
|---|---|---|
| **量測與取捨** | [`docs/decisions/`](docs/decisions/index.md) | 帶量測的必須有 `rerun:` 指令，且指向存在的檔案。`platform/docs/decisions.py` 會擋 |
| 計畫與交接 | [`Plan.md`](Plan.md) | **計畫與當時的判斷，不是現況。**現況看第一節的看板；衝突時以板面為準，因為板面是探測出來的、Plan.md 是寫下來的 |
| 階段 review | [`STAGE_REVIEW.md`](STAGE_REVIEW.md) | 人寫的階段檢討 |
| 待辦與遞延 | [`docs/Backlog.md`](docs/Backlog.md) | 每一項附「現在做 vs 等 K8s」判定 |
| 生態系調查 | [`docs/Ecosystem-Scan-2026-08.md`](docs/Ecosystem-Scan-2026-08.md)、[`docs/Ecosystem-Actions-2026-08.md`](docs/Ecosystem-Actions-2026-08.md) | 判準是「解掉我們真的踩過的問題嗎」，不是星數 |
| harness 工程觀察 | [`docs/Harness-Engineering-Notes.md`](docs/Harness-Engineering-Notes.md) | 學性質，不抄程式碼 |
| 機器可讀證據 | `evidence/` | 不放 secret、token 或完整敏感 payload |
| 服務接入契約 | [`NEW_SERVICE_GUIDE.md`](NEW_SERVICE_GUIDE.md) | 新服務進平台的最低要求 |
| 生產節點接手 | [`docs/Ubu-Prod-Bringup.md`](docs/Ubu-Prod-Bringup.md) | Ubuntu prod 已完成什麼、卡在哪、下一步順序 |
| **歷史里程碑** | [`docs/Milestone-2026-08-25.md`](docs/Milestone-2026-08-25.md) | **2026-08-25 當時的狀態，不是現況。** 保留是為了「那天我們說了什麼」可查；現況一律看板面與本檔第一節 |
| 簡報用八張圖 | [`docs/report/README.md`](docs/report/README.md) | 一份來源、線上與離線兩個版本；三個入口都記在那裡 |

### 決策紀錄的那條規則

一筆寫著 `measured: true` 的紀錄，必須附上重跑指令：

```yaml
measured: true
rerun: platform/analytics/benchmark.sh

```

`decisions.py` 會確認那個檔案還在。這是直接搬 AIS `registry.yaml` 的 `verify` 防殭屍規則——
**指向被改名腳本的 `rerun` 比沒有更糟**，它讀起來可重現，直到有人真的去跑。

索引由 `platform/docs/decisions.py --index` 產生，不要手改（筆數只寫在索引裡，
寫在這裡就是第二份會過期的副本）：[`docs/decisions/index.md`](docs/decisions/index.md)

---

## 三、各能力的說明在哪

**這一節是唯一的能力索引。** 不要在別處再寫一份——2026-09-02 的盤點發現
`platform/README.md` 裡有第二份，停在 2026-08-10，宣稱「所有可本機自主完成的
項目皆已完成，唯一剩餘是 Public URL」。那是 Kubernetes、第二台機器、
跨架構映像守衛之前的事。

**兩份索引的問題不是重複，是分岔**：沒有人會同時更新兩份，於是其中一份開始
說謊，而它讀起來和另一份一模一樣。

守衛：`platform/tests/test_doc_graph.sh` 從這個檔案出發走完整個連結圖，
**任何追蹤中的文件只要沒人連得到就會轉紅**（要嘛補連結，要嘛在
`platform/docs/doc_graph.py` 的 `EXEMPT` 裡寫下理由——豁免必須有理由，
沒有理由的豁免和「有人把它靜音了」分不出來）。

自己跑一次：

```bash
python3 platform/docs/doc_graph.py          # 看整棵樹
python3 platform/docs/doc_graph.py --check  # 有孤兒或斷鏈就 exit 1
```


每個 `platform/` 子目錄都有自己的 README，寫該能力**做什麼、怎麼跑、保證什麼、
目前缺什麼**。這裡只放指標。

| 目錄 | 說明 |
|---|---|
| [`platform/`](platform/README.md) | 目錄入口與邊界規則（能力索引就是下面這張表，不重複一份） |
| [`pilots/`](pilots/README.md) | Pilot 端：目前只有 station2-twin |
| [`platform/k8s/`](platform/k8s/README.md) | 兩個叢集、兩種架構，以及單節點測不到什麼 |
| [`platform/ci/`](platform/ci/README.md) | 雲端 tier 1 與本機全量的分工；BSD↔GNU 可攜性缺陷 |
| [`platform/observability/`](platform/observability/README.md) | 指標、日誌、告警、Grafana 權限 |
| [`platform/vault/`](platform/vault/README.md) | 動態資料庫憑證 |
| [`platform/db/`](platform/db/README.md) | 遷移器拒絕的三種危險情況 |
| [`platform/dataops/`](platform/dataops/README.md) | 約束看不見的三件事 |
| [`platform/mlops/`](platform/mlops/README.md) | 週期重訓與正在正確拒絕發布的閘門 |
| [`platform/analytics/`](platform/analytics/README.md) | DuckDB 分析鏡像 |
| [`platform/statusdag/`](platform/statusdag/README.md) | 狀態 DAG 與影響傳播 |
| [`platform/notify/`](platform/notify/README.md) | 事件與狀態分流 |
| [`platform/backup/`](platform/backup/README.md) | 備份與還原演練 |
| [`platform/security/`](platform/security/README.md) | SAST／DAST／映像掃描 |
| [`platform/ingress/`](platform/ingress/README.md) | 對外曝光與天花板 |
| [`platform/iac/`](platform/iac/README.md) | Infrastructure as Code |
| [`platform/scheduler/`](platform/scheduler/README.md) | 排程與鎖 |
| [`platform/tests/`](platform/tests/README.md) | 測試套件與守衛 |
| [`platform/llm-review/`](platform/llm-review/README.md) | LLM 複審 |
| [`platform/valuestream/`](platform/valuestream/README.md) | 價值流看板 |
| [`platform/compose/`](platform/compose/README.md) | Compose 部署 |
| [`platform/nginx/`](platform/nginx/README.md) | 靜態板面服務 |
| [`platform/docs/`](platform/docs/README.md) | 文件規格與 OKF 檢查 |
| [`pilots/`](pilots/README.md) | Pilot 的定位與退役紀錄 |

---

## 四、測試

```bash
platform/tests/run_all.sh                  # 預設跑全部三層，最嚴格
PLATFORM_TIERS=1 platform/tests/run_all.sh # 只跑不需要環境的契約層

```

| 層 | 需要什麼 | 缺席時 |
|---|---|---|
| 1 | 什麼都不需要 | — |
| 2 | Docker + 活的 Postgres | **硬失敗**（不是 skip） |
| 3 | k3d 叢集 | 大聲 skip，計入標題 |

**層級由呼叫端明示，永遠不自動偵測。** 自動把「沒有資料庫」降級成 skip，和
2026-08-19 那次 3h55m 憑證中斷長得一模一樣——那正是這條規則要抓的東西。
GitHub Actions 宣告 `PLATFORM_TIERS=1`，所以它的綠燈只代表**契約成立**，
不代表平台可用；`run_all.sh` 會在結論之前印出哪幾層沒跑。

判準不是「有幾個測試」，是**「每個守衛都被親手弄壞過一次」**。沒看過它紅過的守衛，
沒有理由相信它會紅。測試邊界本身是經驗問題，不是先驗問題——
見 [`docs/Harness-Engineering-Notes.md`](docs/Harness-Engineering-Notes.md)。

---

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

**給主管閱讀**：[`docs/Stage-Report.html`](docs/Stage-Report.html)（三線階段燈號的靜態版，每 15 分鐘重新產生，可離線轉寄），以及[八張圖](docs/report/plates.offline.html)。

2026-09-02 之前這裡指向 `docs/System-State.html`——一份手工維護的機制盤點，停在 2026-08-14，寫著「排程 8 個 job」（實際 17 個）與「資料治理與流程可視化幾乎是空的」。後面那句在八月是對的，在資料契約、血緣、DuckDB 鏡像、DataOps 指標都做完之後**是反的**。**一份給長官看的現況報告，說反了平台最近投入最多的地方**，比沒有那份報告糟。已刪除；它的 DORA／CNCF 十類分類框架留在 git 歷史裡，若要復活應該做成產生式的，不是手抄的。

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

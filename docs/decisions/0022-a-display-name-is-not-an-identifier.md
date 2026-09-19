---
type: explanation
title: 顯示名可以改，識別字不改——一次改名拆成五層，只動兩層
description: "Renaming station2-twin to station2-PublicHealth: which layers of the name moved (display, repo paths, image) and which did not (time-series labels, Kubernetes objects, database, Vault, frozen history), and why a renamed metric label is a silently severed history."
tags:
  - decision
  - naming
  - observability
  - migration
timestamp: 2026-09-19T12:00:00+08:00
decision:
  id: 22
  status: accepted
  date: 2026-09-19
  measured: true
  rerun: platform/tests/test_xref_lifecycle.sh
  supersedes: []
---

# ADR-0022：顯示名可以改，識別字不改

## 背景

pilot 當初叫 `station2-twin`（digital twin 的 twin）。它現在承載的是公衛監測資料，
使用者要求改名為 **station2-PublicHealth**。

實測爆炸半徑：**104 個檔案、363 處**（排除 `.git` 與 `evidence/`）。

## 問題

「改名」這兩個字底下是**五種不同的東西**，而它們的風險差了兩個數量級：

| 層 | 例子 | 改了會怎樣 |
|---|---|---|
| 顯示名 | 文件標題、看板說明、給人看的散文 | 沒事 |
| repo 路徑 | `pilots/station2-twin/`、`platform/k8s/station2-twin/` | 連結與腳本路徑要一起改，改漏了會立刻壞（看得見） |
| 建置識別字 | 映像名 `station2-twin:dev`、ghcr 套件名 | 要重建與重推；部署路徑會立刻壞（看得見） |
| **時序標籤** | Prometheus `job_name`、`service` 標籤 | **歷史被切成兩段**：改名前的序列永遠留在舊標籤下，看板與告警查新標籤查不到它，而畫面上只是「資料從某天開始」——**不會有任何錯誤** |
| **資料面** | k8s namespace／Deployment、資料庫、Vault 路徑、Compose 專案與容器名、卷名、`evidence/` 目錄 | 要重建 PVC、重發憑證、搬證據；失敗形狀是資料遺失 |

還有第六類：**凍結的歷史**（ADR、Backlog、STAGE_REVIEW、既有 evidence）。
那些是當時的紀錄，改掉等於竄改。

## 決策

**改前三層，不改後兩層，歷史一律不動。**

| 動作 | 舊 | 新 |
|---|---|---|
| 顯示名 | station2-twin | **station2-PublicHealth** |
| pilot 目錄 | `pilots/station2-twin/` | `pilots/station2-publichealth/` |
| k8s manifest 目錄 | `platform/k8s/station2-twin/` | `platform/k8s/station2-publichealth/` |
| 映像 | `k3d-registry:5111/station2-twin`、`ghcr.io/<owner>/station2-twin` | `…/station2-publichealth` |
| **不動** | Prometheus job／`service` 標籤、k8s namespace `station2` 與 Deployment `station2-twin-blue/green`、資料庫 `twin`、Vault `database/creds/station2-twin`、卷 `station2-twin-db`、`evidence/station2-twin/` | 同左 |
| **跟著目錄走** | Compose 專案名與容器名（現在是 `station2-publichealth-db-1`）——呼叫端改用 `platform/db/pilot_db.sh` 解析，不再寫死 | 見下一節 |

### 目錄名一律小寫，顯示名才有大小寫

`station2-PublicHealth` **不能**當識別字，這不是風格問題：

- **ghcr 拒絕儲存庫路徑裡的大寫**——`pilot-image.yml` 早就有一段註解記著這件事。
- **Kubernetes 物件名是 RFC 1123**，一樣不收大寫。
- **macOS 的檔案系統預設不分大小寫，Linux 分**。兩台機器（ADR-0008）各跑一種，
  一個混大小寫的路徑在其中一台上是兩個不同的檔案、在另一台上是同一個。

所以：**人看到的是 `station2-PublicHealth`，機器看到的一律小寫。**

### 呼叫端不可以依賴容器名（2026-09-20 修正，原本的做法已撤回）

**原本的做法**：搬目錄之前在 `compose.yaml` 加 `name: station2-twin`，把專案名釘死，
於是容器名不變、22 處 `docker exec station2-twin-db-1` 全部繼續能用。

**為什麼撤回**：那是**凍結一個衍生字串，去保護一批本來就不該依賴它的呼叫端**。
容器名是 Compose 用 `<專案>-<服務>-<n>` 組出來的，專案名預設又來自目錄名——
釘死它等於宣告「這個目錄以後也不能再改名」，而且下一個人看到那個 `name:` 不會知道
它在保護什麼。改名會痛，真正的原因是**有 22 個地方把一個衍生字串當成了介面**。

**現在的做法**：`platform/db/pilot_db.sh` 依 **compose 檔 + 服務名 `db`** 解析容器，
所有呼叫端改用它，compose 的專案名回到預設（跟著目錄走，容器現在叫
`station2-publichealth-db-1`）。宣告的東西是 compose 檔與服務名；容器名是產物。

**代價**：每次解析約 65ms。`dag.py` 一輪會呼叫 psql 數十次，所以在行程內快取。

**實際搬遷時踩到、與改名無關的一件事**：第一次 `up -d` 撞到舊專案還占著 15432，
埠綁定失敗但容器**已經被建立**；後續 `restart` 不會重建埠綁定，於是
「容器在跑、`docker exec` 正常、但主機連不到那個埠」——Vault 因此核發不了憑證，
而應用回報的是 `credentials_unavailable`，看起來像權限問題。**`down` 再 `up` 才會修好。**
要換專案名時，先把舊專案 `down` 乾淨，再起新的。

## 為什麼時序標籤那一層不動

這是這份 ADR 真正的內容。

改 `job_name` 與 `service` 標籤的成本，**不是**改設定的五分鐘，是**把這個平台
唯一的長期證據切成兩段**。Prometheus 的序列由標籤集定義：改一個標籤值就是開一條
新序列。舊的那條不會消失、也不會報錯，它只是**停在改名那一刻**。

於是：

- `up{job="station2-twin"}` 之後的資料不再增加，而查詢它的看板顯示「一切正常，只是沒有新點」；
- 新序列從零開始，`rate()` 與任何跨改名日期的比較全部斷掉；
- 告警規則若同時比對兩者，會在改名當天同時燒兩條。

**沒有任何一個環節會變紅。** 這正是本 repo 反覆記錄的那種失效：
安靜、看起來正常、而且要好幾週後有人問「為什麼只有兩週的歷史」才會被發現。

顯示名帶來的好處（讀的人知道這是公衛專案）**用文件就能拿到**；
歷史被切斷的代價**沒有任何辦法補回來**。

## 代價

**同一個東西有兩個名字。** 讀者會在看板標籤、容器名與 Vault 路徑裡看到
`station2-twin`，而文件說它叫 station2-PublicHealth。

這個代價被三件事限制住：

1. pilot 的 README 第一段就講明兩個名字與理由（不是藏在這份 ADR 裡）；
2. 這份 ADR 是那段文字指向的唯一出處；
3. `platform/docs/xref.py` 管的四個命名空間裡**沒有服務名**，所以這次改名沒有任何
   自動守衛——這件事登記為 Backlog T56，不在這一輪實作。

## 怎麼自己重跑

```bash
# 識別字是否真的沒被改到（這三個必須仍然存在）
grep -n 'job_name: station2-twin' platform/observability/prometheus/prometheus.yml
docker compose -f pilots/station2-publichealth/compose.yaml ps --format '{{.Name}}'  # 專案名跟著目錄
platform/db/pilot_db.sh name    # 呼叫端看到的是這個，不是寫死的字串
kubectl --context k3d-devops-lab -n station2 get deploy   # station2-twin-blue / -green

# 路徑與映像真的可用（會實際部署兩個顏色再還原）
bash platform/k8s/station2-publichealth/test_bluegreen.sh

# 文件沒有斷鏈、沒有孤兒
python3 platform/docs/doc_graph.py --check
python3 platform/docs/capability_graph.py --check
```

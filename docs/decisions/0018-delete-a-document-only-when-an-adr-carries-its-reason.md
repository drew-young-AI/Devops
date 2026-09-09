---
type: explanation
title: 刪除文件的判準是「理由有沒有被 ADR 接住」，不是「舊不舊」
description: "Why six documents were deleted on 2026-09-09, the three-part test each had to pass, and why two obvious candidates were kept."
tags:
  - decision
  - documentation
  - governance
  - reachability
timestamp: 2026-09-09T14:00:00+08:00
decision:
  id: 18
  status: accepted
  date: 2026-09-09
  measured: false
  supersedes: []
---

# ADR-0018：刪除文件的判準是「理由有沒有被 ADR 接住」

## 背景

`docs/` 累積到 23 份 `.md`，其中好幾份是**帶日期的快照**：某一天的生態系
掃描、某一天的里程碑報告、某一天逐項點過的走查清單。它們的共同特徵是
**寫的那天全對，而且再也不會被更新**。

問題不在佔空間。在於 `doc_graph.py` 保證它們**找得到**，而
`doc_freshness.py` 第 2 層明說：可達性**證不到內容是真的**。一份找得到、
標著「先看這份」、內容停在三週前的文件，比一份不存在的文件更貴。

## 判準（三條同時成立才刪）

1. **它的結論已經落在 ADR、Backlog 或產生式頁面裡。**
2. **沒有任何 ADR 引用它當證據。** ADR 引用的文件是那個決定的推理鏈，
   刪掉它，ADR 就變成一個沒有理由的結論。
3. **它不是產生式產物。** 產生式頁面重跑就有，刪了也不會少任何東西——
   但它們本來就不是「積攢的歷史」。

**不符合第 1 條時，先遷移再刪，不是直接刪。** 這一輪有兩筆是這樣處理的
（見下）。

## 刪掉的六份

| 檔案 | 為什麼可以刪 |
|---|---|
| `Ecosystem-Scan-2026-08.md` | 2026-08 的 GitHub topics 量測。採用／拒絕的結論已在 ADR-0001（DuckDB）與 ADR-0002（Spark 範圍） |
| `Ecosystem-Actions-2026-08.md` | 同一組掃描的行動版。**其中兩筆是活的缺口，先遷移成 §27 T29／T30 才刪** |
| `Milestone-2026-08-25.md` ＋ `.html` | 手寫的定日期現況頁。它的功能已由**產生式**的 `docs/Stage-Report.{md,html,json}` 取代，而那份每 15 分鐘重跑 |
| `Human-Usability-Review-Checklist.md` | 逐項寫死 2026-08-11 的連結與畫面。那天之後 Grafana 換了資料夾結構、部署換到 K8s——**清單描述的畫面已經不存在了**，照著走只會走進 404 |
| `Future-ML-LLMOps.md` | 1.8KB，一半已經被真的做出來的東西取代（`model_run`＋`feature_set`＋ADR-0016＋24 條 `mlops_*` 指標），另一半**併入** `Future-DataOps.md` |

## 第二輪（同日）：四份「第一天寫的、之後沒動過」的決策範圍頁

第一輪的判準抓的是**帶日期的快照**。第二輪換一個問法，抓到不同的一批：
**這份文件跟後來的 ADR 矛盾嗎？**

| 檔案 | 矛盾在哪（量得到的） |
|---|---|
| `Architecture.md` | 控制平面圖停在 `Production-like Compose -> NGINX`，並把 Kubernetes 列在「Future adapters：等平台契約通過再說」。**ADR-0010 早已把 Kubernetes 定為目標執行環境**，而 `prodlike` 節點在板面上是 `superseded`。**它不是舊，是反的**——而它從 README 連得到，標題叫「平台架構決策」 |
| `IaC.md` | 「Tool baseline」列 OPA/Conftest、Ansible、Packer——`grep` 全 repo：**各 0 個引用檔**。它列的是打算用的，讀起來像已經在用的。真正在用的 OpenTofu／Checkov／conftest 政策都在 `platform/iac/README.md`，量得到 |
| `Security.md` | 一張 P0 檢查清單，**六項全部沒打勾，而六項全部早就做完**（Vault 已 unsealed、機密已遷入、Gitleaks 每次測試都跑）。一份宣稱阻擋發行、而阻擋理由已不存在的清單，比沒有清單更糟 |
| `Pilot-Validation.md` | 驗證狀態機以 `PRODUCTION_LIKE` 收尾，而該節點是 `superseded`；它又依賴第一輪刪掉的走查清單 |

### 一個順帶的發現，說明「沒人讀」是可以被證明的

`platform/vault/runbooks/rotate_github_token.md` 引用
`docs/Security.md` 的「不使用長期 access key」原則。
**`grep` 那份 30 行的檔案，那句話從來不在裡面。** 引用是假的，而且沒有任何
檢查會抓到——`doc_graph.py` 只驗連結指向的**檔案**存在，驗不到引用的**內容**
存在（`Reachability.md` 自己寫著第 1 層證不到內容是真的）。

### 遷移了什麼，遷到哪

刪之前先把還成立的約束搬到**真的有人讀的地方**，這是判準第 1 條的執行：

- 「不得讀取／印出／複製／記錄 Secret 的值」「正式環境的不可逆動作由真人決定」
  → **`AGENTS.md` §2 硬規則第 4、5 條**。這兩條原本躺在一份沒有 agent 會讀的
  檔案裡，現在在每個 agent 接手時第一批讀到的地方。
- 平台／pilot 擁有權界線、「MacBook 是 PoC 主機」、「MLX 是自動化行為者不是
  部署目標」→ **`NEW_SERVICE_GUIDE.md`**。
- 「MinIO 是物件儲存，不取代 PostgreSQL」與 state 後端邊界
  → **`platform/iac/README.md`**。

### `STAGE_REVIEW.md` 通過了判準，所以沒刪

它自稱「目前實際建置狀態的快照」，而最後一次 review 是 2026-08-19——
K8s 轉向、pilot 資料迴路、整個 mlops 層全部在那之後。**那句話現在是假的。**
但 `docs/Future-DataOps.md` 三次引用它 §8 的 Stage 1-4 路線圖當推理依據，
所以它卡在判準第 2 條。**處置是修掉那句假話、在 README 標成凍結的歷史，
不是刪掉。** 判準的價值就在這種時候——它擋住了一個我想刪的檔案。

**兩輪合計：`docs/*.md` 由 23 份降到 14 份。**

## 沒刪、而且值得說明為什麼沒刪的兩份

- **`Spark-Design.md`** —— 它描述的東西**確實被放棄了**（3.2／3.3 已 drop，
  無容器、無設定引用），看起來是最典型的刪除對象。但 **ADR-0002 引用它四次
  當證據**，而且 `Ecosystem-Actions` 裡記著一段：上一輪建議「明確殺掉 Spark
  計畫」是**在沒讀這份文件的情況下說的**，讀了之後推翻了自己。刪掉它，
  ADR-0002 就變成一個沒有推理鏈的結論，而下一個人會再提一次 Spark。
  **可達性要防的正是這個。**
- **`Kubernetes-Readiness.md`** —— 名字像「轉移前的評估」，決定已由 ADR-0010
  做完，看起來也該刪。但它第 3 節是**零經驗缺口清單**，其中兩條是這個平台
  反覆踩的同一種形狀：kindnet **完全不執行 NetworkPolicy**（套用成功、
  `describe` 正常、沒有任何流量被擋），以及 CPU limit 造成的 throttling
  （症狀是「應用程式變慢」，而問題在 cgroup）。那不是歷史，是還沒踩到的坑。

## 這一條不涵蓋什麼

**不涵蓋 `Backlog.md`（178KB）與 `Plan.md`（68KB）。** 兩份都很大、都含大量
歷史，但它們是**累積式登記簿**不是快照：Backlog 的每一列都有「什麼時候該做」
的觸發條件，Plan.md 被 17 處引用（含程式）。把登記簿當成歷史文件刪掉，
等於把「為什麼還沒做」一起刪掉。

**刪除是可逆的。** 六份都在 git 歷史裡，`git show <sha>^:docs/<file>` 就拿得
回來。這一節存在的理由是：讓「要不要留」變成一個可以事後翻案的決定，而不是
一個沒人記得發生過的動作。

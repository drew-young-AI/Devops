---
type: plan
title: 待辦與遞延項目（含 Kubernetes 轉移判定）
description: "Deferred work with an explicit verdict on whether each item should be built on Compose now or waited out until the Kubernetes substrate arrives."
tags:
  - backlog
  - planning
  - kubernetes
timestamp: 2026-08-18T11:05:00+08:00
---

# 待辦與遞延項目

記錄未完成的項目，以及**每一項是否該現在做**。

理由：`Plan.md` 的 P3 是 Kubernetes adapter，而 K8s 已經從「未來某天」變成
「很快就有的專案」。有些遞延項目在 K8s 上會被整個換掉，現在投入等於做兩次；
有些則與底層無關，現在做的成果 100% 帶得走。**分辨這兩者，比排優先序更要緊。**

## 判定摘要

| # | 項目 | 轉移到 K8s | 現在做？ |
|---|---|---|---|
| 1 | Vault 動態資料庫憑證 | ✅ 完全轉移 | **現在做** |
| 2 | station2-twin 接進 blue/green | ⚠️ 判定 2026-08-21 改變 | **A9 完成後接著做**（在 K8s 上，不在 Compose） |
| 3 | DAST form-aware profile | ✅ 完全轉移 | **現在做** |
| 4 | station2-twin 的 ingress ceiling | ⚠️ 政策轉移、實作不轉移 | 只寫政策 |
| 5 | 異地備份（Google Drive） | ✅ 與底層無關 | 待使用者決定 |
| 6 | 測試資料管理 + redaction v2 | ✅ 完全轉移 | 真實醫療資料前必須 |

---

## 1. Vault 動態資料庫憑證 — 現在做

**✅ 已完成（2026-08-19）。** `platform/vault/scripts/setup_database_secrets.sh`
建立 database secrets engine、`workload-station2-twin` policy 與 AppRole；
`verify_database_secrets.sh` 6 項斷言全過，關鍵一項是**被撤銷的憑證確實會被
postgres 拒絕**——不是「Vault 說它撤銷了」。station2-twin 目前
`/health/ready` 回報 `credentials.mode = vault`，使用者名稱形如
`v-approle-station2-...`，TTL 3600 秒。

當初保留接縫的那個 policy 檔（`workload-station1-hello.hcl`）已隨 pilot 退役
刪除；證明「換的只是路徑，不是身分模型」這件事的測試改由
`workload-pilot-fixture` 承擔——一個**具名的測試夾具**，不是服務。

**為什麼現在做**：Vault 的 database secrets engine 設定（connection、role、
TTL、revocation）與底層無關。K8s 上改變的只有「憑證怎麼送進 Pod」
（Vault Agent Injector / External Secrets Operator / CSI driver），
**Vault 這一側一行都不用改**。這是少數現在做、之後原封不動帶走的工作。

## 2. station2-twin 接進 blue/green — 判定已於 2026-08-21 改變

**原判定（station1-hello 還在時）：不要投入。** 理由是產出的 Compose blue/green
機制不會被帶到 K8s。那個理由**現在仍然成立**——但前提變了：A9 已完成，
K8s 底座就緒（`platform/k8s/verify_cluster.sh` 8/8），所以現在做 blue/green
不必在 Compose 上補一次，直接在 K8s 上用 Deployment 做。

使用者 2026-08-21 定序：**A9 先，A10 後**。下一步是拆 station2-twin 的
db/app compose（讓兩個顏色共用同一個資料庫，那正是 expand/contract 紀律存在的理由），
然後在 K8s 上驗證真實顏色切換。

以下為原判定，保留供對照：

### 原判定

**2026-08-19 補充：station1-hello 退役後，blue/green 現在沒有任何目標 Pilot。**
station2-twin 接不上的原因是具體的，不是抽象的：它的 `compose.yaml` 把
`db` 與 `twin` 綁在同一份檔案，第二個顏色會嘗試在同一個 host port (15432)
啟動第二個 postgres、掛同一個具名 volume `station2-twin-db`。要接上就得把
資料庫層與應用層拆成兩份 compose，讓兩個顏色共用同一個資料庫——那正是
expand/contract migration 紀律存在的理由。

依下面的判定，這件事**不做**：拆分本身要改動一個正在運作的 Pilot，而產出的
機制不會被帶到 K8s。相關的東西已據實移除而非假裝存在——Prometheus 沒有
production-like 的 scrape job（否則兩個目標會永遠紅），告警規則沒有
`sum() over colours` 的規則（否則是虛構），`recover.sh` 沒有選顏色的分支
（否則是假裝成安全機制的死程式碼）。

`platform/compose/deploy.sh` 的 blue/green 是 Compose 專屬實作。K8s 用
Deployment rolling update，或 Argo Rollouts 做真正的漸進式發布。**這段
實作不會被帶走。**

值得注意的是：真正該被保護的東西**已經證明有效了**——station2-twin 在
schema 不符時拒絕 readiness，實測 503 `schema_mismatch`。那個保護機制本身
是與底層無關的，而且在 K8s 上會更強（readiness 失敗直接把 Pod 移出 Service
endpoints）。所以「還沒經過真實顏色切換」這個缺口，等 K8s 上用 Deployment
驗證即可，不必為 Compose 再補一次。

## 3. DAST form-aware profile — 現在做

station2-twin 的 `POST /twin/<asset>/observation` 是這個平台上第一個吃 JSON
body 的寫入端點，也是第一個值得用 form-aware profile 掃的目標。

**為什麼現在做**：ZAP 掃的是 HTTP 端點，與跑在 Compose 還是 K8s 無關。
掃描設定、規則集、掃描完整性檢查（`site` 條目而非 alert URL）全部帶得走。

## 4. station2-twin 的 ingress ceiling — 只寫政策

**✅ 政策已寫入（2026-08-19）。** `targets.conf` 現有
`station2-twin|18090|tailnet`。它**沒有**繼承 station1 的 `funnel` ceiling：
資料本身是公開資料、發布出去無害，但**服務**是一條沒有自身速率限制、
不需認證就能讀的活資料庫路徑，readiness 還會洩漏 schema 狀態。
公開資料是「做一份匯出」的工作，不是「把持有資料的伺服器暴露出去」的理由。

**判定**：把 ceiling 與理由寫進 `targets.conf`（政策），但不要為它擴充
Tailscale 實作。政策本身——「可暴露到什麼程度，由『它靠什麼驗證』決定，
不由名字聽起來多敏感決定」——在 K8s 上直接變成 NetworkPolicy（預設拒絕）
+ Ingress + admission policy（OPA/Kyverno）。**規則轉移，`tailscale serve`
的呼叫不轉移。**

## 5. 異地備份 — 待使用者決定

機制已完成並雙向驗證（拒絕非 crypt remote、上傳前加密探測）。使用者已表示
「保留討論」，pending 授權已取消，`offsite` job 持續誠實回報
`not-configured`（黃燈）。與底層無關，K8s 上改用 Velero 也仍需要一個異地
目的地決策。

## 6. 測試資料管理 + redaction v2 — 真實醫療資料前的硬性前提

尚未開始。目前 Alloy 的寫入時遮蔽（台灣身分證、email、token 前綴）是
**緩解措施，不是保證**。在任何真實 CYCH 資料進入這個平台之前必須完成。

與底層無關；K8s 只會讓它更必要（多 namespace、多租戶、Kubeflow notebook
可以直接讀 PVC）。

## 7. 中醫大個人級 + 醫院級資料 — 預測準確度的下一層，但有硬前提

**使用者 2026-08-19 明確要求記錄**：目前的 %ILI 預測只用得到總體開放資料，
天花板是生態層級推論——說得出「台中市這週會怎樣」，說不出「哪一群人、
哪一家醫院會先滿載」。中醫大的個人級與醫院級資料會顯著改善，但它改變的
**是問題的種類，不是特徵的數量**：

- 現有特徵全是**縣市級落後指標**（開放資料落後約 2 週）。醫院級就診量是
  **同期指標**；個人級（年齡、共病、就醫史）讓模型從生態層級升到個體層級。
- 用縣市級特徵預測鄉鎮或醫院層級是**生態謬誤**，等於假設縣內同質。

**進入前必須完成，不可跳過**：

1. 上面 §6（測試資料管理 + redaction v2）。目前 Alloy 的寫入時遮蔽是緩解
   措施不是保證。
2. 流行病學週 ↔ 日曆日的對應查證（`docs/Spark-Design.md` §6）。目前
   `time_period` 有 1,024 個 epi_week 期間，`cal_date` **全為 NULL**，
   所以週資料與日資料無法在時間軸上 join，中醫大資料送來時會對不上。
3. `data_source.is_synthetic` 與 `platform.data_class` 標籤必須能區分真實
   醫療資料與合成／開放資料，否則會混進同一個 Loki tenant。

## 8. RODS 家族的 metric 過度指定 — 已知，刻意未修

migration 012 把 NHI 家族的 `ili_visits` 改成 `nhi_visits`，理由是疾病已經
由 `disease_id` 表示，編碼兩次會允許 `metric=covid_visits AND
disease=enterovirus` 這種 schema 擋不住的無意義列。

**RODS 家族有完全相同的問題**（`ili_ed_visits`，7 種疾病同一結構），但沒有
一起修，原因具體：**應用程式讀 `ili_ed_visits`**（`app/surveillance.py:72`），
所以那是應用程式變更不是資料變更，要連同 `MODELS` registry 一起改。
記在這裡而不是默默做一半。

RODS 家族尚未載入的 6 個 feed（腹瀉、結膜炎、COVID-19、腸病毒、手足口病、
疱疹性咽峽炎）等這件事決定後再一起處理，否則會用錯的 metric 形狀載進去。

## 9. 簡報用的八張圖 — 待完成

`docs/Platform-Report.html` 是第一版，使用者評「品質不差，但我還不滿意」。
缺的是**結構**：三層混在一張圖裡，各層沒有自己的圖。指定要補的八張，
**配色由使用者指定，不要自行更換**：

| # | 圖 | 顏色 |
|---|---|---|
| 1–2 | DevOps 架構 / 流程 | 藍 |
| 3–4 | DataOps 架構 / 流程 | 綠 |
| 5–6 | MLOps 架構 / 流程 | 棕 |
| **7** | **大統整流程圖** | 三色分段 |
| **8** | **大統整架構圖** | 三色分段 |

7、8 是使用者特別強調的重點。目的是**報告長官**，所以每張圖要能單獨看懂。

畫法：先安裝 `cathrynlavery/diagram-design`（MIT / v2.5.20 / 23.7k star，已查證
skill 只帶 drawio_extract、mermaid_extract、self_check 三支解析器，無網路與系統存取）。
**安裝是 Claude Code 互動指令，AI 跑不了**，需使用者自行輸入：

```
/plugin marketplace add cathrynlavery/diagram-design
/plugin install diagram-design@diagram-design
```

它能重畫 draw.io 與 Mermaid，所以 `docs/Spark-Design.md` 的 flowchart 與
`platform/statusdag/dag.py` 的輸出可以直接接進去，不必手繪 SVG。

第 3 節列的三條斷層（週定義、中醫大前提、K8s）經使用者確認為**已知且刻意延後**，
不是遺漏；補齊時一併更新該頁。

---

## 已知但尚未排期的技術債

- **`platform/compose/deploy.sh` 629 行**，混合了 build / deploy / promote /
  rollback 四種職責。若確定要轉 K8s，**不要重構它**——那是即將被取代的程式碼。
- **`dag.py` 自訂 schema**：曾提議改輸出 Backstage `catalog-info.yaml`，
  以 mermaid 當薄渲染層。K8s 上這件事的價值更高（Backstage 是 CNCF 生態的
  service catalog 標準），但同樣建議等底層確定後一次做對。
- **`docs/presentation/`（PPTX）仍未納入 git**，待使用者決定。
- **scheduler 的日曆觸發**：2026-08-18 03:00 是第一次真實 `StartCalendarInterval`
  觸發。在確認 `status.sh` 的 SCHEDULE 欄位由 `NEVER FIRED` 轉為 `fired`
  之前，整個排程機制仍屬 UNVERIFIED。K8s 上這些會變成 CronJob。

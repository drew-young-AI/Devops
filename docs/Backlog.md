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
| 1 | Vault 動態資料庫憑證 | ✅ 完全轉移 | ✅ **已完成 2026-09-01**（K8s 那份副本也轉成 vault；剩 secret zero，見下） |
| 2 | station2-twin 接進 blue/green | ⚠️ 判定 2026-08-21 改變 | ✅ **已完成 2026-08-25**（K8s Deployment + Service selector；已接進 run_all.sh 第 3 層） |
| 3 | DAST form-aware profile | ✅ 完全轉移 | ⚠️ **目標已修好（2026-08-25），form-aware profile 仍待做** |
| 4 | station2-twin 的 ingress ceiling | ⚠️ 政策轉移、實作不轉移 | ✅ **政策已在 K8s 強制執行（2026-08-26）** |
| 5 | 異地備份（Google Drive） | ✅ 與底層無關 | 待使用者決定 |
| 6 | 測試資料管理 + redaction v2 | ✅ 完全轉移 | 真實醫療資料前必須 |
| 10 | 三把秘密沒有輪替紀錄 | ✅ 與底層無關 | **等使用者決定**（會動到活憑證） |
| 11 | 憑證輪替自動化 | ✅ 與底層無關 | 分層：Grafana 先做，ghcr 要先實測 |
| 12 | Docker → k3d 搬遷準則 | — | ✅ **前提已解除（2026-08-26）**：備份鏈已吃 PVC |

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

### 2026-09-01 補記：K8s 那份副本也轉過去了

上面那段寫於 2026-08-19，講的是 **Compose 那份**。K8s 那份直到 2026-09-01
都還帶著這行：

```yaml
- { name: PGPASSWORD, value: "twin-bootstrap" }
```

明文、共用、不過期、沒有撤銷路徑——而**要被推上生產的，正是憑證模型比較弱的那一份**。
兩份副本貼上不同 `environment` 標籤，本來就是為了讓分歧看得見；看見了卻不收斂，
只是把同一個失效往後推一步。

現在的狀態：

| | Compose（develop） | K8s |
|---|---|---|
| `credentials.mode` | `vault` | `vault` |
| 使用者 | `v-approle-station2-ESr7...` | `v-approle-station2-VfIa...` |
| lease | 各自獨立，TTL 1200s | 各自獨立，TTL 1200s |

做法：AppRole 以 k8s Secret 送進 Pod（`sync_vault_secret.sh`，由 `deploy.sh` 自動呼叫），
manifest 不再有任何密碼。**刻意不保留 static fallback**：Vault 連不上時 Pod
readiness 失敗、被移出 Service endpoints，藍綠因此無法把一份「拿不到憑證」的副本推上線。
悄悄退回共用密碼的 Pod，和拿到 lease 的 Pod，外觀完全相同——那才是要避免的。

**default-deny egress 抓到了這件事。** 移除靜態密碼後 Pod 起不來，錯誤是
`Vault unreachable ... Connection refused`——這正是預設拒絕遇到新相依時該有的樣子：
在邊界上被擋下並且說得出名字，而不是一個安靜地能動、也安靜地比任何人以為的更寬的服務。
授權方式是新增一條獨立的 `allow-host-vault`（/32＋單一 port），不是在
`allow-host-postgres` 上加一個 port——政策的名字必須還能描述它准了什麼。

**還沒解決的：secret zero。** AppRole 的 `secret_id` 現在放在 k8s Secret 裡，
那是 base64、不是加密，namespace 內有 `get secrets` 權限的人都讀得到。
這件事的性質是：把「共用、永不過期的資料庫密碼」換成「範圍受限、可撤銷、可輪替的
啟動憑證，且它只能用來換取短期資料庫憑證」——是**爆炸半徑變小，不是歸零**。

終局是 Vault 的 `kubernetes` auth method：Pod 的 ServiceAccount token 本身就是身分，
完全不必配發任何 secret。它需要動到 pilot 應用（在 AppRole 之外多一條登入路徑）
與叢集的 token reviewer 綁定，所以列為下一步而不是在這裡做一半。

守衛：
- tier 1 `test_static.sh` — 任何 k8s manifest 都不得指派字面憑證值（突變驗證過）
- tier 3 `test_migration_observed.sh` — 兩份副本的 `credentials.mode` 必須相同，
  且 K8s 那份必須是 `vault`（只比對 mode 不比對使用者名稱：使用者名稱本來就該不同）
- tier 3 `test_bluegreen.sh` — 8/8 仍通過，含 green，證明兩個顏色都拿得到 Secret

## 2. station2-twin 接進 blue/green — ✅ 已完成 2026-08-25

**完成狀態**：`platform/k8s/station2-twin/`（`promote.sh` 四道閘門、
`test_bluegreen.sh` 8/8、已接進 `platform/tests/run_all.sh` 第 3 層）。
實測 blue → green → blue，回滾 0.72 秒。細節見 `Plan.md` 的 2026-08-25 補記。

以下為判定過程，保留供對照：

### 判定已於 2026-08-21 改變

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

## 3. DAST form-aware profile — 目標已修好，profile 仍待做

**2026-08-25 修好的是「掃描目標」，不是 profile。** DAST job 之前每天紅，
訊息是「Is the develop deployment up?」——指向一個**已經退役好幾天**的部署
（station1-hello 的 nginx develop vhost，18443）。compose 仍然 publish 8443，
所以失敗長成最會誤導人的形狀：**TCP 連得上、TLS 握手直接斷**
（`SSL_ERROR_SYSCALL`）。port 有回應，後面沒有東西。

已改指向 station2-twin 真實的 HTTP 介面（`http://host.docker.internal:18090`）。
首次實掃：**DAST PASS，HIGH=0 MEDIUM=0 LOW=1**（`Server` header 洩漏版本，
x2），閘門設在 MEDIUM。

**仍待做**：station2-twin 的 `POST /twin/<asset>/observation` 是這個平台上第一個
吃 JSON body 的寫入端點。ZAP baseline 只做 spider + passive（GET），**不會碰
這個端點**，所以目前那條寫入路徑等於沒掃。要掃它需要 form-aware / API profile
（餵 OpenAPI 或 context file）。順帶一提，掃寫入端點前要先想清楚它會不會把垃圾
observation 寫進那個 650 萬列的資料庫。

**為什麼現在做**：ZAP 掃的是 HTTP 端點，與跑在 Compose 還是 K8s 無關。
掃描設定、規則集、掃描完整性檢查（`site` 條目而非 alert URL）全部帶得走。

## 4. station2-twin 的 ingress ceiling — ✅ 政策已被強制執行（2026-08-26）

當初的判定是「規則轉移、`tailscale serve` 的呼叫不轉移」。**那次轉移做完了。**

`platform/k8s/station2-twin/networkpolicy.yaml`：namespace 預設拒絕進出，
然後只開三條——DNS、`192.168.65.254/32:15432`（共用的那個 postgres）、
8080 進入。`targets.conf` 裡的 ceiling 是一段沒人強制的散文；這裡是**網路真的
拒絕做的事**。Compose 給不出等價物，同一個 network 上的容器永遠互相可達、
也永遠連得到外網。

**強制力是量出來的，不是假設的。** NetworkPolicy 跑在一個不理會它的 CNI 上，
比沒有更糟：manifest 讀起來像控制、`kubectl get netpol` 列得出來、而沒有任何封包
被擋。`verify_networkpolicy.sh` 每次都先在拋棄式 namespace 套一個 deny-all，
確認 pod 真的失去網路（open → closed），**再**去驗 station2 的策略——
否則底下每一條都可能在一個什麼都沒擋的叢集上通過。

實測 5/5：CNI 確實強制、4 條策略在位、app 仍讀得到資料庫、Service 仍有 endpoint、
**app 連不出公網**。最後一條是唯一有內容的：前面幾條在一個完全沒有策略的
namespace 裡也一樣會過。

順帶抓到一件事：策略套下去之後**要時間傳到每個節點的 iptables**。第一次探測回
`UNREACHABLE`，幾秒後同一個探測就成功。等待從 5 秒改成 15 秒——把傳播延遲當成
測試失敗，是教會所有人「紅了就再跑一次」最快的方法。

以下為原判定，保留供對照：

### 原判定

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

## 9. 簡報用的八張圖 — ✅ 已完成 2026-09-01

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

### 2026-09-01 完成，且沒有裝那個 plugin

**駁回原本的前提。** 上面寫「先安裝 `cathrynlavery/diagram-design`」，
但那個 skill 的用途是**重畫既有的 draw.io / Mermaid**，不是畫圖的必要條件。
Artifact 原生就會渲染 Mermaid，所以八張圖直接寫成 Mermaid 即可——
把一個「使用者必須自己輸入互動指令」的步驟當成前置條件，
只會讓這件事無限期卡住，而它本來就不必卡。

八張圖，配色照指定（DevOps 藍 / DataOps 綠 / MLOps 棕 / 7、8 三色分段）：

| # | 圖 | 這張圖單獨回答什麼 |
|---|---|---|
| 01 | DevOps 架構 | 這條線由哪些東西組成，誰依賴誰（四層） |
| 02 | DevOps 流程 | 一次變更從程式碼到上線經過哪些關卡，哪些擋得住 |
| 03 | DataOps 架構 | 資料存在哪裡、以什麼形態存（單點 vs 欄式） |
| 04 | DataOps 流程 | 一批資料進來後依序發生什麼，哪一步是前提 |
| 05 | MLOps 架構 | 有哪些成品，各自被什麼綁定（`code_sha256`） |
| 06 | MLOps 流程 | 一次重訓要通過什麼才能對外，現在卡在哪 |
| 07 | 大統整流程圖 | 三條線接起來，跨過哪兩個交界 |
| 08 | 大統整架構圖 | 同一個系統換成分層看，誰站在誰上面 |

**節點與連線全部取自 `platform/statusdag/dag.py` 的 `LINES` 與 `EDGES`**，
不是示意圖——圖上任何一個方塊，都對得到板面上一個會自己變色的節點。
現況數字（15 條規則、8,059 行政區、6.5M 列、9 次回測、t+1 −12.31%）
同樣取自板面實際探測。

**驗收方式不是「看起來對」**：把八段 Mermaid 抽出來，用 `mermaid.parse()` 加
`mermaid.render()` 逐張跑過，八張全部通過並回報節點數
（12 / 13 / 8 / 7 / 8 / 7 / 15 / 18）。順帶抓到驗證頁自己引用了一個
**cdnjs 上不存在的 mermaid 版本**（11.4.1 → 404）——和 trivy-action
那個從未存在的版本是完全同一種缺陷，改釘實測 HTTP 200 的 11.6.0。

產物：Artifact「三線平台圖譜」（私有連結，可自行分享）。

第 3 節列的三條斷層（週定義、中醫大前提、K8s）經使用者確認為**已知且刻意延後**，
不是遺漏；補齊時一併更新該頁。

## 10. 三個秘密沒有輪替紀錄 — 需要使用者決定，AI 不代決

`rotation` job 現在會真的檢查了（2026-08-25 前它每次都以 bash usage error 收場，
**訊息裡從來沒提過秘密**）。第一次真掃的結果是紅的，而且是**真的紅**：

| 路徑 | 狀態 |
|---|---|
| `secret/devops/ghcr` | 無 `rotated_at` 紀錄 |
| `secret/devops/github` | 無 `rotated_at` 紀錄 |
| `secret/devops/grafana-admin` | 無 `rotated_at` 紀錄 |

**為什麼停在這裡不自己做**：這三把是活的憑證。轉 `secret/devops/github`
（git PAT）會直接弄壞 push；`ghcr` 會弄壞 image 推送。這是外部後果，不是本機
重構，該由使用者決定時機。

**另一條路不要走**：`check_rotation_due.sh` 的檔頭提到 `rotated_at` 可以
「manually set for secrets migrated but not yet rotated by this tooling」。
手動蓋一個日期會讓板子變綠，但那是**寫下一個沒人驗證過的宣稱**——正是這個專案
一路上重複踩的那個坑。寧可紅著。

兩個選項：
1. `platform/vault/scripts/rotate_secret.sh <path>` 逐一真的轉（會需要同步更新
   GitHub / GHCR / Grafana 那一側）。
2. 明確決定某幾把不納入 90 天政策，並把理由寫進 policy，而不是讓它一直紅。

## 11. 憑證輪替自動化 — 分層，不是一句「能不能自動」

2026-08-25 查一手文件後的結論。**能不能自動取決於「誰能發新憑證」，不是腳本寫不寫得出來。**

| 憑證 | 能否全自動 | 機制 |
|---|---|---|
| 資料庫憑證 | **已經是了** | Vault database secrets engine（A5/A6 已實證，撤銷後 postgres 確實拒絕） |
| `devops/grafana-admin` | **可以** | Grafana 有 API；`setup_grafana_identity.sh` 已會寫 Vault，只差排程 |
| `devops/github` | **可以** | 換成 **GitHub App**：私鑰簽 JWT → `POST /app/installations/{id}/access_tokens` → **1 小時** token，可程式化重簽，零人工（GitHub 官方文件確認） |
| `devops/ghcr` | **⚠️ 未查證** | 官方文件寫死：「GitHub Packages only supports authentication using a personal access token (classic)」。GITHUB_TOKEN 在 Actions 內可用（它本身就是 installation token），但**自架 App 的 token 能不能推 ghcr.io，文件沒寫** |

**ghcr 那格不准假設。** 這個專案已經被同一種假設咬過一次——以為 fine-grained PAT
勾對權限就能推 GitHub Packages，實際上官方文件說完全不支援（見 `Plan.md` Registry
promotion 段）。要走 GitHub App 必須先實測，不能照推理。

**同一把憑證住兩個地方**：Vault 一份、macOS keychain 一份，而 `git push` 讀 keychain
不讀 Vault。真正的輪替是「在 GitHub 上撤銷舊的」——撤銷那一刻，沒同步更新的那一份就死。
輪替腳本必須同時處理兩邊，否則會在最不該壞的時候壞。

建議順序：Grafana（純本機、零外部依賴）→ GitHub App 換掉 `devops/github` →
ghcr 先實測再決定。

## 12. Docker → k3d 的搬遷準則（2026-08-26 定案）

使用者問「聽起來是幾乎都可以移轉，是的話就通通移轉」。**不是。** 分兩層，
而且分界線不是偏好，是一個可以當場示範的技術事實。

### ✅ 阻擋條件已解除（2026-08-26）

原本的阻擋是備份鏈看不見 PVC。**那條已經補好了**：

- `backup.sh` 現在同時列舉 docker volume **與** `kubectl get pvc -A`，三選一規則相同
  （備份 / 邏輯 dump / 記錄理由排除），少一個就 rc≠0。
- `pvc_archive.sh` 以**釘在該節點**的 pod 唯讀掛載 PVC 打包。node affinity 不是可選項：
  local-path 是 RWO 且實體綁在單一節點，排到別的節點不會拿到空的 volume，
  而是**卡 Pending 或另外開一個空目錄然後打包出一個空檔**——
  一個 digest 完全正確、內容什麼都沒有的備份，是最糟的那種。所以小於 100 bytes 直接拒收。
- 匿名 volume 那條規則（64 位十六進位＝docker 暫存）**現在對 k3d 節點 volume 不適用**。
  它們只有在「PVC 列舉真的跑成功」時才被豁免——因為豁免的理由就是「裡面的資料已由上面
  逐 PVC 覆蓋」，列舉不到就沒有這個理由。
- 叢集連不上時：靠 `evidence/backup/last_known_pvcs.txt` 分辨「本來就沒有 PVC」與
  「有 PVC 但現在看不到」。後者一律 rc≠0——「叢集當時關著」半年後會變成
  「那個資料庫從來沒被備份過」。
- `restore_drill.sh` 多一段：把 PVC 封存**還原進拋棄式 PVC 並讀回內容**。
  完整性檢查看不出空封存，只有放回去看才看得出來。

**實測**（`platform/tests/test_backup_coverage.sh`，已進 run_all 第 3 層，0.4 秒／次）：

| 狀態 | 結果 |
|---|---|
| 乾淨 | PASS |
| 有未分類 PVC | **拒絕，並指名是哪一個** |
| 叢集關閉、從未有過 PVC | PASS，並印出它假設了什麼 |
| 叢集關閉、曾經有 PVC | **拒絕** |
| 叢集關閉時 k3d 節點 volume | **失去豁免** |

端到端也走過一次：建一個 200KB 的測試 PVC → 備份（釘節點打包）→ 進 manifest 帶 digest
→ 還原演練驗 digest → 還原進拋棄式 PVC → 讀回 2 檔 200,014 bytes，14 passed 0 failed。

**過程中抓到兩個自己的 bug**：PVC 區塊原本寫在 manifest 產生**之後**，
所以封存檔躺在目錄裡卻沒進 manifest——沒有 digest、還原演練不會檢查、還原時不知道它存在
（是還原演練回報「這份備份沒有 PVC 封存」時抓到的，而檔案就在旁邊）。
另一個：空陣列 `printf '%s\n' "${arr[@]}"` 仍會寫出一個換行，`[ -s ]` 判成非空——
於是一個完全沒有 PVC 的叢集被記成「有 1 個」，關掉叢集就擋住備份。
一個每次筆電關叢集就亮的紅燈，是沒有人會持續反應的紅燈。

### 原本的阻擋理由（保留供對照）

**理由是備份，不是記憶體。**

k3d 的 PVC 由 local-path-provisioner 寫在節點的 `/var/lib/rancher/k3s/storage`，
而那條路徑掛的是一個**匿名 docker volume**（實測 `b397a64fd0a7...`，64 位十六進位名）。

`platform/backup/backup.sh` 對這種名字有一條明確規則：

```bash

# Anonymous volumes are docker's own scratch (64-hex names), not state

# anybody chose to keep.

case "$vol" in [0-9a-f]*) [ "${#vol}" -ge 64 ] && covered=1 ;; esac

```

也就是說，**今天把 postgres 搬進 k3d，資料會落在一個備份腳本明文歸類為
「docker 自己的暫存、沒人想留」的 volume 裡，而備份仍然回報 PASS。**
A8（備份覆蓋率不得有漏）與還原演練會同時失效，而且是**安靜地**失效——
那正是這個平台一路在對付的失敗形狀。

要搬這一層，得先重寫備份／還原鏈去理解 PVC。那是一件獨立的工作，不是搬遷的副作用。

### 要搬：工作負載、政策、批次

| # | 項目 | 為什麼是純收穫 |
|---|---|---|
| 1 | ingress ceiling → NetworkPolicy | ✅ **已完成**（見 §4）。Compose 做不出預設拒絕 |
| 2 | `ingest` 批次 → k8s Job | 批次天生就是 Job；順帶示範資源限制與重試 |
| 3 | scheduler → CronJob | 示範企業級排程語意——**但不解決睡眠問題**（見下） |

**第 3 項要講清楚**：k3d 跑在同一台筆電的 Docker 裡，筆電睡著時 CronJob 一樣不觸發。
它換到的是排程語意與可觀測性，不是修好那一夜 15 次錯過。把它當成「搬過去就不會漏跑」
會是下一個「註解描述了一個機制」。

---

## 13. Ubuntu 生產節點 — 進行中，暫停於機器休眠（2026-08-31）

叢集已建好並從 Mac 驗證可達，隨即失聯（SSH 與 6443 逾時，網卡仍回應 ARP＝休眠）。
完整狀態與接手順序見 [`Ubu-Prod-Bringup.md`](Ubu-Prod-Bringup.md)。

| 項目 | 狀態 |
|---|---|
| k3s 單節點 + kubeconfig context `ubu` | ✅ 已完成，`platform/k8s/bootstrap_k3s.sh` 可重跑 |
| 停用休眠、固定 IP | ⬜ **必須先做**，否則 `prod` 只是名字 |
| amd64 建置鏈 | ⬜ 待 GitHub/GitLab CI 方案定案（見 [ADR-0008](decisions/0008-two-machines-two-architectures.md)） |
| Vault（兩台都放，使用者決定） | ⬜ ubu 上尚未安裝 |
| pilot 上 prod | ⬜ 需同時修 Vault 憑證與 Prometheus scrape 兩個缺口 |

---

## 14. CI 紅了六天沒人知道 — ✅ 機制已補（2026-08-31）

GitHub Actions 最近 20 次有 13 次紅，最近一次成功在數週前，**沒有任何人被通知**。
成因不是通知鏈壞掉——Alertmanager、Telegram、板面全都正常——而是**遠端 CI 的狀態
從來沒有進入任何一條通知路徑**。

已做：

- 4 個 macOS↔Linux 可攜性缺陷修掉（`stat -f`、`mktemp -t`、`scutil`、
  `ingress.sh` 的檢查順序），全部在真的 GNU coreutils 容器裡驗證過
- `run_all.sh` 加入呼叫端明示的分層（`PLATFORM_TIERS`），雲端只跑 tier 1
- 燈號板新增 `gha` 節點；`platform/ci/fetch_gha_status.sh` 排程抓取寫成證據

通道也補了（2026-09-01）：

- `platform/observability/prometheus/alerts/platform-nodes.yml` —— `dag.py` 匯出
  `devops_node_state` 已數週，**沒有任何規則消費它**。節點紅了只有打開網頁的人看得到。
  現在 `PlatformNodeFailed` 會在紅超過兩個評估週期後發 Telegram。
- `PlatformBoardStale` 守著上面那條：node-exporter 會繼續提供最後讀到的 textfile，
  所以 `dag.py` 停掉之後每個節點指標會**凍結在最後一個值**——凍結的綠燈和健康的綠燈
  長得一模一樣。
- 兩條規則都以**評估**驗收（`/api/v1/rules` health=ok），不是以 `promtool` 通過驗收
  （[ADR-0007](decisions/0007-verify-by-evaluation.md)）。`PlatformNodeFailed` 目前
  pending，帶著 1 個 alert：`gha`。

板面現在說的是：**`GitHub Actions: main failure，最近 10 次有 10 次紅`。**

仍待做：**尚未推送，所以 GitHub 上的 CI 仍是紅的。** 修正只在本機與 Linux 容器裡
驗證過（tier 1 全綠、本機全三層 ALL SUITES PASSED）。推送之後才會知道雲端是否轉綠。

---

## 15. K8s 那份 pilot 沒被監控 — ✅ 已修（2026-09-01）

不是漏設 scrape config，是**通路根本不存在**：K8s 副本掛在 ClusterIP，而 k3d 只對外
開 6443，所以 Prometheus 在原理上就抓不到它。Prometheus 有兩個 target，遷移過去的
副本兩個都不是。

`pilots/README.md` 記過同一個缺陷（station1-hello 退役時，監控留在已退役的那份）。
**這次是角色對調的同一個缺陷。**

| 動作 | 檔案 |
|---|---|
| NodePort 30890 → 主機 18091，帶與流量 Service 相同的 `color` selector | `platform/k8s/station2-twin/metrics-service.yaml` |
| `promote.sh` 同一步搬動 metrics Service 並回讀驗證 | `platform/k8s/station2-twin/promote.sh` |
| scrape job `station2-twin-k8s`，`environment=k8s` | `platform/observability/prometheus/prometheus.yml` |
| 守衛：部署的東西與被監控的東西必須對得起來 | `platform/tests/test_migration_observed.sh` |

兩個斷言都親手弄紅過再還原（顏色錯置、無人監控的工作負載），還原都經過驗證。

**仍看不到的**：閒置顏色。綠色部署在 promote 之前壞掉，從叢集外看不出來。
正解是 Prometheus 進叢集用 `kubernetes_sd_configs`——那是 amd64 生產叢集該有的東西。

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

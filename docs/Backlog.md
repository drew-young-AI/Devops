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

## 只有使用者能解的阻塞項（2026-09-03 盤點）

這一節存在的理由：這些項目在每次對話裡被口頭提起、然後隨對話消失。
**口頭提起不是紀錄。** 它們全部不是技術問題——是需要人做決定或人親自執行的事，
agent 做不了也不該替使用者決定。

| # | 阻塞的是什麼 | 為什麼 agent 不能自己做 | 解除後可以做什麼 |
|---|---|---|---|
| B1 | 異地備份目的地未指定 | 要選一個實體位置或雲端帳號，並在瀏覽器完成 OAuth 授權 | `sync_offsite.sh` / `sync_remote.sh` 從 `not-configured` 轉為真的有第二份 |
| B2 | 三把秘密尚未真正輪替 | 會動到**活的**憑證，輪錯就是自己把自己鎖在外面 | §10 從「閘門會判斷」變成「輪替真的發生過」 |
| B3 | Grafana 憑證輪替排程未定 | 要決定週期，且輪替會改變使用者自己的登入方式 | §11 第一層落地 |
| B4 | `zhe0@hotmail.com.tw` 的 app password | 密碼類憑證只能由使用者本人取得與輸入 | 郵件通知從 local-only 變成真的送得出去 |
| B5 | `docs/presentation/` 的 PPTX 是否納入 git | 是使用者的簡報檔，納不納入是他的決定 | 簡報產物有版本 |
| B6 | Google API key 輪替 | 同 B2，動到活憑證 | 憑證盤點的最後一格 |
| B7 | ~~ubu 主機尚未上線~~ **2026-09-03 已上線**；剩兩件需要你操作：停用休眠（ubu 上沒有免密碼 sudo）與固定 IP（路由器保留位址） | 停用休眠與改路由器都需要 root／實體存取 | 會休眠的筆電不是生產主機；固定 IP 是為了診斷與 mDNS 失效時的退路，**不是**為了 kubeconfig（見 §26） |
| B8 | 八張圖「有些細節要調整」，細節未指定 | 只有使用者知道要調哪裡；配色由使用者指定不可自行更換 | 圖定稿 |
| B9 | 這一輪的修正尚未 commit | `CLAUDE.md` 明訂未經明確指示不得 commit / push / 開 PR | 這一輪的所有修正才會進入歷史 |
| **B10** | **Telegram bot token 已外洩到日誌，需要輪替** | 只有使用者能對 BotFather 執行 `/revoke`；agent 不得建立或輪替憑證 | 這條通知鏈才重新可信；同時要決定既有 Loki 資料怎麼處理 |

**B10 是唯一有時效性的一項**，詳見 [§22](#22-telegram-bot-token-經由錯誤路徑外洩到日誌2026-09-03-發現)。
**B9 是其中唯一會讓其他所有工作歸零的一項。** 目前所有修正只存在於工作目錄。

---

## 未來要做的（已記錄，刻意不現在做）

一步一步來的意思是**知道下一步是什麼**，不是忘記還有下一步。完整理由各見章節：

| 何時做 | 項目 | 觸發條件 |
|---|---|---|
| ~~K8s 部署路徑穩定後~~ **已完成 2026-09-03** | [§16](#16-價值流看板收不到部署證據--已修2026-09-03) 看板收不到部署證據 | k8s deploy 現在會寫 `deploy_develop_<sha>.json`；`starved: false` |
| 使用者決定成本後 | [§17](#17-八張圖回到板面上單一來源內嵌-svg) 板面內嵌圖 | 需 ~150 MB Chromium；**不准手繪第二套** |
| 服務數量到位後 | [§18](#18-追蹤traces三個前提依序不可跳過) 追蹤 | 三個前提依序，遮蔽優先於接收 |
| 第二個 pilot 或首次遇到上游停發 | [§19](#19-執行了但沒有效果重訓在沒動過的資料上看起來和真的一樣) 空抓取偵測 | 正確位置是 `pipeline_metrics.py` |
| ~~下一個做的就是這個~~ **已完成 2026-09-03** | [§21](#21-磁碟沒有被量2026-09-03-完成) 主機磁碟監控 | 插隊到 §20 前面，因為它已經發生過一次並停掉整個平台 |
| ~~下一個做的就是這個~~ **已完成 2026-09-03** | [§20](#20-五支來源永久紅--已修2026-09-03但原因不是門檻) 五支來源永久紅 | 修法不是門檻是排程：23 支全部 ≤ 0.29 天 |
| 後端要換的那天 | [ADR-0012](decisions/0012-otel-at-the-boundary-backend-deferred.md) OTLP 接收端 | Alloy 已是 OTel Collector，只差一個 `otelcol.receiver.otlp` 區塊 |

**工具會換掉之後我們還剩什麼**，寫在
[`docs/Reachability.md`](Reachability.md#工具會換掉那時候還剩下什麼)：
失效形狀目錄、證據紀律、每個守衛都有證明它會紅的合成控制項。
那三樣與工具無關，是換棧時第一天要帶走的東西。

---

## 推進車道：待辦在 green 上做，blue 在服務

**2026-09-03 定案。** 從現在起這個平台是被**操作**的，不是被開發的，
所以每一項待辦都必須有一個「在哪裡做、怎麼確認、什麼時候才碰到正在服務的東西」的答案。

**顏色的事實先講清楚**：目前 **blue 正在服務**（`Service.spec.selector.color = blue`，
image `v15`），**green 是待命車道**（image `v15-green`，2 個 pod Ready、
`promote.sh` 判定 eligible）。顏色是**角色不是版本號**——哪一個在服務由
Service selector 決定，會隨每次 promote 互換，所以文件不寫死「blue 是正式」。

**車道規則**：

1. 待辦改動一律先部署到**非服務中**的顏色（現在是 green）
2. `promote.sh` 是唯一的切換入口，而且它**會拒絕**：schema 不符、Deployment 未 Ready、
   顏色不存在，三種都擋（有合成控制項，見 `test_bluegreen.sh`）
3. 回滾不需要重建——兩個顏色都在，切回去實測 0~1 秒
4. **不要把 promote 排程化**。`install.sh` 的註解已經寫明理由：
   自動化 promote 等於順手刪掉發布閘門

**為什麼是這個順序**：非服務顏色是這個平台唯一一個
「東西真的在跑、真的可連線、但還沒有人在用」的位置。
那個位置是「部署成功」與「可以承接流量」之間唯一的差別；
沒有它，兩者只能事後分辨。

---

## 判定摘要

| # | 項目 | 轉移到 K8s | 現在做？ |
|---|---|---|---|
| 1 | Vault 動態資料庫憑證 | ✅ 完全轉移 | ✅ **已完成 2026-09-01**（K8s 那份副本也轉成 vault；剩 secret zero，見下） |
| 2 | station2-twin 接進 blue/green | ⚠️ 判定 2026-08-21 改變 | ✅ **已完成 2026-08-25**（K8s Deployment + Service selector；已接進 run_all.sh 第 3 層） |
| 3 | DAST form-aware profile | ✅ 完全轉移 | ⚠️ **盲區已量化並上板（2026-09-01，4/10 路由）**；實掃待拋棄式副本 |
| 4 | station2-twin 的 ingress ceiling | ⚠️ 政策轉移、實作不轉移 | ✅ **政策已在 K8s 強制執行（2026-08-26）** |
| 5 | 異地備份（Google Drive） | ✅ 與底層無關 | 待使用者決定 |
| 6 | 測試資料管理 + redaction v2 | ✅ 完全轉移 | ⚠️ **v1 邊界已量化（2026-09-01，10 類中 6 類沒被找過）**；v2 仍待 CYCH schema |
| 9 | 簡報用的八張圖 | ✅ 與底層無關 | ✅ **已完成 2026-09-01**（八張 Mermaid，節點取自 dag.py） |
| 10 | 三把秘密沒有輪替紀錄 | ✅ 與底層無關 | **等使用者決定**（會動到活憑證）；閘門的空集合通過已於 2026-09-01 修掉 |
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

## 3. DAST form-aware profile — ⚠️ 盲區已量化並上板（2026-09-01），實掃仍待拋棄式副本

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

### 2026-09-01：先把「沒掃到」變成看得見的數字

原本的順序是錯的。要掃寫入端點，得先有一個安全的掃描目標；而在那之前，
**更嚴重的問題是沒有任何地方說明 DAST PASS 到底涵蓋了多少**。

實測：`4 of 10 routes reachable (40%)`。

所以那條 `DAST 執行中系統 PASS` 的真正意思是「spider 撞到的那 4 條是乾淨的」，
不是「這個服務是乾淨的」。**一條綠燈，實際內容是「幾乎什麼都沒檢查」**——
這是這個平台最老的缺陷形狀穿上資安的衣服。

`platform/security/dast_coverage.py` 把它量化，並分成三個**處置不同**的原因：

| 原因 | 數量 | 該做什麼 |
|---|---:|---|
| `write` | 1 | GET spider 永遠碰不到。需要 API profile ＋ 拋棄式副本 |
| `parameterised` | 3 | 要餵範例 id / 縣市名 |
| `unlinked` | 2 | JSON API 沒有連結可循 |

上板：三線階段燈號面板 105–107。**刻意不設告警**——這個值只在有人新增端點時
才變，對單調值設告警只會永遠響或永遠不響。

### 實掃寫入端點：設計已定案，尚未實作

**絕對不對現行實例掃。** 這件事在上面那段就寫過風險（會把垃圾 observation
寫進 650 萬列的資料表），現在把它變成硬規則：

- 拋棄式副本（一次性 postgres ＋ app ＋ migrations，掃完即銷毀，`trap` 保證清理）
- 腳本**拒絕**對任何不是它自己啟動的目標執行
- 需要一份 OpenAPI spec 給 `zap-api-scan.py`

這也正是 `scan_dast.sh` 開頭早就寫下的規則：主動掃描
「needs an explicit decision about what may be attacked and when」。
上面三條就是那個決定，只是還沒寫成程式。

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

### 2026-09-01：先量出 v1 的邊界，不憑空設計 v2

設計 v2 需要一份還不存在的 schema，而憑空猜它就是這個平台明令禁止的
「沒有證據就硬套資料對應」。今天能確定性地解決的是底下那個問題：
**v1 到底涵蓋多少？**

在此之前**沒有任何測試斷言遮蔽有遮到任何東西**。README 記著
「Verified end-to-end, by generating real PII」——那是 2026-08-14 的一次手動驗證，
正是這個 repo 在自己 CI 裡批評過的形狀。任何一條 regex 今天壞掉都不會有人知道。

實測（全部合成值）：

| 類別 | v1 | |
|---|---|---|
| 台灣身分證字號 / email / GitHub PAT / Vault token | **OK** | 四類都確認會被遮掉 |
| 健保卡號 | — | 12 位純數字無字首，和任何長數字無法區分 |
| 病歷號 | — | 院內格式，**需要 CYCH schema 才可能有 pattern** |
| 手機號碼 | — | 與日期、port、列數衝突 |
| 出生日期 | — | 形狀與日誌裡每個時間戳相同 |
| 姓名（自由文字） | — | 需要名單或 NER，不是 regex |
| 地址 | — | 自由文字 |

**10 類中 6 類沒有被找過。** 沒被找過不等於不存在——這只是把設定檔註解裡那句
「a mechanism with a starter ruleset」變成一份**具名清單**，好讓 v2 有東西可以
對照著界定範圍。其中「病歷號」那一條直接標明了瓶頸在哪：**schema**。

### 順帶抓到的真風險：同一組規則寫了兩遍

`config.alloy` 把三條規則各宣告兩次（`redact_internal` / `redact_restricted`）。
兩份副本就是它們分歧的方式，而分歧時繼續洩漏的會是 **restricted——比較敏感的
那一條串流**。同一天已經被同一個形狀咬過一次（K8s 那份 pilot 的憑證模型是兩份
裡比較弱的，而沒有東西在比對）。現在有斷言要求兩個 block 的規則集完全相同，
突變驗證過：只拿掉 restricted 那一份的身分證規則 → 轉紅。

另外檢查 RE2 相容性：lookahead 在 Python 編得過、**會被 RE2 拒絕**，
那會讓 Alloy 帶著一個安靜不存在的 stage 繼續跑，而設定檔讀起來像有在遮蔽。

**這不改變本項的結論**：真實 CYCH 資料進來前 v2 仍是硬前提，
而 v2 的前提是 schema。改變的是在那之前，沒有人會誤以為 v1 是完整的。

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
**該檔已於 2026-09-02 刪除**：手工維護、停在 2026-08-20、自己標著「待完成 — 這不是最終版」，
數字已過期（「6,172,492 疫情事實列」實際 6,503,799、「31 tests」實際數百項斷言），
而它所規格化的八張圖早已畫完。它唯一的內容就是這一節，留在 git 歷史即可。
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

### 2026-09-01：那個閘門本來根本沒在把關

在決定「要不要開始輪替」之前，先發現閘門自己是空的：

```
3 secret(s): 0 within interval, 0 due, 0 without a record, 3 exempt
ROTATION PASS -- every non-exempt secret has a record and is within its own interval
```

三把全部豁免，所以那句話是在**空集合**上量化，恆真。
`ROTATION PASS` 讀起來像政策被滿足，實際是政策什麼都沒檢查。

`check_rotation_sweep.sh` 現在對「全部豁免」回報 **rc 2 / `ROTATION VACUOUS`**，
`run_job.sh` 把它映射成新的 `vacuous` 狀態（不是 ok、也不是 failed——
沒有東西逾期，為一個有人刻意選擇的狀態每天叫人，是告警被靜音的方式），
板面顯示為「檢查了零個項目: rotation」。

**這支腳本原本就有一段空集合守衛**，註解寫著「An empty tree is not a pass」，
擋的是「`secret/` 底下沒有秘密」。平台漂移進了另一種空，直接繞過去。
一道空集合守衛是針對你當時想像得到的那種空寫的。

**這不改變 §10 的結論**：真正開始輪替仍然會動到活憑證，仍然要使用者決定。
改變的是「在你決定之前，板面不會謊稱這件事已經在管控中」。

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

## 16. 價值流看板收不到部署證據 — ✅ 已修（2026-09-03）

`docs/Value-Stream-Board.html` 上 25 個項目全卡在「已提交」、**0 次上線**、
前置時間中位數「尚無資料」。**照字面讀，它說這個平台從來沒有出貨過。**

不是。看板判斷「已部署」的依據是 `evidence/<pilot>/deploy_develop_<sha>.json`，
寫這份契約的是 `platform/compose/deploy.sh`。而 pilot 的部署路徑已改走
Kubernetes（[ADR-0010](decisions/0010-kubernetes-target-runtime-k3s.md)），
**K8s 那條路徑沒有把契約帶過去**。

這是**空集合失效的反面**：不是從空集合推出綠燈，是從空集合推出**紅燈**——
而紅的那種更有說服力，因為空管線和塞住的管線長得一模一樣。

### 修法

[`platform/k8s/station2-twin/deploy.sh`](../platform/k8s/station2-twin/deploy.sh)
在 rollout 之後寫出**同一個檔名、同一組欄位**的契約。
沒有為 K8s 另立格式——那會讓看板讀兩種契約，而兩份索引就是分岔問題。

`compose_project` 這個欄位名保留（這裡沒有 compose project），改放 Kubernetes 的
workload 身分，另外加 `runtime` / `kube_context` / `color` / `image_tag` 讓直接打開
檔案的人不必從 `compose_project` 的形狀去推。看板忽略它不認得的欄位，所以加欄位
不會產生第二份契約。

`health_status` 取自 `rollout status` 的結果，不是固定寫 `healthy`——
一個永遠回報健康的部署證據，正是它要防的那種東西。

### 驗收（2026-09-03 實測）

```
evidence/station2-twin/deploy_develop_410dff9.json
deploy_feed: {"active_files": 1, "retired_files": 4, "starved": false, ...}
```

`board.py` 的 `DEPLOY_EVIDENCE_WRITER` 也一併更新為兩條路徑都會寫——
在缺料橫幅裡只寫其中一個，會把讀者送到錯的檔案。

---

## 17. 八張圖回到板面上（單一來源、內嵌 SVG）

2026-09-02 把重複的第二套圖刪掉之後，`docs/Stage-Report.html` 從**內嵌 SVG**
改成**連到** `docs/report/plates.offline.html`。單一來源達成了，但板面上少了圖。

要兩者兼得，需要在建置時把 mermaid 原始檔渲染成 SVG，再由 `stage_report.py` 內嵌。
`mermaid-cli` 走 `npx`（不全域安裝，符合 CLAUDE.md）但會帶進 Chromium（約 150 MB）。
**這是個取捨，不是純加分**，所以列在這裡由使用者決定，不自行動手。

**不可接受的做法**：再手繪一套 SVG。那正是 2026-08-25 那套的來歷，
而它在九天內就和真實架構分岔到幾乎沒有共同標籤（舊那套寫「31 tests」、完全沒有 Kubernetes）。

---

## 18. 追蹤（traces）：三個前提，依序，不可跳過

決策見 [ADR-0012](decisions/0012-otel-at-the-boundary-backend-deferred.md)。
**現在不裝 Tempo／Jaeger／SigNoz，也不開 OTLP 接收端。**

流傳中的「Prometheus、Grafana、Jaeger、SigNoz ＝ 指標、日誌、追蹤、錯誤」有兩格是錯的：
**Grafana 不儲存任何東西**（日誌是 Loki），**SigNoz 不是錯誤追蹤**
（它是 OTel 原生全棧，是取代 Prometheus+Loki+Jaeger 的選項；「錯誤」那一格是 Sentry 類產品）。

**便宜的部分**：`Grafana Alloy v1.10.2` **就是 OpenTelemetry Collector 的一個發行版**，
而且已經在跑。「應用端一律 OTLP」的代價是一個 `otelcol.receiver.otlp` 區塊，不是新元件。

**但順序是先遮蔽、後接收**，三個前提依序：

1. **遮蔽擴及 span 屬性**。span 例行性帶著完整 URL、query string、使用者識別碼、SQL 片段，
   而現有遮蔽 v1 的三條規則是針對 **log 行**寫的。
   **驗收**：與 log 遮蔽同一種驗法——產生真實格式的 PII，確認儲存內容為 `[REDACTED_*]`，
   原始值在所有租戶查詢皆 0 筆。
2. **租戶隔離的等價物**。目前 Loki 做到的是「restricted 對某資料源**結構上不可達**」，
   不是「查詢時被過濾」。**任何做不到這件事的後端不要選**——
   查詢時過濾是一個「所有人都會記得套用」的承諾，承諾不是控制。
3. **有一個真的需要追蹤的問題**。目前單一 Pilot、單一資料庫。
   追蹤解的是跨服務因果與延遲歸因，服務數量到位前那個問題還不存在。

**不要因為「順手」就先把接收端打開。** 追蹤資料進了儲存，唯一真正的補救是重建整個 store——
這是全平台唯一「晚做比做得不完美更貴」的機制類別，log 遮蔽當初就是照這條判斷先出 v1 的。

---

## 19. 「執行了，但沒有效果」——重訓在沒動過的資料上，看起來和真的一樣

**2026-09-03 發現，資料層已修（[ADR-0013](decisions/0013-pilot-loop-was-open.md)），這個縫隙沒修。**

現在 `ingest` 每日跑，`DataSourceStale` 在 14 天無新資料時會燒。這涵蓋了
2026-08-20 到 09-03 那次的形狀：抓取整個停掉。

**它涵蓋不到的**：抓取**成功**但上游沒發布新資料。
`dataops_source_last_fetch_timestamp_seconds` 取自 `ingest_runs.fetched_at`，
一次成功的空抓取會把時鐘歸零，於是：

- 疾管署停止發布 → 每天抓到同一份檔案 → `fetched_at` 每天更新 → **`DataSourceStale` 永遠不燒**
- `retrain` 每週在相同特徵上重訓 → `model_run` 新增列 → 排程綠燈
- `n_train` 不動，`code_sha256` 不動，MAE 到小數第四位都不動
- **平台每一件產物都顯示一切正常**

**正確的量測不是抓取時間，是「資料的最大流行病學週有沒有前進」。**
`ingest_runs` 已經有 `content_sha256`，連續相同的 sha 就是這個訊號，
而且它已經被記錄下來了——只是從來沒有被讀出來過（和 §14 的 CI 一樣的形狀）。

**為什麼現在不做**：這需要一個新的指標與一條新的告警規則，
而 `retrain.sh` 的註解已經拒絕過「把同一條規則放進第三個地方」。
正確的位置是 `pipeline_metrics.py`（資料層，規則已經住在那裡），
不是 `retrain.sh`。等有第二個 pilot、或第一次真的遇到上游停發時再做。

**驗收（做的時候）**：合成控制項——連續兩次 ingest 灌入同一份檔案，
確認新指標由綠轉紅；這個守衛必須被證明會紅，否則它和不能紅的守衛無法區分。

---

## 20. 五支來源永久紅——✅ 已修（2026-09-03），但原因不是門檻

**2026-09-03 完成。原本的診斷是錯的，修法也會是錯的。**

### 原本的診斷

`DataSourceStale`（14 天）與 `DataSourceVeryStale`（45 天）對所有來源套用同一個門檻，
而五支來源永久停在 warning／critical：

| 來源 | 當時年齡 |
|---|---|
| `moi-admin-geography` | 15.35 d |
| `cdc-tb-caremag` | 15.28 d |
| `cdc-tb-town` | 14.94 d |
| `moi-ris-village-population` | 14.71 d |
| `moi-ris-village-education` | 14.71 d |
| 其餘 18 支 | 0.25 d |

原本的結論是「這五支是年更新來源，門檻訂錯」，提出的修法是
`dataops_source_expected_interval_seconds` ＋ `age > 3 * expected`。

### 為什麼那個修法是錯的

**`dataops_source_age_seconds` 量的是「我們上次抓取」，不是「上游上次發布」。**
它的定義是 `now - max(fetched_at) FROM ingest_runs`。

所以那五支不是門檻訂錯，**是根本沒有東西在抓它們**。
`ingest.sh` 跑的是 `--sources nhi_all,rods_all`，這五支不在裡面，
而它自己的註解把這件事寫成一個決定：

> annual and near-annual sources 「stay a manual load; DataSourceStale watches
> them at 14 days and MissingSource at 45, which is the correct instrument」

這個推理自相矛盾：**手動載入的年更新來源必然會超過 14 天**，
所以那個「正確的儀器」保證會永遠紅。

按原本的修法把門檻拉成 3×發布週期，等於把一個**為真**的陳述
——「兩星期沒有任何東西抓過它」——調到不再被說出來。**那是把真告警靜音。**

### 實際的修法

新增 `platform/dataops/ingest_slow.sh`，週排程（`ingestslow|604800`），涵蓋三支 loader：

```
load_dimensional.py --sources tb,caremag
load_registry.py --datasets pop,edu --years 114-115
load_geography.py --refresh
```

**量測（執行後）：23 支來源全部 ≤ 0.29 天。** 五支永久紅消失，
`DataSourceStale` 的 14 天門檻對每一支都重新是有意義的。

週而不是日：`caremag` 是 4.1M 筆存量列，日排程要重讀 365 次來學到零；
週排程讓每一支都留在 14 天門檻內、還有一次漏跑的餘裕，成本是日排程的七分之一。
caremag 因此落後最多 7 天，這是刻意接受的——它不餵預測。

**ROC 115 也照抓**：實測 `ODRP019/115` 回 HTTP 200、`responseCode=OD-0102-S`、0 筆，
而 `load_registry.py` 把非 `OD-0101-S` 當作 skip 不是失敗。
所以要 114-115 的成本是每次多一個請求，好處是 115 一發布就自動開始收，沒有人要記得改。

### 頻率表還是做了，但用途不同

`pilots/station2-twin/ingest/source_frequency.json`，由
`platform/dataops/refresh_source_frequency.py` 從出版方目錄產生，24 支來源：
20 支 `declared`（CKAN `updated_freq`）、2 支 `structural`、2 支 `no-evidence`。

它的用途是**決定排程週期**，不是決定告警門檻——後者問的是我們的抓取有沒有停，
前者才需要知道上游多久發一次。

**這張表當場推翻了本節原本的表格。** 原本寫 `cdc-tb-caremag` 是「年」，
CKAN 宣告是 **`day`**——那個資料集就叫「結核病**每日**縣市鄉鎮管理中個案」。
一個憑印象寫的數字，在 markdown 表格裡和量出來的數字長得一模一樣，放了好幾週沒人發現。
`platform/tests/test_source_frequency.sh` 現在要求每一列都帶 provenance，沒有依據的列直接紅。

**欄位名也是錯的**：Backlog 原文說查 CKAN 的 `frequency`，實際欄位是 `updated_freq`。

### 還沒做的

- **上游是不是還在發布，仍然量不到。** `age` 只回答「我們的抓取有沒有停」。
  要回答前者需要比對資料本身的最大期別（epi_week／statistic year）與宣告週期，
  那是 §19 空抓取的同一個缺口，頻率表是它的前提但不是它。
- **`moi-ris-village-age-marital`（ODRP052）從未載入過**，在 `DATASETS` 裡但沒有攝取歷史。
  沒有加進 slow ingest：那是新範圍，不是這次的修正。

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

---

## §21 磁碟沒有被量（2026-09-03 完成）

**插隊的理由，明說。** §20 原本是下一個。磁碟監控排到它前面，
不是因為比較重要，是因為**它已經發生過一次，而且停掉的是整個平台**——
包含用來發現 §20 那五支永久紅來源的那套監控本身。

### 發生了什麼

`/System/Volumes/Data` 使用率 100%（剩 133Mi）。Prometheus 停止回應，
Docker 引擎 11:23 死掉，所有容器下線。當時：14 條告警規則、91 個已登記能力
（零孤兒）、777 個通過的斷言，**沒有一條引用剩餘空間**。

新的失效形狀，加進目錄：

> **「監控系統被它沒有監控的東西弄停了」**

它與其他形狀的差別在於**自我隱藏**：資源耗盡先殺掉的，
正是負責報告資源耗盡的那個程序。事後看不到告警，
和「沒有東西值得告警」在輸出上分不出來。

### 做了什麼

| 產出 | 位置 |
|---|---|
| 主機端匯出器（跑在 macOS，不在容器裡） | [`platform/observability/host_disk_metrics.sh`](../platform/observability/host_disk_metrics.sh) |
| 兩條磁碟門檻規則 | [`platform/observability/prometheus/alerts/host-capacity.yml`](../platform/observability/prometheus/alerts/host-capacity.yml) |
| 三條匯出器新鮮度規則（守的是上面兩條的輸入） | [`platform/observability/prometheus/alerts/exporter-freshness.yml`](../platform/observability/prometheus/alerts/exporter-freshness.yml) |
| 五方交叉比對：門檻表／運算式／`jobs.conf`／compose 掛載／實際檔案 | [`platform/tests/exporter_freshness_check.py`](../platform/tests/exporter_freshness_check.py) |
| 合成控制（紅綠成對） | `platform/observability/prometheus/rule_tests/{host-capacity,exporter-freshness}_test.yml` |
| 測試套件（含突變測試，證明控制能失敗） | `platform/tests/test_host_capacity.sh`、`test_exporter_freshness.sh` |
| 排程 job（300s，本表最短） | `platform/scheduler/jobs.conf` |
| 選擇性回收腳本（**不是** `docker system prune -a`） | [`platform/observability/docker_reclaim.sh`](../platform/observability/docker_reclaim.sh) |
| 決策紀錄與量測 | [ADR-0014](decisions/0014-host-disk-was-unmeasured.md) |

故障全程用假序列模擬。**沒有真的填滿磁碟**——CLAUDE.md §5c 點名禁止，
何況要測的故障正好會殺掉執行測試的那個程序。

### 三件被推翻的事

1. **`ls -lh` 說 `Docker.raw` 926G。** 那是 sparse image 的 apparent size，
   等於整顆卷。真正佔用（`stat -f %b × 512`）是 22.4GB。差 44 倍。
   與事故初期把 `df /`（唯讀封存卷）誤讀成資料卷是同一類錯誤。
2. **「macOS 的 Docker.raw 只增不減」不成立於這個版本。** 先寫進註解、再實測：
   VM 內回收 ~2.7GB 後，主機檔案數分鐘內從 24.03GB 降到 22.49GB，
   三次取樣一致。保留原敘述會把人推向「重設磁碟映像」這條破壞性路徑。
3. **`service-health.yml` 說「沒有 node-exporter」。** node-exporter 已經跑了數週。
   結論碰巧還對（它以 `--collector.disable-defaults` 啟動），但理由早就不成立。
   **沒有標日期的「已承認缺口」會從決策退化成信念。** 該段已更正並標日期。

### 順帶修掉的版本歪斜

測試用 `promtool` 來自 `prom/prometheus:v3.6.0`，實際評估規則的是 `v3.5.0`。
**驗證規則的版本不是跑規則的版本**，形狀同「登記為存在，但不執行」。
`lib.sh` 新增 `prom_image()` 直接從 compose 讀，兩者不可能再分岔。

### 還沒做到的

- **逐則訊息對不上告警。** `HostDiskMetricsStale` 已在真實資料上燒過並解除，
  telegram 計數器 1 → 5、失敗 0；但一次就成功的通知不留日誌，
  哪一則對應哪一個要看使用者的 Telegram。
  `HostDiskLow` / `HostDiskCritical` 從未在真實資料上燒過——磁碟一直健康。
- **門檻是推的不是量的。** 10% / 4% 依事故當天的填充速度選定，只有一次觀察。
- **只涵蓋一顆卷。** 外接磁碟與其他 APFS volume 沒有涵蓋。

---

## §22 Telegram bot token 經由錯誤路徑外洩到日誌（2026-09-03 發現）

### 事實

Alertmanager 的容器日誌裡有完整的 bot token 明文，形如
`https://api.telegram.org/bot<id>:<token>/sendMessage`。
Alloy 把容器日誌送進 Loki，所以 **Loki 裡有 379 行含 token**
（`observability-alertmanager-1` 39 行、`observability-loki-1` 340 行）。

擴散範圍已量：

| 位置 | 結果 |
|---|---|
| git 追蹤的檔案 | **0**（`git ls-files \| xargs grep` 全掃） |
| `evidence/` | **0** |
| `docs/` | **0** |
| 容器日誌 | 有 |
| Loki | **379 行** |

**Loki 沒有認證，Grafana 對區網開放**（[ADR-0003](decisions/0003-prometheus-lan-exposure.md)），
所以區網上任何能開 Grafana 的人都讀得到這個 token。

### 為什麼既有防護擋不住

`alertmanager/config.yml` 刻意用 `bot_token_file` 讓 token **不進設定檔**，
那一層是對的、也生效了。漏的是**錯誤路徑**：telebot 把整個請求 URL（含 token）
放進 error 字串，Alertmanager 把 error 記進日誌。

**一個被擋在設定檔外的憑證，在第一次呼叫失敗時就會抵達日誌儲存。**
這不是 Telegram 的怪癖，是通則。

Alloy 的 redaction 有三條規則，涵蓋 `ghp_` / `github_pat_` / `hvs.`——
那三條是**從憑證格式清單推出來的**。這一條是**因為真的漏了才存在的**。
兩種選規則的方式，找到的東西不一樣。

### 已做（止血）

- `config.alloy` 兩個 redaction block 各加第四條規則（drift guard 要求兩份一致）。
  規則刻意保留數字 bot id、只遮掉冒號後的祕密——bot id 用來分辨是哪一支 bot，不是祕密。
- `redaction_check.py` 加入 `Telegram bot token` 正向控制；
  `test_redaction.sh` 的 `rules_per_block` 由 3 改 4。10/10 通過，
  且 negative control 仍然通過（沒有變成「什麼都遮」）。
- Alloy 已重啟，規則對**新**日誌生效。

### 只有使用者能做（B10）

1. **輪替 token**：Telegram BotFather `/revoke` 後重新產生，寫回
   `platform/observability/alertmanager/telegram-token`（chmod 600）並重啟 Alertmanager。
   **agent 不建立也不輪替憑證。**
2. **決定既有 379 行怎麼處理**：Loki 的 `/loki/api/v1/delete` 需要開啟
   `deletion_mode`；或直接讓保留策略過期。**刪資料不是 agent 該自己決定的事。**

輪替之前，這條通知鏈要當成已知外洩來看待。

### 補記：「守衛的守衛」被追問之後改掉的東西（2026-09-03 當天）

第三條原本是 `HostDiskMetricsStale`，看磁碟匯出器**自己寫的**時間戳。原則對，實作三處錯：

1. **node-exporter 早就有 `node_textfile_mtime_seconds`**，六個檔案全都有——自訂 gauge 是重複造輪子。
2. **mtime 比較強**：自訂 gauge 是腳本對自己的宣稱，時鐘錯了或 `mv` 失敗它會繼續報新鮮；
   mtime 是檔案系統觀察到的，寫入者無法宣稱。
3. **只守一個檔案**，另外五個失效模式相同卻一條規則都沒有。

遞迴的終止條件是一個**性質**：安靜失敗的檢查需要外部見證者，大聲失敗的不需要。
新規則以 `time()` 為軸，Prometheus 停了它會連同整組規則消失而不是安靜變綠。**鏈長是二。**
剩下的縫（新 `.prom` 沒門檻）是**組態**性質，放測試不放告警——
執行期的問題給告警，組態的問題給測試。

**當場抓到的量測錯誤**：第一版規則寫 `file="host_disk.prom"`，實際 label 是
`/textfile/host_disk.prom`——是我自己的顯示指令 `sed` 掉前綴，我再照那個形式寫規則，
於是它匹配不到任何序列、永遠不會燒。抓到它的是 `TextfileExporterMissing` 轉 pending。
**與把 `ls -lh` 的 926G 當成佔用量同一類：為了好讀而做的轉換改變了答案。**

**另一個當場抓到的**：突變測試的 `sed` 指著舊的 matcher 拼法，什麼都沒改到，
輸出卻寫「mutant survived」——那是關於規則的宣稱，實際上是關於測試的宣稱。
`lib.sh` 新增 `mutate()`，先驗證編輯真的落地才量它的效果。
**「突變沒套用」和「突變存活」必須分得開。**

---

## §23 `IngestRunsFailing` 只可能因為「不是失敗」而燒（2026-09-03 移除）

### 事實

`dataops_ingest_runs_failed_total` 的定義是 `count(*) FILTER (WHERE status <> 'ok')`。
資料庫裡實際存在的狀態只有兩種：

| status | 筆數 | 意思 |
|---|---|---|
| `ok` | 80 | 正常 |
| `ok-with-conflicts` | 2 | **執行成功**，但來源自己矛盾：同鍵不同值，該列被拒絕並計數 |

**沒有任何 loader 寫得出失敗狀態。** 真的抓失敗時 loader 直接非零離開，
**一列都不會寫進 `ingest_runs`**。

所以這條規則：
- **不可能**因為它宣稱的理由（批次失敗）而燒；
- **只可能**因為 `ok-with-conflicts` 而燒，然後說「有失敗的載入批次」。

而 `cdc-tb-caremag` 的來源每次都帶同一個 conflict，
所以 §20 新增的週排程一上線，它就變成**每週準時報到的永久紅**——
正是 §20 才剛在上一層移除掉的那個東西，在下一層立刻重現。

### 處置

- `pipeline_metrics.py` 改成三份具名清單 `OK_STATUSES` / `CONFLICT_STATUSES` /
  `FAILURE_STATUSES`，未分類的狀態直接讓匯出器停掉。
  規則與理由同 `RETIRED_SOURCES`：**具名清單加上斷言，不用啟發式。**
- 新增 `dataops_ingest_runs_conflicted_total`，與失敗計數分開。
- **移除 `IngestRunsFailing`。** 批次失敗由排程器那條路徑覆蓋
  （loader 非零 → `probe_scheduler` FAIL → `PlatformNodeFailed`），
  留一條燒不起來的規則在這裡會被讀成額外覆蓋，實際相反（[ADR-0005](decisions/0005-dataops-monitoring-scope.md)）。
- `test_dataops_metrics.sh` 斷言資料庫裡每一個 status 都被分類，且三份清單互斥。

### 還沒做的

- **conflict 沒有告警，是刻意的。** caremag 的 conflict 數自 2026-08-19 起
  一直是 1；**只有變化才是新聞**，而偵測變化需要一條這個平台還沒存的基線。
  對絕對值告警只會製造出剛剛被移除的那種永久紅。
- **讓 loader 真的寫得出失敗列**，`IngestRunsFailing` 才會有意義的版本可以回來。
  現在的替代覆蓋（排程器路徑）看得到「job 失敗了」，
  看不到「25 支來源裡有 1 支失敗、其餘成功」——那個粒度目前量不到。

---

## §24 ADR-0008 訂了三天，沒有人檢查另一邊（2026-09-03）

### 事實

[ADR-0008](decisions/0008-two-machines-two-architectures.md) 自 2026-08-31 起就宣告
這個平台橫跨兩種指令集與兩個作業系統。ubu 一開機、**第一次真的在 Linux 上跑 tier 1
（就是 CI 跑的那一層）**，找到三個已經推上去的缺陷，外加這個檢查自己找到的第四個。

| 缺陷 | 為什麼 Mac 上看不到 | CI 有沒有抓到 |
|---|---|---|
| `host_disk_metrics.sh` 寫死 `/System/Volumes/Data` | macOS 專屬路徑，Linux 上 `df` 直接失敗 | 有——連紅四次，從 04:09 到 12:01 |
| `sed -i ''`（`lib.sh` ＋ 兩個套件） | BSD 專屬。GNU sed 把 `''` 當腳本、腳本當**檔名**，**每個突變靜默地什麼都沒改**，輸出卻寫「mutant survived」 | 有 |
| `source_frequency_check.py` 直接呼叫 `docker` | Linux 上沒有 docker，未捕捉的 `FileNotFoundError` 變成假缺陷 | 有 |
| `test_loki_coverage.sh` 的合成控制項餵空檔案 | Loki 在 Mac 上活著；shell 重導向即使 curl 失敗也會建檔，所以 `\|\|` fallback 永遠不執行 | **沒有**——它在 CI 上剛好也是綠的 |

第四個最值得記：**一個輸入取決於環境的控制項不是控制項**，
它是對環境的第二次觀察。CLAUDE.md §5b 要求確定性輸入正是為了這個，
而這個檔案一邊對別人的程式執行那條規則、一邊自己壞著。

### 處置

| 產出 | 位置 |
|---|---|
| 推之前在 Linux 節點跑 CI 那一層 | [`platform/tests/run_on_ubu.sh`](../platform/tests/run_on_ubu.sh) |
| 可攜的就地編輯 | `lib.sh::sed_i`，＋`test_static.sh` 靜態規則＋合成控制 |
| 磁碟匯出器依 OS 選掛載點 | `host_disk_metrics.sh`，已在 ubu 實測 |
| cadence checker 容忍沒有 docker 的機器 | `source_frequency_check.py` |
| loki 控制項改用確定性 fixture | `test_loki_coverage.sh` |
| 平台知道 ubu 存在 | `dag.py` 的 `prodk8s` 節點；**空叢集回報 WARN 不是 OK** |
| ADR-0008 第二條規則開始執法 | `deploy.sh` 對非 lab context 拒絕 tag |
| amd64 建置鏈 | `.github/workflows/pilot-image.yml`（**尚未執行過**） |

### 順帶修掉的：新增排程 job 會讓看板紅一整個星期

`never-run` 原本無條件視為不新鮮，`probe_scheduler` 把任何不新鮮的 job 變成
FAIL「not running: <job>」。**每個新加的 job 在它第一個週期內都是 never-run**——
300s 的 `disk` 只紅五分鐘，週排程的 `ingestslow` 會紅六天，
而那個節點正是用來偵測「job 停了」的。**保證會紅一週的紅燈，人會學會等它過去。**

現在用 launchd agent 的安裝時間把三種宣稱分開：

| 情況 | 判定 |
|---|---|
| 沒有 agent 檔 | `never-run`，**FAIL**（agent 從未載入，這才是原本註解描述的情況） |
| 安裝未滿一個週期 | `not-yet-due`，fresh，但仍以獨立狀態顯示在板面上 |
| 安裝已超過一個週期仍未觸發 | `never-run`，**FAIL**，而現在這句話是真的 |

三個方向都有斷言（`test_scheduler.sh`）。**中間那一條是放寬，而一條無法證明
仍然抓得到硬情況的放寬，等於把檢查關掉。** 第三條就是那個證明。

### 還沒做的（需要你操作）

1. **停用 ubu 的休眠**——會休眠的筆電不是生產主機。ubu 上沒有免密碼 sudo：
   ```bash
   ssh ubu
   sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
   sudo sed -i 's/^#\?HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
   sudo systemctl restart systemd-logind
   ```
2. **固定 IP**（目前 `192.168.1.144`）——理由已在 §26 更正：**不是**因為 kubeconfig
   會壞（它用的是名字不是 IP），而是為了診斷路徑與 mDNS 失效時的退路。
3. ~~**ghcr 套件的可見性**~~ **不需要處理**：實測未帶認證即可 `imagetools inspect`，
   套件是公開可讀的，ubu 的 k3s 直接拉得到。原本那句「預設私有」是假設不是量測。

### 還沒做的（不需要你，但需要前置條件）

- **pilot 上 prod**：`pilot-image.yml` 已於 2026-09-03 首次執行成功，
  digest 是 `ghcr.io/drew-young-ai/station2-twin@sha256:a073781305...`，
  且已在 ubu 上以一次性 Job 實測跑起來（`machine: x86_64`，拉的是 digest 不是 tag）。
  **剩下的阻塞不是映像，是 Vault 與資料庫**：`deployment-template.yaml` 的
  `PGHOST` 與 `VAULT_ADDR` 都指向 `host.k3d.internal`，那是 k3d 專屬的名字，
  ubu 上不存在。在那之前 `test_image_arch.sh` 對 ubu 會回報 `VACUOUS`——
  它問的是「部署在那裡的 Deployment」，一次性 Job 不算。**空集合就該說是空集合。**
- **Vault on ubu**（使用者已決定兩台都放）：`hashicorp/vault:1.18` 是多架構，
  k3s 自己拉得到，不需要本機建置也不需要 root。沒有現在做是因為它會產生
  unseal key 與 root token，而那批憑證的存放位置與 pilot 上 prod 的時程應該一起決定。
- **prodk8s 的 DAG 邊**：目前刻意沒有邊。誘人的那條是 `registry → prodk8s`，
  但那個 registry 是 Mac 上的 k3d registry，供應 amd64 節點跑不動的 arm64 映像——
  畫下去等於斷言 ADR-0008 明確否認的依賴關係。

---

## §25 磁碟是被測試套件填滿的（2026-09-04 找到根因）

### 事實

2026-09-03 建了主機磁碟監控（[ADR-0014](decisions/0014-host-disk-was-unmeasured.md)），
理由是「一個沒人量的數字停掉了整個平台」。**隔天那個告警要燒的時候，去找消耗者，
發現是測試套件自己。**

```
/System/Volumes/Data          761G used / 95G free   (89%)
  └ /private/var/folders/…/T  427G                   ← $TMPDIR
      └ tmp.XXXXXXXX × 124    每個 3.6G，日期 09-01 21:58 → 09-03 23:11
```

每個 3.6G 的內容是 `platform/` 的完整複本——包含 **`platform/backup/archives`
的 3.3GB 備份 tarball**，而沒有任何測試讀過其中任何一個。

清掉之後：**95GiB → 516GiB**（回收 421GB，使用率 89% → 44%）。

**累積視窗涵蓋 09-03 的停機。** 測試套件就是那個填滿磁碟的東西，
而沒有東西把兩者連起來，因為沒有東西在量磁碟——
**ADR-0014 蓋的那個洞，比它自己的成因高了一層。**

### 三個疊在一起的缺陷

**1. sandbox 複製了 3.3GB 沒有人要的東西。**
`cp -R "$REPO_ROOT/platform"` 沒有排除機制。改用 `rsync --exclude`，
排除清單以**名稱**列出（不是大小門檻——門檻會在某天某個東西長大時
悄悄開始排除測試需要的檔案）。sandbox 從 3.6G 變成 **1.9M**。

**2. 清理從來沒有執行過。** 不是「異常退出時沒執行」，是**從來沒有**。

```bash
SANDBOXES=()
make_sandbox() { sandbox="$(mktemp -d)"; SANDBOXES+=("$sandbox"); ... }
# 但每個呼叫端都寫：
SANDBOX="$(make_sandbox)"     # ← 命令替換是子 shell
```

陣列在子 shell 裡被追加，父行程的永遠是空的，`cleanup_sandboxes` 迭代空集合、
刪掉零個目錄。**這個 repo 已經記載過同一個形狀**——一個合成控制項的計數器
`N=$((N+1))` 寫在 `$(...)` 裡，永遠到不了 3。**同一個檔案、三週之內、同一個錯誤。
子 shell 是狀態去被遺忘的地方。**
改用註冊檔（寫檔案，穿得過子 shell）。

**3. 十個套件把 lib.sh 的 EXIT trap 覆蓋掉了。**
`trap X EXIT` 是**取代**不是疊加。那十個套件在正常路徑上還活著，
是因為 `suite_summary` 也會直接呼叫清理——**但異常退出的安全網，
恰好在最認真想過清理的那些套件裡消失了。**
新增 `lib.sh::on_exit`（累加而非取代），十個套件全部轉換，
並加靜態規則擋住下一個人寫出那個顯而易見的寫法。

### 順帶

`run_cmd` 每次呼叫洩漏兩個暫存檔，一次完整執行約 500 個，從未清理——
$TMPDIR 裡累積了 8,188 個。小到看不見，正因如此才沒人發現。現在也一起清。

### 驗收

`platform/tests/test_sandbox_hygiene.sh`，五個斷言，其中兩個是控制項：

- 排除清單不是過期的（名稱要在樹裡真的存在）
- sandbox 不帶 backup archives，且小於 50MB（實測 1MB）
- 一個跑完的套件留下小於 50MB（實測 0KB）
- **一個不呼叫 `suite_summary` 就退出的套件仍然會被清理**（trap 的證明）
- **量測本身能紅**：塞 60MB 進 $TMPDIR，同一個量測必須看得到

### 修的過程中我自己犯的兩個錯，都被同一批控制項抓到

**1. 把 `on_exit` 用 pattern 套到不 source lib.sh 的套件上。**
`test_backup_coverage.sh` 與 `test_no_lookahead.sh` 有自己的 PASS/FAIL 計數器、
不 source lib.sh。我把它們的 `trap restore_state EXIT` 改成 `on_exit restore_state`，
而 `on_exit` 在那裡是**未定義指令**——印一句 "command not found" 到沒人看的 stderr、
註冊零個處理常式。結果：**該套件的狀態還原無聲停止**，
`evidence/backup/last_known_pvcs.txt` 被留在測試 fixture 的值上。

lib.sh 的檔頭早就警告過這個形狀（針對斷言 helper）。**它對 cleanup 一樣成立，而且更糟：
少一個斷言是「有個檢查沒發生」，少一個 cleanup 是「平台的帳被改了還留著」。**
已還原成裸 trap，靜態規則改成只對真的 source lib.sh 的套件生效。
狀態檔用它真正的產生者 `platform/backup/backup.sh` 重新產生，不是用手填回去。

**2. 靜態規則的豁免條件匹配到散文。** 我寫的豁免是 `grep -q 'lib.sh' "$file"`，
而那兩個檔案的新註解裡正好寫著「這個套件不 source lib.sh」——於是它們被豁免了。
**這是這個檔案第五次發生 grep 檢查匹配到自己的散文。**
五次之後那不是疏忽，是方法的性質：**一個文字比對的守衛，活在它所搜尋的語料裡。**
改成匹配真正的 source 行（`^\s*(source|\.)\s+.*lib\.sh`）。

**3. `run_cmd` 的暫存檔陣列有同一個子 shell缺陷。** 第一版修正用陣列，
理由是 run_cmd 是被直接呼叫的。對多數呼叫成立、對全部不成立——
一個寫 `X="$(run_cmd ...; cat "$LAST_STDOUT")"` 的套件就在子 shell 裡。
改成與 sandbox 共用同一個註冊檔。

**4. `dd bs=1m` 在 GNU dd 上直接失敗。** 那個 ballast 控制項推上去之後 CI 紅了，
訊息是「這個檢查是瞎的」——關於一個運作正常的 `du`。真正的原因是
`dd: invalid number '1m'`：GNU dd 拒絕小寫倍率，BSD/macOS 接受，
而 dd 的錯誤訊息去了一個測試通常已經重導掉的 stderr。
**在 alpine 容器裡實測驗證**，不是用推的：`bs=1m` 失敗、`bs=1024k` 兩邊都寫出 2097152 bytes。

**兩天內第三個 BSD/GNU 陷阱**（`stat -f`、`sed -i ''`、現在 `dd bs=`）。
三次之後這不是巧合，是這台開發機與 CI／prod 之間一條穩定的裂縫。
`test_static.sh` 已加規則與合成控制。

### 最終量測

完整套件跑完後 `$TMPDIR` **完全沒有成長**（前後都是 8,105 項 / 5.5G）。
878 assertions / 35 suites 全綠。

最後一條第一次跑就失敗了，而且失敗得對：我用 `mkfile -n 60m` 造 ballast，
那是**稀疏檔**——`du` 量的是區塊，稀疏檔佔零個區塊，所以量測回報 0MB 成長、
控制項回報「這個檢查是瞎的」——關於它自己。改用 `dd`。
**與 `ls -lh` 對 Docker.raw 顯示 926G 是同一個區別，只是換了一個檔案。**

---

## §26 DHCP／命名：先量了才發現原本的理由是錯的（2026-09-04）

### 我先前寫錯的一句話

我在 §24 與 `docs/Ubu-Prod-Bringup.md` 寫過「DHCP 換約會讓 kubeconfig 的 SAN
與所有診斷失效」。**查了之後，前半是錯的。**

```
kubectl config view -o jsonpath='{...clusters[?(@.name=="ubu")]...server}'
  → https://ubu.local:6443        ← 是名字，不是 IP
```

而今天 `kubectl --context ubu get nodes` 連得上，這本身就證明
**k3s 的 leaf 憑證 SAN 已經涵蓋 `ubu.local`**——否則 TLS 驗證會失敗。
（想直接看 SAN 的話 ubu 現在睡著了，但「連得上」是比讀憑證更強的證據。）

**所以 DHCP 換約不會弄壞 kubectl。** mDNS 已經在承擔這件事。

### 那固定 IP 還要不要做？要，但理由不同

| 換 IP 之後會壞的 | 會不會壞 |
|---|---|
| `kubectl --context ubu`（走 `ubu.local`） | **不會** |
| `platform/tests/run_on_ubu.sh`（走 `ssh ubu`，`~/.ssh/config`） | 看 config 寫的是名字還是 IP |
| 手冊第二節的診斷指令（寫死 `192.168.1.144`） | **會**，而那正是機器出事時要用的東西 |
| mDNS 本身失效時的退路 | **會**——沒有 IP 就完全沒有第二條路 |

`docs/Ubu-Prod-Bringup.md` 已經記過 `70.local` 那次教訓：**mDNS 可以單獨失效**。
固定 IP 的價值是「mDNS 壞掉時還有東西可用」，不是「kubeconfig 需要它」。

### ZTP 與 service discovery：都不採用，理由不是「太複雜」

- **ZTP（Zero-touch provisioning）** 解的是「從裸機大量佈建設備」。
  這裡是兩台機器、其中一台已經手動裝好並驗證過。ZTP 的成本全在建立佈建管線，
  而佈建這件事在這個規模只會發生一次。
- **Service discovery（Consul / etcd 之類）** 解的是「服務對服務的動態尋址」。
  這裡的問題是**主機層的命名**，而 mDNS 就是這個規模的 service discovery——
  它已經在用、而且已經在承擔 kubeconfig。再疊一層等於用第二個名字服務去解
  第一個名字服務偶爾失效的問題，兩個都會失效，而且要維護兩份。
- **Kubernetes 內部的 service discovery 本來就有**（CoreDNS）。
  今天才修過它一次：`host.k3d.internal` 的映射在 Docker VM 猝死後消失，
  pod 因此連不到 Vault。那是叢集內的命名，與這裡討論的主機層命名是不同的一層。

### 真正的缺口：沒有東西在驗證這條命名鏈

`probe_prod_cluster` 涵蓋「叢集回不回應」。它**沒有**分辨這三種：

1. `ubu.local` 解析不到（mDNS 失效）
2. 解析得到但 IP 變了、憑證 SAN 沒涵蓋新位址（TLS 失敗）
3. 機器睡著了（今天實際發生的）

現在三種都收斂成同一句「prod 叢集連不上」。**分辨它們需要不同的處置**，
所以這是一筆待辦（見下方 §27），不是現在要加的新功能。

---

## §27 待辦登記簿（2026-09-04 起，逐一完成）

**規則：這一節只登記，不實作。** 需求不擴張，功能逐步收斂落地。
每一筆都要有「為什麼現在不做」與「什麼時候該做」。

| # | 待辦 | 為什麼現在不做 | 觸發條件 |
|---|---|---|---|
| T1 | **備份歸檔沒有保留策略** | 見下方分析：現在不痛，但單調成長 | 磁碟告警再燒，或歸檔超過 10G |
| T2 | **`probe_prod_cluster` 分辨三種連不上**（mDNS 失效／SAN 不符／機器睡著） | 三種目前都收斂成同一句話；分辨需要不同處置，而處置還沒定 | ubu 停用休眠之後——在那之前「睡著」會蓋掉另外兩種 |
| T3 | **從社群的教訓反向補守衛** | 見下方分析 | 每次遇到「本機綠、別處紅」時追加一條 |
| T4 | **loader 寫得出失敗狀態**（§23） | `IngestRunsFailing` 才有有意義的版本可以回來 | 出現第一個「25 支來源裡 1 支失敗」的情境 |
| T5 | **conflict 變化的基線**（§23） | 只有變化才是新聞，而基線還沒存 | T4 之後 |
| T6 | **空抓取偵測**（§19） | 前提（頻率表）2026-09-03 已備妥 | 下一個 dataops 週期 |
| T7 | **pilot 上 prod**：Vault ＋ 資料庫 on ubu | 映像已通，剩這兩個；會產生 unseal key，存放位置要與時程一起定 | ubu 停用休眠之後 |
| T8 | **`moi-ris-village-age-marital`（ODRP052）從未載入** | 那是新範圍不是修正 | 需要年齡／婚姻維度時 |
| T9 | **`prodk8s` 的 DAG 邊** | 誘人的 `registry → prodk8s` 是假的（arm64 registry 供不了 amd64 節點） | ghcr 進入部署路徑之後 |
| T10 | **板面內嵌 SVG**（§17） | 需 ~150MB Chromium，成本由使用者決定 | 使用者決定 |
| T11 | **追蹤 traces**（§18） | 三個前提未到 | 服務數量到位 |

### T1 備份歸檔：現況與建議

**現況（量測，2026-09-04）**

```
platform/backup/archives   3.6G / 163 份
每日約 70–150 MB，最早 2026-08-16，最大單份 433 MB
.gitignore:57 已排除 → 不會進 git
```

**目前有的**：`host_filesystem_avail_bytes` 告警（10% warning / 4% critical）
會在它變成問題**之前**說話——這是 2026-09-03 那輪建的，而它今天早上確實
壓在 10.3% 上並促成了整個調查。所以「監控」這一半已經到位。

**目前沒有的**：**任何保留策略**。`backup.sh` 每天新增一份、從不刪任何一份。
以目前速率約 100MB/日，一年約 36G——不是急性風險，但是單調成長，
而且它已經以「被複製進 sandbox」的形式參與過一次真正的停機。

**建議（不是現在做，登記為 T1）**

1. **保留策略要用「還原過的最舊一份」當下限，不是用天數。**
   `restore_drill.sh` 每週驗證一份；刪掉從未被還原驗證過的份，
   等於刪掉未經證實的備份，那沒有損失。刪掉**唯一被證實過**的那份才是損失。
2. **刪除必須是產生者的責任**（`backup.sh`），不是外部 cron。
   外部清理與產生者對「哪些還需要」的認知會分岔。
3. **合成控制**：一個「刪到只剩零份」的突變必須讓 `backup` 節點變紅，
   否則保留策略會安靜地把備份清光。

### T3 從社群的教訓反向補守衛

**動機（使用者提出）**：我們自己踩到的坑會變成守衛，但別人踩過的坑
不該等我們再踩一次。

**這一輪的三個坑全是同一類**：`stat -f`、`sed -i ''`、`dd bs=1m`——
BSD 與 GNU 的介面差異。這不是稀有知識，是有名的坑，
而我們是靠 CI 紅四次、再靠第二台機器開機才逐一發現的。

**可行的形狀**（登記，不實作）：

- 這個 repo 已經有的資產是**失效形狀目錄**與**每個守衛都有合成控制**。
  外部教訓應該以**同樣的形式**進來：一條靜態規則 ＋ 一個能紅的控制項，
  而不是一份「注意事項」文件——後者會退化成信念（本輪已有兩個實例：
  `service-health.yml` 說「沒有 node-exporter」、手冊說兩個缺口未修）。
- 來源優先序：`shellcheck` 的規則清單（SC2xxx）本身就是社群整理過的
  bash 坑目錄，而且可機器讀。**先把 shellcheck 跑起來、再挑要升級成
  硬規則的那幾條**，比人工蒐集 issue 有效。
- **判準沿用 [[no-frankenstein]] 的三條**：外部方案先寫 watchlist，
  不直接納入。一條外部教訓要變成這裡的規則，必須先在這個 repo 裡
  找得到「它會發生」的證據，否則就是照抄別人的焦慮。

**為什麼現在不做**：這會新增一個工具（shellcheck）與一批規則，
而目前的方向是收斂。等下一次「本機綠、別處紅」發生時，
用那一次的具體案例當入口，比一次導入一整套規則更容易站得住。

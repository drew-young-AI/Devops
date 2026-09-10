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
| ~~B9~~ | ~~這一輪的修正尚未 commit~~ **2026-09-08 已解除**：使用者明確指示後推上 `origin/main`（`cbf7031..edfb331`，7 筆，88 檔）。這一項是**復發型**的——每一輪工作結束時都會重新成立 | `CLAUDE.md` 明訂未經明確指示不得 commit / push / 開 PR | — |
| **B10** | **Telegram bot token 已外洩到日誌，需要輪替** | 只有使用者能對 BotFather 執行 `/revoke`；agent 不得建立或輪替憑證 | 這條通知鏈才重新可信；同時要決定既有 Loki 資料怎麼處理 |

**B10 是唯一有時效性的一項**，詳見 [§22](#22-telegram-bot-token-經由錯誤路徑外洩到日誌2026-09-03-發現)。
**B9 是其中唯一會讓其他所有工作歸零的一項**，且它會在每一輪工作結束時復發。
2026-09-08 的這一輪已推上遠端；下一輪的修正一樣只存在於工作目錄，直到你再說一次。

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

## 19. 「執行了，但沒有效果」——✅ 已修（2026-09-04）

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

### 修法與量測（2026-09-04）

**訊號早就在記錄，只是從來沒有被讀出來過**——`ingest_runs.content_sha256`。
量測顯示它有真實內容：多數來源**連續 3–4 次抓到完全相同的位元組**，
`cdc-tb-town` 是 4/4（它是年更新，那是對的）。

**門檻不能是「重複幾次」。** 週報來源被日排程抓，七次相同是健康的。
正確的門檻是**未變動的時間 vs 該來源自己的發布週期**——
而發布週期昨天已經從出版方目錄建好了（§20 的 `source_frequency.json`）。
**這就是為什麼 §19 的前提是 §20。**

| 產出 | 內容 |
|---|---|
| `dataops_source_unchanged_seconds` | 距離這支來源上次回傳**不同**位元組多久。成功抓到相同內容**不會**重置它 |
| `dataops_source_expected_interval_seconds` | 出版方宣告的週期，帶 `provenance` 標籤。**沒有依據的來源不發這個序列** |
| `SourcePublishedNothingNew` | `unchanged > 3 × expected`，`for: 1h` |

規則比較的是**兩個指標**而不是一張寫死在 `.yml` 裡的表——所以週期不會有第二份副本會漂移。
沒有依據的來源（`moi-admin-geography`）不發 interval 序列，join 直接把它丟掉、
永遠不會告警。**那是刻意的**：預設一個週期就是把猜測套上量測的外觀（§20 記過代價）。

**以評估驗收，不是以解析。** 這條規則 join 兩個指標族，
而同一個檔案裡的 `WidespreadGeoDrift` 正是因為少了 `group_left`
而「解析通過、promtool SUCCESS、每次評估都失敗、撐了 11 小時」——
那是 [ADR-0007](decisions/0007-verify-by-evaluation.md) 的起源。

- 合成控制四個案例（`rule_tests/dataops-emptyfetch_test.yml`）：
  超過 3× 會燒且帶 provenance／在週期內保持安靜／沒有 cadence 的燒不起來／剛變動過的安靜
- 突變測試證明控制能紅：**移除 `group_left`** 與 **把 3× 壓成 0.001×**，兩個都被殺死
- 活的 Prometheus：`health=ok`，join 產出 22 支，倍率最高 1.04×（門檻 3×）

### 修的過程中我把檢查放進了永遠不會執行的分支

新增的驗證區塊被插進 `if [ ! -x venv ]` 的 SKIP 分支裡——venv 存在，
所以那段**從來沒有執行過**，而套件報綠。斷言數從 26 沒有變成 30，
是那個數字露的餡。

**這正是這個 repo 在對付的形狀，而我在新增一個對付它的檢查時犯了它。**
沒有工具會抓到它：那段程式碼語法正確、在檔案裡、看起來像被執行。
唯一的訊號是「斷言總數沒有增加」，而目前沒有東西在看那個數字。
登記為 T12。

---

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

1. **停用 ubu 的休眠**——會休眠的筆電不是生產主機。ubu 上沒有免密碼 sudo。

   **狀態（2026-09-05 實測，不是記載）：只做了第二半。**
   `HandleLidSwitch=ignore` 與 `HandleLidSwitchExternalPower=ignore` 都已在
   `/etc/systemd/logind.conf` 生效——所以闔蓋不會睡。但 `systemctl mask` 那半**從未執行**：
   五個 sleep target 全部是 `LoadState=loaded／UnitFileState=static`（masked 會是
   `LoadState=masked`），而 logind 自己回答 `CanSuspend="challenge"`。
   **ubu 今天仍然會自行休眠**，因此 §27 的 T2 與 T7 的觸發條件「ubu 停用休眠之後」**尚未成立**。

   **闔蓋那半是承重的，不是裝飾**：ubu `hostnamectl chassis` 回 `laptop`，
   而 `/proc/acpi/button/lid/*/state` 此刻就是 `closed`——它現在還活著，
   靠的正是 `HandleLidSwitch=ignore`。

   指令不變（四個 target 就夠：實測 `systemd-suspend-then-hibernate.service`
   帶 `Requires=sleep.target`，遮蔽 `sleep.target` 即連帶擋住它）：

   ```bash
   ssh ubu
   sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
   sudo sed -i 's/^#\?HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
   sudo systemctl restart systemd-logind
   ```

   缺的不是指令是**驗收**。B1–B10 那張表只有三欄（阻塞什麼／為什麼只有你能解／解除後會怎樣），
   沒有 verify 欄——這是表格格式，不是 B7 特有的疏漏。但這個區塊是指令區塊，
   而一個沒有驗收方式的補救措施，「做完了」就是不可證偽的。補上：

   `verify`（任何人都可重跑，**不需要 root**）：
   ```bash
   ssh ubu 'busctl call org.freedesktop.login1 /org/freedesktop/login1 \
            org.freedesktop.login1.Manager CanSuspend'
   # 期望 s "na"     ← 已停用
   # 目前 s "challenge" ← 仍可休眠（2026-09-05 實測）
   ```
   用 `CanSuspend` 而不是列 unit 狀態：它問的是**行為**（這台機器還睡不睡得著），
   不是設定檔長什麼樣。

   **但要注意這個補救措施沒有涵蓋真正發生過的那件事。** 2026-09-03 ubu 兩次
   hybrid-sleep（15:26、15:45）都是**電池耗盡**觸發的，不是閒置、不是闔蓋、不是手動。
   遮蔽 sleep target 擋得住閒置與手動路徑，擋不住電量耗盡——那條路徑要靠
   「插著電」或 UPS，是實體條件不是設定。所以這一項做完之後，
   **不要把「ubu 不會再消失」當成已證明的事**。
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
| mDNS 本身失效時的退路 | ~~**會**——沒有 IP 就完全沒有第二條路~~ **2026-09-05 更正：第二條路已存在**（路由器 DNS：`ubu.home` → `192.168.1.144`，且對不存在的名字 11ms 回 NXDOMAIN，正是 mDNS 缺的否定回答）。固定 IP 降級為加固：把第二條路從「靠 lease 還在」變成「永遠成立」 |

`docs/Ubu-Prod-Bringup.md` 已經記過 `70.local` 那次教訓：**mDNS 可以單獨失效**。
固定 IP 的價值是「mDNS 壞掉時還有東西可用」，不是「kubeconfig 需要它」。

### ZTP 與 service discovery：**這個規模不採用，但架構軌跡要留著**

**使用者的更正**：這裡是小型試驗與雛形，未來到中醫大的醫院環境會增加很多機器。
所以結論不能寫成「不採用」就結束——**雛形的價值在於它知道自己會長成什麼**。
以下把每一層在**什麼門檻上變成必要**寫下來，而不是把它們丟掉。

#### 現在為什麼夠用

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

#### 擴張軌跡：每一層的門檻與觸發條件

**軸線是「機器是誰在數的」**：人 → DHCP 保留表 → 清單即程式碼 → 自我登記。
每一步都是前一步在某個數量上崩潰之後才成立的，不是能力升級。

| 階段 | 規模 | 命名／尋址 | 佈建 | 什麼時候該往下一階 |
|---|---|---|---|---|
| **A：現在** | 2 台 | mDNS（`ubu.local`），kubeconfig 用名字 | 手動 ＋ `bootstrap_k3s.sh`（冪等） | mDNS 跨網段失效，或有人**記不住**哪台是哪台 |
| **B** | 3–10 台 | DHCP 保留 ＋ 內部 DNS 區域（不再靠 mDNS） | Ansible／cloud-init 之類的**清單即程式碼** | 佈建一台需要有人**打字**，或清單開始與現實分岔 |
| **C** | 10–50 台 | 內部 DNS ＋ K8s 內的 CoreDNS（已有） | **ZTP**：PXE/iPXE ＋ 自動註冊 | 節點會**自己來又自己走**（汰換、擴充），清單追不上 |
| **D** | 服務數 ≫ 機器數 | **Service discovery**（Consul／etcd／K8s Service） | 同 C | 服務位置與機器位置**脫鉤**——同一個服務今天在這台明天在那台 |

**關鍵區別（本輪蒸餾出來的，不要再重推）**：

- **mDNS 與 service discovery 解的是不同的問題。** mDNS 是**主機層命名**：
  「`ubu` 這台機器在哪」。Service discovery 是**服務層尋址**：
  「`postgres` 這個服務現在由誰提供」。前者的答案一台機器一個，後者會隨調度改變。
  這個平台**兩者都已經在用**——mDNS 給主機，CoreDNS 給叢集內——
  只是規模還小到看不出它們是兩層。
- **ZTP 的成本全在建立佈建管線，而佈建在小規模只發生一次。**
  所以判準不是「機器多不多」，是「**機器會不會自己來又自己走**」。
  兩台固定機器就算變成五台固定機器，ZTP 仍然不划算；
  但只要開始有「這週加三台、下個月退兩台」，手動佈建就會變成事故來源。
- **醫院環境會先撞到 B 而不是 C。** 醫院網段通常**封鎖 mDNS 多播**
  （安全政策），所以第一個崩潰的會是階段 A 的命名，而不是佈建。
  這代表 **B 的內部 DNS 是進醫院前的必經之路**，而 ZTP 可以更晚。
  （這是推論不是量測——醫院網路政策要進去才知道，登記在 T2 的旁邊。）

#### 對現在的三個約束（讓雛形不會擋住 B/C/D）

1. **任何自動化不寫死 IP**（手冊第二節已記）。診斷可以用 IP，自動化不行。
   本輪已驗證 kubeconfig 走名字，這條約束目前成立。
2. **主機名要是穩定識別碼**，不是描述。`ubu` 撐得住換硬體；
   `mac.local` 那次教訓（曾停在 `70.local` 這個不解析的名字上）就是反例。
3. **佈建腳本必須冪等**——`bootstrap_k3s.sh` 已經是（「k3s already active，
   this script is idempotent, re-checking only」）。冪等是 B→C 的前提：
   ZTP 就是「把冪等腳本交給一個沒有人在看的流程」。

### 真正的缺口：沒有東西在驗證這條命名鏈

`probe_prod_cluster` 涵蓋「叢集回不回應」。它**沒有**分辨這三種：

1. `ubu.local` 解析不到（mDNS 失效）
2. 解析得到但 IP 變了、憑證 SAN 沒涵蓋新位址（TLS 失敗）
3. 機器睡著了（今天實際發生的）

現在三種都收斂成同一句「prod 叢集連不上」。**分辨它們需要不同的處置**，
所以這是一筆待辦（見下方 §27），不是現在要加的新功能。

---

## §28 新 session 的接手（2026-09-04）

**問題**：context 長度耗盡了大部分 usage，`compact` 幫不上忙，所以要開新 session。
交接文件最容易變成「讀起來很好、但下一個 session 無法據以行動」的東西。

**這個 repo 已經有三個索引**（README、本檔、`docs/decisions/`），
再加一個就是**兩份索引是分岔問題**。所以交接文件被寫成**路由器不是現況頁**：

- **裡面沒有任何數字。** 現況一律由指令產生
  （[Doc Provenance](Reachability.md)：手寫的現況會退化成信念，
  本專案已有三個實例）。
- 只放兩種東西：**指標**（去哪裡取得真相，都是可重跑指令）
  與**不可推導的判斷**（讀完整個 repo 也得不到、只有踩過才知道的）。
- **它的 `verify` 是真的**：`test_static.sh` 新增一條規則，
  斷言該文件裡指名的每一個路徑都還存在——
  一個指向已改名檔案的指標，會在下一個 session 最沒有 context 的時候把人送錯地方。

產出：[`docs/Session-Handover.md`](Session-Handover.md)，從 README 第一段連入。

**AIS 側**（跨 CLI 共用，只放與專案無關的通則）：

| record | 內容 |
|---|---|
| `bsd-gnu-portability-traps` | 四種在 macOS 綠、Linux 靜默失敗的寫法；真正的教訓是**錯誤訊息去了沒人看的 stderr** |
| `guard-matches-own-prose` | 文字比對的守衛活在它所搜尋的語料裡；六次之後是方法的性質不是疏忽 |
| `subshell-loses-state` | `$(...)` 裡的陣列累積會消失；第二次的代價是 421GB |

三筆都以 `docs/Backlog.md` 的實際章節為 source locator 並**釘上 digest**，
所以來源一改動就會被 `context audit` 標記，不會變成殭屍。
`context audit` → `active 20｜not-ready 0｜invalid 0`。

---

## §29 2026-09-04／05 這一輪：改了什麼、還欠什麼（給接手的人）

**未 commit。** 動到 6 個檔案（`git status` 為準）。三件事做完並驗收，兩件事狀態是
`UNVERIFIED`，其餘登記在 §27。

**做完的三件（都是既有東西的缺陷，不是新功能）**

1. `WidespreadGeoDrift` 的分母下限（T13）→ 見上方 T13 節。
2. 同一條規則的 `for` 在會睡的宿主上無法被滿足 → `max_over_time(...[1h])`。
3. `probe_prod_cluster` 丟掉 kubectl 的 stderr → `run_diag()`，只具名 SAN。

**兩件 `UNVERIFIED`，判準已寫好，不要當成已完成**

- `max_over_time` 在**生產環境**上還沒遇過睡眠。判準：下次醒來後
  `ALERTS_FOR_STATE{alertname="WidespreadGeoDrift"}` 的值**沒有前進**。
- promtool 那層在 ubu 跑不到（無 docker），所以規則測試**只在 macOS 驗過**。
  `run_on_ubu.sh` 跑的是 tier 1，會如實印出「tier 2/3 未跑」。

**2026-09-05 追加：非 Claude agent 的接手管道**

使用者要求 codex／agy／copilot 等也能接手。做了三件，**全部是文件與既有工具，沒有新程式**：

1. **`AGENTS.md`**（repo 根目錄，vendor-neutral 慣例入口）——**薄指標**，
   刻意不複製內容也不含數字，只指向 `docs/Session-Handover.md` ＋
   對所有 agent 都成立的硬規則與證據要求。理由：兩份索引就是一個分岔問題。
2. **`test_static.sh` 的路由守衛擴充成掃兩份**（Session-Handover ＋ AGENTS.md），
   共用同一個迴圈而不是複製一份檢查。斷言數 376 → 377。
3. **AIS 中立層兩筆知識記錄**（跨 AI 唯一共用管道）：
   `sleeping-host-breaks-continuity`、`nondeterministic-error-strings`。
   已補 locator（**必須是標題**，正文粗體字不算）與 digest，
   `context audit` 由 `not-ready 2` 轉為 `active 21｜not-ready 0`；
   並加上 `devops`／`platform` tag，讓 AGENTS.md 教的
   `context resolve --tags devops,platform` **實測取得到**——
   否則那份文件會教一個回傳不到東西的指令。

**這一輪犯過並修掉的錯，形狀值得記住**

| 錯 | 為什麼測試抓不到 |
|---|---|
| 分母下限放進告警而非 recording rule | 面板讀 recording rule，兩邊各持一份定義。是**敘述**與**佈局**錯，不是程式錯 |
| 交叉引用把這台 Mac 的休眠指到講 ubu 的 B7／§13 | 引用錯機器，語法完全正確 |
| 多加一個被 `Requires=sleep.target` 連帶擋住的 systemd target | 多做一件無害的事，沒有任何檢查會反對 |
| 新 `run_cmd` 插進既有斷言區塊中間 | `assert_output_contains` 讀**最後一個** `run_cmd`，三個舊斷言被靜默改指 |

前三個是**對抗式複審**抓到的，不是測試。**改完之後把「我剛才主張了什麼」也送去複審**，
特別是跨檔案的引用與機器名——那是測試看不到的地方。

## §30 從 Grafana 倒推回 data digest：七層逐節驗證（2026-09-08）

**做法**：不是讀程式碼推論，是**從長官會打開的那個畫面出發**，一節一節往回問
「這個數字是誰算的、他讀了什麼」，每一節都要有可重跑的指令回答，不接受「應該是」。
中間任何一節省略，錯誤就會躲在被省略的那一節裡——這一輪找到的三個缺陷有兩個
正好躺在平常會被跳過的兩節（textfile 掛載、settle 規則的第二份副本）。

### 這條鏈長什麼樣（每一節都附當時用來確認的指令）

| # | 這一節 | 怎麼確認的（可重跑） | 結果 |
|---|---|---|---|
| 0 | 長官打開的那個 Grafana 真的在服務這份 JSON | `docker exec observability-grafana-1 sha256sum /var/lib/grafana/dashboards/*.json` 與本機檔比對 | **三張逐位元相同**；provisioning 日誌只有 plugins／alerting 目錄不存在的良性錯誤 |
| 1 | 三張看板共 34 個 panel target | 解析 `platform/observability/grafana/dashboards/*.json` 取出每個 `expr` | 34 個運算式，1 個是 Loki |
| 2 | 每個運算式在 Prometheus 有沒有值 | 逐條打 `/api/v1/query` 數 result 長度 | **33/33 有值，零空面板** |
| 3 | 指標由哪個 rule／哪支程式產生 | `grep -rl <metric> platform/` | 公衛三個指標全部收斂到 `platform/dataops/pipeline_metrics.py` |
| 4 | `.prom` 檔怎麼進到 Prometheus | `docker inspect <node-exporter> --format '{{range .Mounts}}…'` | `evidence/statusdag` → `/textfile`，`--collector.textfile.directory=/textfile`，job `platform-dag` |
| 5 | 產生器讀什麼 | 讀 `drift()`：`M.cmd_check()` 擋鏡像過期，之後全部在 DuckDB 上算 | parquet 鏡像，非 Postgres |
| 6 | 鏡像從哪來 | `evidence/analytics/mirror_manifest.json` | `surveillance_fact` 等 5 表，watermark `max_ingest_id=179`、6,534,834 列 |
| 6a | 鏡像與 Postgres 是否真的一致（不採信 manifest 的自我宣稱） | 兩邊各跑 `count(*)` 與 `sum(value)` | **6,534,834 列／453,416,484 逐值相同** |
| 6b | 事實表的血統守恆 | `\d ingest_runs` 的 CHECK | `rows_in_file = source_rows_accepted + rows_rejected + duplicate_rows`，且每批都存 `content_sha256` |
| 7 | 事實表從哪來 | `pilots/station2-twin/ingest/load_dimensional.py` 的 `url=` | `https://od.cdc.gov.tw/eic/*.csv`（疾管署開放資料）—— **digest 的底** |

**端到端對帳（證明鏈是真的通的，不是看起來通的）**：
Prometheus 上 `dataops_yoy_ratio{disease_id="24"}` = `4.548152`；
直接對鏡像算 `19316/4247` = `4.548152`。`disease_id="35"` = `0.900943` = `191/212`。
**逐位相同**，所以第 2–6 節之間沒有第二個算式在偷偷插手。

### 缺陷一：長官看到 FAIL「scheduler not running」，真相是筆電睡著了

`platform/scheduler/status.sh` 在 10:39 判 `board`／`dag`／`stagereport` 三個 15 分鐘
任務停在 48–51 分鐘前，`dag.py` 據此把 `scheduler` 節點打成 **fail**，`verdict: FAILED`。

實測：`sysctl -n kern.waketime` → 最後喚醒 **10:31:51**；三個任務的
`evidence/scheduler/<job>_last.json` 顯示 09:53 之後沒有紀錄，喚醒後 10:42 陸續補跑。
`.launchd.log` 全是 `ok (rc=0)`，**沒有任何一次失敗**。

也就是說：**這個 FAIL 說的是「本機睡了 38 分鐘」，不是「排程壞了」**。
`launchd` 的 `StartInterval` 在睡眠期間不觸發，醒來也不補齊次數——這件事
AIS 的 `sleeping-host-breaks-continuity` 已經記過，但**寫的是告警的 `for:`，
沒有回頭套用到 scheduler 探針**。一份記錄只修了發現它的那個地方，
就是「登記為存在，但不執行」的變形。

**本輪不修**，登記為 T19：修法要決定的是「睡眠窗要不要算進 SLA」，那是使用者的決定不是我的。

### 缺陷二：`dataops_yoy_ratio` 標「全國」，而它不是全國（2026-09-08 修標示）

`cur_total` 與 `prev_total` 是在 `cur JOIN prev ON disease_id AND geo_code` **之後**才加總的，
所以**今年有回報、去年沒有的地區，會從分子分母同時消失**。而 HELP 寫的是
"National total"，panel 標題寫的是「全國」。

實測 13 支疾病：

| disease | 今年真全國 | 內連後 | 地區數（今年／內連／去年） |
|---|---|---|---|
| 35 急性出血性結膜炎 | 193 | **191** | 21 / **20** / 20 |
| 其餘 12 支 | — | 完全相同 | 22 / 22 / 22 |

板面顯示 `0.900943`，真正的全國比值是 `193/212 = 0.910377`。今天差 1.04%，
但**誤差沒有上界**：新增一個縣市回報，它整筆會從分子消失。

**修法是改標示不是改查詢**。內連是刻意的——沒配對到的地區否則會長得像真的年對年變化，
而那正是這個指標要偵測的東西。所以：HELP 改成寫明「只加總兩年都有回報的地區」並帶上實測數字，
panel 標題改為「年對年比值（**可比地區**，最近一個已結算疫情週）」，description 補上受影響的疾病與筆數。
`T14`（`prev` 側完整度守衛）**維持登記狀態**：那才是「把數字修對」的那一半，本輪只修「不要說謊」的那一半。

### 缺陷三：settle 規則的 12 週視窗每年一月會塌陷（2026-09-08 修）

settle 規則是「取最近一週，其地區涵蓋數 ≥ 前 12 週的中位數」。前 12 週寫成
`p.yw >= c.yw - 12`，而 `yw = epi_year*100 + epi_week`。**這只是「同一年之內」的週算術**：
在 2026w01，它要的是 `[202589, 202600]` 這個沒有任何一週能落在的區間。

實測（真實鏡像，2026-09-08）：

| 週別 | `cov` 有的 (disease,week) 組合 | 進到中位數視窗 | 遺失 |
|---|---|---|---|
| week = 1 | 191 | **0** | **191（全部）** |
| week ≤ 12 | 2,291 | 2,100 | 191 |
| week 13–52 | 7,445 | 7,444 | 1（資料集的第一週，應該的） |

後果**每年一月發作一次而且不會叫**：把同一份鏡像截到 2026w01，
舊寫法選出 `202553`、新寫法選出 `202601`。舊寫法會把**一年前的那一週**
掛上「最近一個已結算疫情週」的標籤，然後拿它跟**兩年前**比。
這與 §20 修掉的 `- 100` 是同一個病：結構性看不見當年，而且數字看起來完全合理。

**修法**：改用 DuckDB 原生窗口框
`MEDIAN(geos) OVER (PARTITION BY disease_id ORDER BY yw ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING)`。
`ROWS` 數的是**排序後的位置**，年界對它不存在。順帶把自連接整段移除——程式碼是變少的。
第一列的框是空的會得到 `NULL`，等同舊寫法對第一週的丟棄，所以 `latest` 明確加了 `med_geos IS NOT NULL`。

**驗收**：
- 正控制：鏡像截到 2026w01 → 必須得到 `202601`（壞的寫法得到 `202553`）
- 負控制：截到 2026w02 → `202602`；不截 → `202635`，**與修改前完全相同**
- 回歸：重跑 `platform/dataops/run.sh`，`dataops.prom` 所有非時間類指標**逐行相同**
- 突變測試：把 CTE 換回舊的自連接 → `45 passed` 變 `44 passed, 1 failed`，
  且失敗的正是年界那一條；還原後以 `cmp` 驗證檔案逐位元相同

### 缺陷四：settle 規則有兩份副本，而其中一份的註解說「只有一份」

`platform/dataops/settled_week.py` 的 docstring 寫著
「extracted from the test so the settle rule has exactly one implementation」，
但那段 SQL 同時存在於 `pipeline_metrics.py`。測試套件跑的是 `settled_week.py`。

這件事在**本輪當場發作**：缺陷三的修正先落在 `pipeline_metrics.py`，於是那一刻
生產用的是修好的查詢、測試驗的是壞掉的副本——**套件會繼續替一段沒人執行的 SQL 背書**。
這是本 repo 自己編目的「兩份索引是分岔問題」，加上「註解描述的機制不等於機制存在」。

**修法**：規則定義成 `pipeline_metrics.SETTLE_CTE` 一份，`settled_week.py` 改成 import 它。
新的年界控制項也是對 `SETTLE_CTE` 求值，不是對副本求值——
**守衛如果驗的是副本，它防的就是副本而不是生產**。

### 本輪之後仍然 UNVERIFIED 的事

| 事項 | 為什麼還不能宣告已驗 | 什麼時候能驗 |
|---|---|---|
| 年界修正在**真實一月**的行為 | 控制項是把資料搬過去，不是把時間搬過去 | 2027w01 當週看 `settled_week.py` 的 `LAG_OK` |
| `max_over_time` 抗睡眠（§29 沿用） | 載入後尚未遇到一次夠長的睡眠窗 | `ALERTS_FOR_STATE{alertname="WidespreadGeoDrift"}` 在下次喚醒後不得前進 |
| promtool 規則測試在 Linux | ubu 無 docker，該段在 ubu 上是 SKIP 不是 PASS | ubu 裝上 docker 或改用本機 promtool 二進位 |

## §31 MLOps 那條鏈，以及跨 session 的遺漏稽核（2026-09-08）

§30 從 Grafana 倒推到疾管署 CSV，走的是 **devops 與 dataops** 兩條。
使用者指出漏了 mlops，而且點名了要看的東西：
**「model prediction's evaluation score over current model score」**。這一節補上。

### 一、MLOps 這條鏈的實際樣子（同樣逐節，同樣附指令）

| # | 這一節 | 怎麼確認的 | 結果 |
|---|---|---|---|
| 1 | 長官在看板上看得到什麼 mlops | `platform-stages.json` 的三個 mlops panel | 只有**節點燈號與歷程**，`devops_node_state_code{layer="mlops"}` |
| 2 | Prometheus 裡有沒有任何模型指標 | `/api/v1/label/__name__/values` 全掃，正則 `model\|forecast\|mae\|baseline\|train\|predict` | **99 個指標，零筆與模型有關** |
| 3 | 那 `-12.08%` 從哪來 | `dag.py` 的 `probe_model_gate` | 只活在**節點 detail 的字串**裡，沒有時間序列 |
| 4 | 閘門讀什麼 | `model_run`：`mae`／`baseline_persistence_mae`／`split_strategy`／`horizon_weeks` | 14 筆 run，`code_sha256` 全部相同（`b27a652e`），自 08-20 未變 |
| 5 | 誰決定上線 | `pilots/station2-twin/mlops/publish_forecast.py` | `WHERE beats_baselines ORDER BY mae ASC LIMIT 1` |
| 6 | 上線了什麼 | `forecast` 表 | 2 筆，出自 run 2（2026w34）與 run 12（2026w36），**都是 t+2** |
| 7 | 有沒有人回頭看預測準不準 | grep 全 repo：`forecast` 與 `fact/actual/observed/error/score` 同時出現的程式 | **沒有。零筆。** |

### 二、找到三個問題

#### 2-1 板面報的是「歷來最佳」，句子讀起來像「現在」（已修）

`probe_model_gate` 取出所有 rolling-origin run，然後 `max(margin)` per horizon。
2026-09-08 的實測是 t+1 `-12.08%`／t+2 `+0.55%`——**剛好是對的**，
因為至今每次重訓都在進步。**會暴露它的是第一次退步的那次重訓**，
而歷史裡已經有一筆 t+1 `-56.25%` 被這個 max 藏了從 08-20 到現在。

**修法**：改取**每個 horizon 最新的那次 run**（`DISTINCT ON ... ORDER BY trained_at DESC`），
並在旁邊加上**目前線上那個 run 的分數**。板面現在說：

```
t+1 最新 run13 -12.08%（尚未上線）／t+2 最新 run14 +0.55%（線上 run12 +0.55%）
```

**這正是使用者要的那個比較**，而且它同時讓一件事**可見**：
閘門本身**從來沒有拿候選模型跟線上模型比過**，它只跟持平基準比。
把兩個數字並列不會讓閘門多做那個比較，但會讓「它沒做」從看不見變成看得見。

**驗收**：SQL 抽成 `dag.MODEL_GATE_SQL`，測試用 **DuckDB 對合成回歸資料求值**
（舊 run 贏 10%、最新 run 輸 30%，線上是舊那個）——
`max` 會報 `+10.00`，正確的要報 `-30.00`。突變測試把 `ORDER BY trained_at DESC`
改成 `ORDER BY pct DESC`，兩層斷言同時變紅；還原以 `cmp` 驗證。

#### 2-2 沒有任何東西把已發布的預測跟真實發生對帳（已補節點）

mlops 那一列五個節點全綠，而**這個 pilot 從來沒有一筆預測被評分過**。
回測不是這件事：rolling-origin 的 MAE 是拿模型去比它**被擬合圍繞的歷史**；
事後評分是拿**真的發出去的那個數字**，比**真的到來的那一週**。

這是本 repo 目錄裡「登記為存在，但不執行」的形狀，升了一層——
**登記的是一整個 layer 的綠燈**。

**第一次評分的結果（2026-09-08）**：

| forecast | 目標週 | 起點觀測 | 模型預測 | 實際發生 | 模型誤差 | 持平基準誤差 | 判定 |
|---|---|---|---|---|---|---|---|
| 3（run 2） | 2026w34 | 0.018875 | 0.019779 | 0.021828 | **0.002048** | 0.002953 | 模型勝 30.6% |
| 7（run 12） | 2026w36 | 0.021932 | 0.023564 | — | — | — | 目標週尚未有資料 |

**n=1。這不證明任何事**，而且刻意寫進節點的 detail 裡（`n=1，尚不足以下結論`），
因為 `1/1` 這種字串在板面上讀起來像戰績。有趣的是它跟回測不一致：
回測說 t+2 只贏 `+0.55%`，唯一一筆能評分的實際觀測贏了 `30.6%`。
**兩個都是真的，只是問的不是同一個問題**，而在這之前板面上只有前者。

**單位是這件事最容易出錯的地方，寫進註解**：`predicted_value` 是
`nhi_visits / denominator` 的**比率**。若把 `surveillance_fact.value` 跨 metric 加總
當成「實際值」，會得到 `18286` 對上預測 `0.0198`——差三個數量級，
而那個比較**在 SQL 上完全合法**。所以事後值是用
`build_features.weekly_series` 的**同一組分子分母**重算的。

**寫這個節點時當場犯的錯，以及它變成的控制項**：`actual` CTE 依
`geo_code, visit_type` 分組卻沒 SELECT 也沒 join，LEFT JOIN 於是把 2 筆預測
**扇開成 44 列**，節點顯示「22/44 勝過持平基準」。
**那個字串沒有任何一處看起來不對**，n 還變得比較健康。
抓到它的是不變量：**探針評分的筆數不可能多於 `forecast` 表的列數**。
突變測試（拿掉 join 條件）證明這條不變量會紅。

#### 2-3 概念漂移（model drift）完全不存在——這是跨 session 稽核找到的

見下一小節。

### 三、跨 session 稽核：方法與結果

**為什麼要做**：可觀測性與可達性的對象不只是系統，也包括**我們自己的決定**。
一件事在某次對話裡被要求過、當時沒做、後來沒人記得，
在 repo 裡長得跟「從來沒被要求過」一模一樣。

**方法（可重跑）**：

```bash
grep -rl -i 'devops' ~/.claude/projects --include='*.jsonl' | grep -v '/subagents/'
# 逐檔抽出 type=='user' 的訊息（不含工具結果、不含 local-command），離線比對
```

7 個 session、**699 則使用者訊息**（08-11 至 09-08）。抽出後逐條對照 repo 是否有落點。

| 曾經要求的事 | 落在哪裡 | 判定 |
|---|---|---|
| Spark 的取捨 | `docs/decisions/0002-spark-scope.md` | 有 |
| DuckDB 分析鏡像 | `0003`／`mirror_manifest.json` | 有 |
| 不導入 ELK，改 Loki | `0011-loki-not-elk.md` | 有 |
| OTel 在邊界、後端延後 | `0012-otel-at-the-boundary-backend-deferred.md` | 有 |
| 轉 K8s，k3s 為先 | `0010-kubernetes-target-runtime-k3s.md` | 有 |
| 兩台機器兩種指令集、原生建置 amd64 | `0008-two-machines-two-architectures.md` | 有 |
| Vault「兩台都放」 | `docs/Ubu-Prod-Bringup.md` 第五節 | 有 |
| Docker.raw／磁碟監控 | `0014-host-disk-was-unmeasured.md` | 有 |
| 資料迴路要真的在跑 | `0013-pilot-loop-was-open.md` | 有 |
| 可達性樹狀圖、不要孤兒文件 | `docs/Reachability.md`／`platform/docs/doc_graph.py` | 有 |
| email 通知（zhe0@…） | 板面 `alertmgr` 明說「宣告了但沒接上: email」 | 有（已知缺口，非遺漏） |
| GitHub topics 生態調查 | 原 `docs/Ecosystem-Scan-2026-08.md`，2026-09-09 刪除（ADR-0018）；結論落在 ADR-0001／0002，活的缺口遷移為 §27 T29 | 有 |
| **「mlops 有定期更新 model and drift detect 嗎？」** | 重訓有（`retrain` 每週）；**drift detect 沒有** | **遺漏** |

**唯一的遺漏**：`grep -rilE 'concept drift\|model drift\|模型漂移\|概念漂移\|drift detect'`
在 `docs/`、`platform/`、`pilots/` 回傳**零筆**。repo 裡所有的 "drift" 都是
**資料漂移**（`dataops_yoy_geo_drift_*`，比較的是今年與去年的資料分布），
沒有一處是**模型漂移**（比較的是模型在新資料上的表現與它上線時的表現）。

兩者名字像、意思完全不同，而且**資料漂移的存在會讓人以為漂移這件事已經被顧到了**——
這正是它能潛伏兩週沒被發現的原因。

登記為 T20。**2-2 的事後評分節點是它的前提**：沒有「預測 vs 實際」的歷史，
就沒有東西可以拿來判斷模型的表現有沒有隨時間退化。

## §32 模型層從「一個寫死的模型」變成註冊表（2026-09-08）

**要求**：模型要能多種設計、要有擴充性，而且**長官要知道怎麼擴充**。
完整的擴充指南在 [`docs/MLOps-Model-Extension.md`](MLOps-Model-Extension.md)；
這一節只記**改了什麼、為什麼、以及怎麼證明它沒改壞**。

### 改之前的實際狀態（不是印象，是 grep）

`model_run` 的 schema 從第一天就有 `algorithm`、`hyperparams`、`feature_set_id`、
`seed`、`code_sha256`——**一個說「支援很多模型」的結構**。程式碼裡只有一個模型，
而且它的身分被**手抄成三份**：

| 位置 | 內容 |
|---|---|
| `run_rolling` 的建構子 | `HistGradientBoostingRegressor(max_iter=60, max_depth=3, learning_rate=0.05, ...)` |
| `run_random_split` 的建構子 | 同上，第二份 |
| banner 的 print | `"HistGradientBoostingRegressor(60, depth 3, lr 0.05)"` 字串 |
| `INSERT INTO model_run` | `"HistGradientBoostingRegressor"` ＋ 重打一次的 hyperparams dict |

**換模型時只要漏改一處，`model_run` 就會用上一個模型的名字記錄新模型的數字**——
比沒有 provenance 更糟，因為之後每一次比較都繼承這個謊。
這是「兩份索引是分岔問題」的四份版本。

### 改了什麼

一個 `MODELS` 註冊表，四個地方全部從它讀。一筆登記必須宣告六件事
（`family`／`build`／`hyperparams`／`handles_nan`／`nan_policy`／`deterministic`），
理由逐項寫在 `backtest.py` 的註解裡。加上 `--algorithm` 與 `--list-models` 兩個旗標。

**未登記的名稱一律拒絕並列出清單，絕不預設回退。**
`--list-models` 也跑同一個守衛：**列得出來的就必須是選得起來的**，
否則那份清單又是一個「登記為存在，但不執行」的目錄。

### 第二個家族是真的，不是宣稱

**一個只有一筆的註冊表，跟寫死是同一件事穿上機制的外衣。** 所以加了 `Ridge`
（統計／線性），而且**跑完寫進資料庫**（run 15／16），不是紙上數字。

同一批折、同樣基準的實測：

| 模型 | 家族 | t+1 | t+2 | t+2 方向準確率 |
|---|---|---|---|---|
| HistGradientBoosting | 梯度提升樹 | −12.1% | **+0.6%** | 63.8% |
| Ridge | 統計／線性 | −22.0% | −11.0% | 62.0% |

Ridge 兩個 horizon 都輸持平基準，`beats_baselines=False`，
**閘門直接拒絕它**——機制在運作，而且現在有第二個模型可以示範這件事。

**加第二個模型當場暴露的設計缺口**：在只有一個模型時，「最新一次 run」是明確的；
有了第二個家族之後，樹模型與線性模型的數字會**輪流佔用同一格**，
板面會讀成「同一個模型時好時壞」。所以 `MODEL_GATE_SQL` 一併帶出 `algorithm`：

```
t+1 最新 run15 Ridge -21.99%（尚未上線）／t+2 最新 run16 Ridge -11.01%（線上 run12 +0.55%）
```

這一行同時回答了使用者原本問的那個問題：**挑戰者的分數與線上模型的分數並列**。

### 缺值：這是決定「哪些家族加得進來」的那個條件

樹模型原生吃 NaN，所以現行模型從來沒碰到這題。**線性與深度模型都會碰到**，
而這份資料的缺值不是雜訊：

| 特徵 | 556 列中 NULL | 原因 |
|---|---|---|
| `covid_lag_1` | **288（51.8%）** | COVID 2020 才開始，序列回溯到 2015 |
| `same_week_last_year` | 52（9.4%） | 第一年沒有去年 |
| 其餘 | 1–4 | 序列開頭 |

**丟掉不完整的列＝丟掉一半歷史且全部是 2020 以前；靜默填補＝發明一段
2020 年以前的 COVID 訊號。** 所以 `handles_nan=False` 的登記**必須**附
`nan_policy`，否則註冊表拒絕啟動。Ridge 的政策用 sklearn 的 `Pipeline`
（`SimpleImputer(add_indicator=True)` → `StandardScaler` → `Ridge`），
填補的統計量**每折只從訓練列學**——不是自己寫的迴圈，所以沒有自己寫錯 leak 的空間。

### 驗收

- **行為不變**：重構後以排程實際使用的旗標（`--predict-delta`）重跑，
  t+1 `-12.1%`／t+2 `+0.6%`，與紀錄中的 `-12.08%`／`+0.55%` 相符
- **新套件** `platform/tests/test_model_registry.sh`：13 個斷言，tier 1，需要 pilot 容器不需要資料庫
- **突變測試（兩次，皆以 `cmp` 驗證還原）**：
  - 拿掉 Ridge 的 `nan_policy` → 5 條斷言變紅（`--list-models` 自己就會失敗）
  - 整筆移除 Ridge → 「a SECOND family is registered」等 4 條變紅

### 這一輪自己犯的錯（記下來，因為它有形狀）

把 `algorithm` 加進 `MODEL_GATE_SQL` 之後，**只驗了實機板面就往下走**——
板面顯示正確，所以看起來沒事。但那段 SQL 有一個 DuckDB 夾具在測試裡對它求值，
夾具的 `model_run` 沒有 `algorithm` 欄，於是 `test_dataops_metrics.sh` 六條斷言全紅，
而我是在跑全套時才發現的。

**形狀**：改了一段被兩個地方使用的東西（生產路徑與測試夾具），
只驗了其中比較顯眼的那一個。「板面看起來對」證明的是生產路徑，
不是「所有讀這段 SQL 的地方都還成立」。

**代價**：一次 437 秒的全套。**判準**：動到被抽出來共用的常數
（`MODEL_GATE_SQL`、`SETTLE_CTE` 這類），就要跑那個常數的**所有**消費者，
而不是最容易看到結果的那一個。

### 沒做，而且刻意沒做

**沒有加深度學習模型。** 不是因為麻煩，是因為 **556 列**。
`min_train=104` 之後可回測 451 折，特徵 12 個。
LSTM／TCN／Transformer 在這個規模上不是「有點少」，是少兩個數量級。
硬跑會得到一個過擬合的模型與一個好看的隨機分割分數，
而這個 repo 已經有 `--also-wrong-split` 專門示範那個數字長什麼樣。

要做深度學習，**先解決資料量，不是先解決模型**：現在的目標是
「單一地區（66000）／單一就診別／單一疾病」的一條序列；
22 縣市 × 13 疾病 = 286 條序列的全域模型才有話講，
而那要重新定義 `feature_set`——是新範圍，不是這一輪。

## §33 MLOps 那條鏈的第二次倒推：這次走進「寫這張表的那支程式」（2026-09-08 下半場）

### 一、先講為什麼上一輪會漏

§31 補上了 `fcscore`（預測事後評分），那是真的缺口。但**倒推在 `forecast`
這張表就停了**：確認了表裡有兩筆、確認了 trigger 會擋輸掉的模型、確認了
API 只做 SELECT。沒有做的是**打開寫這張表的那支程式**。

倒推法的規則是「每一跳都要有可重跑指令」。`forecast` 那一跳我拿到的是
「trigger 存在且會擋」——那證明了**沒有輸家被寫進來**，
沒有證明**寫進來的贏家就是被評分的那一個**。

> 這是目錄裡「可達不等於還是真的」的一個新變體：
> **「擋住壞的」不等於「放進來的是對的」。**
> 閘門是必要條件不是充分條件，而必要條件在看板上長得跟充分條件一樣。

### 二、逐節點重問一次：這個節點量的是什麼，不量什麼

| 節點 | 它證明 | 它**不**證明 | 本輪處置 |
|---|---|---|---|
| `features` | 特徵表建出來了、列數 | 特徵值對不對 | 未動（既有 no-lookahead 守衛） |
| `backtest` | 有 rolling-origin 評分 | 評的是哪個模型（家族已上板，設定沒有） | `predict_delta` 進 `hyperparams` |
| `mgate` | 閘門會拒絕輸家 | **放行的那個是不是最該放行的** | T22 做掉，見下 |
| `forecast` | 表裡有列、trigger 沒被繞過 | **列裡的數字是不是那個 model_run 產生的** | 發布路徑改走註冊表 |
| `fcscore` | 發出去的數字對不對 | n=1，還不能下結論 | 未動（T20 等資料） |

### 三、找到的三個缺陷（都已修）

**（1）發布時重建的永遠是 HGB，不管贏的是誰。**

`publish_forecast.py` 直接 `from sklearn.ensemble import
HistGradientBoostingRegressor`，然後用**贏家 run 的 `hyperparams`**
去餵它，而且是 `hyper.get("max_iter", 60)` 這種讀法。所以如果 Ridge 贏了
某個 horizon，發布出去的會是：**一個 HGB 的擬合結果，掛著 Ridge run 的
`model_run_id`，帶著 Ridge run 的 MAE**。`alpha` 被無聲丟棄，
三個 HGB 超參用預設值補上。

資料庫裡 Ridge（run 15/16）和 HGB 都在。**只是因為 Ridge 兩個 horizon 都輸，
這件事今天還沒發生過。**

這是 §32 剛做完註冊表之後**立刻**存在的分岔：註冊表只覆蓋訓練端，
發布端是第二份實作。跟 settle 規則那次一模一樣的形狀，隔了半天又長一次。

修法：`backtest.fit_one()` 成為**唯一**的擬合路徑，折內與最終重擬合共用；
`publish_forecast.py` **一行 sklearn import 都沒有**，只能透過註冊表建模型；
測試斷言這兩件事（`grep -c '\.fit('` == 1、publisher 不得 import sklearn）。

**（2）跨 feature set 比 MAE。**

`ORDER BY mae ASC LIMIT 1` 掃的是**所有** feature set 的 run。
migration 013 自己寫過一句話：

> a baseline evaluated on different folds is not a comparison, and that
> mismatch is invisible in a single reported number

——然後隔壁那張表的 publisher 就是這樣寫的。**同一個錯誤，隔一張表。**
551 折的 0.001682 和 553 折的 0.001680，印出來一樣長，意思不一樣。

今天剛好是新 feature set 的 run 較低，所以線上是對的。**那是運氣不是規則。**

修法：候選只取**目前 feature set**；現役模型拿它**在目前 feature set 上
重新評的分數**來比，而不是把舊分數搬過來。現役在目前 feature set 上
沒有分數時，判 `INCOMPARABLE`——**被命名的狀態，不是靜默當它輸。**

**（3）target convention 只存在散文裡。**

`--predict-delta` 決定模型學的是「下週的值」還是「下週的變化」，
而它只被記在 `notes` 的句尾（`target = level` / `target = change ...`）。
`publish_forecast.py` 從來沒讀 `notes`，**無條件當成 delta**。

run 3 是 level run。它輸了，所以沒事。**贏了的那天，發布出去的會是一個
沒有任何評分涵蓋過的數字，而每一件產物看起來都正常。**

修法：migration 016 把 `predict_delta` 從散文搬進 `hyperparams`
（依 `notes` 一次性回填，並 `CHECK` 強制往後每一列都要有），
發布端讀不到就拒絕發布。

> 回填讀了散文——那是**一次性、在審查下、寫在 migration 裡**的讀。
> 和「讓程式長期依賴散文」是兩件事。

### 四、機制上的改進（不只修這三個）

1. **註冊表契約上移到 `platform/mlops/model_registry.py`**，pilot 的容器
   以唯讀掛載取得。契約與條目分離：契約無領域知識，條目帶 pilot 的理由。
2. **`check_buildable()`**：`--list-models` 現在會**真的呼叫每個 `build()`**，
   並拒絕回傳「已擬合估計器」的條目。用**突變測試**驗證這條守衛會紅，
   還原後以 `cmp` 逐位元比對（§5c）。
3. **汰換規則抽成 `platform/mlops/promotion_policy.py`**，
   **不給預設門檻**——沒想過門檻的專案應該被逼著想，不是拿到 0.02 和一片沉默。
4. **看板那行門檻是讀出來的**（`dag.py` 的 `replacement_margin()` regex 讀
   `publish_forecast.py`），不是第二份手抄。

### 五、重構沒有改變行為的證據

| 檢查 | 期望 | 實測 |
|---|---|---|
| t+1 delta rolling MAE（feature_set 55） | run 13 = 0.001319 | `0.1319 pp` 逐位相同 |
| t+2 delta rolling MAE（feature_set 55） | run 12/14 = 0.001680 | `0.1680 pp` 逐位相同 |
| t+2 重擬合後的預測值 | forecast 7 = 0.023564 | `2.3564 pp` 逐位相同 |
| `test_model_registry.sh` | — | 31 passed, 0 failed |

第三列是最有意義的一列：**整條擬合路徑換掉之後，發布端算出來的數字和舊路徑
逐位相同。**

### 六、migration 016 連帶掀出來的三個東西（不是預期中的收穫）

套用 migration 016 之後，Kubernetes 上的兩個顏色**全部 503**——
`EXPECTED_SCHEMA_VERSION` 在四個地方各寫一份，
`pilots/station2-twin/tests/test_contract.py` 只檢查其中三個：

| 副本 | 之前 | 被誰檢查 |
|---|---|---|
| `config.example.env` | 15 → 16 | ✅ test_contract |
| `compose.yaml` | 15 → 16 | ✅ test_contract |
| `app/app.py` | 15 → 16 | ✅ test_contract |
| `platform/k8s/station2-twin/deploy.sh` 的 `${3:-15}` | **15，沒人動** | ❌ **沒有** |

那段程式的註解自己寫著：「版本住在三個檔案裡；只檢查兩個的測試，
certifies a consistency that does not exist」——**然後它自己就是第四份。**

修法：`deploy.sh` 改成從 `config.example.env` **讀**預設值，
`test_contract.py` 斷言這條推導還在（不是比對兩個字面值），
`test_bluegreen.sh` 三處寫死的 `15` 拿掉改用推導值。
守衛以突變測試驗證會紅（改回字面值 → 紅；還原後 `cmp` 逐位元相同）。

**（2）板面的「藍綠切換」在兩個顏色都 503 的時候是綠的。**

它讀的是 Service selector——那回答「流量被定址到哪個顏色」，
不回答「那個顏色有沒有在服務」。**流量有去處，沒有服務，板面說 ok。**
和上面 mgate 那件事同一個形狀，只是換一層：
**指標存在不等於指標後面有東西。**
已改成同時數該顏色的就緒 pod：0 個就緒 → `fail`，部分就緒 → `warn`。

**（3）`probe_prod_cluster` 的 jsonpath 從來沒有成功執行過。**

```python
"jsonpath=...{'\n'}{end}"     # Python 先把 \n 變成真的換行
```

kubectl 收到的是「未終結的引號字串」，rc=1、stdout 空。
下一行把空輸出讀成「沒有工作負載」，於是節點永遠顯示
**「叢集就緒但沒有任何工作負載」——而這句話在真的沒有工作負載時也是對的**，
所以它躲過了每一次檢視。是在修 `probe_bluegreen` 時踩到同一個坑才發現的。

已修（改用 `{"\\n"}`），並以本機 k3d 叢集實測同一個 jsonpath 形式
回傳 5 個 namespace（rc=0）。**ubu 關機中，端到端仍為 `UNVERIFIED`。**

**復原過程本身又長出第四個**：我用 `docker compose up -d twin` 重啟 compose 那份，
而正確的入口是 `platform/recover.sh`——它會先寫 `.env.vault` 再帶 `--env-file` 起。
少了那一步，app 走**靜態密碼**回來，Kubernetes 那份走 Vault，
兩份副本的憑證模型分岔。`test_migration_observed.sh` 當場抓到
（`develop='static' but k8s='vault'`）。**這個守衛是 2026-09-01 同一件事發生後加的，
這次它做了它該做的事。** 復原方式：`write_pilot_approle_env.sh` ＋ `--env-file` 重起，
`/health/ready` 回 `"mode": "vault"`。

> 這三個都不是這一輪原本要做的事。它們是**動一個共用常數**之後掉出來的——
> §32 記過的那條判斷規則（「動到被抽出來共用的常數就要跑那個常數的所有消費者」）
> 這次是對的，而消費者比預期多一個：**資料庫的 schema 版本也是一個共用常數。**

### 七、這一輪還是沒做的

- **T23**：2% 是政策不是統計。同折配對檢定需要逐折誤差，`model_run` 只有彙總值。
- **T20**：模型漂移仍然等資料（`fcscore` 目前 n=1）。
- **深度學習**：仍然卡在 556 列，不是卡在模型（見 `docs/MLOps-Model-Extension.md`）。

## §34 「重」在哪裡：先量，再決定要不要修（2026-09-08）

問題是「哪些 `sh` 或資料夾 loading 很重」。分兩種重，量法不同，處置也不同。

### 一、量測機制本身（這才是可以一直用下去的東西）

在這之前，整套測試的成本知識只有一句「大約八分鐘」——**一個總數，沒有歸屬**。
那讓每個優化決定都是猜的，也讓反向的錯誤完全隱形：一支從 4 秒長到 90 秒的套件，
表現出來只是「等久一點」。

`run_all.sh` 現在每支套件計時，寫進 `evidence/tests/suite_timing.json`，
並在結尾印出最貴的五支與各自佔比：

```
COST  500s measured across 36 suites
  24.4%  122s  tier 3  test_bluegreen.sh
  22.0%  110s  tier 1  test_stage_report.sh
  12.4%   62s  tier 1  test_model_registry.sh
  10.2%   51s  tier 1  test_static.sh
   5.2%   26s  tier 2  test_data_contract_live.sh
  25.8%  129s  the other 31
```

**五支佔 74%。**

**跨執行的總數不可比，同一次執行內的分佈才可比。** 同一天稍晚的第二次完整執行，
`test_static` 從 51s 變 122s、`test_data_contract_live` 從 26s 變 67s——
**每一支都變慢，包括完全沒動過的**。那是機器狀態（快取／溫度／背景負載），
不是程式碼。這正是 CLAUDE.md §5c 那條：結果取決於當下硬體狀態時，
它就不是 deterministic 證據。所以下面那張表的「之後」欄位都是**單獨重跑的實測**，
不是從兩次總表相減得來的。

另外新增 `PLATFORM_SUITES`（basename 的 regex），
可以只跑某一區——但**任何被過濾的執行都會在結尾大聲說「這是部分執行，
不能當成平台判定」**，和既有的 `PLATFORM_TIERS` 同一條紀律。

### 二、跑起來重的四個，以及每一個「重」的真正原因

| 套件 | 之前 | 之後 | 真正的原因 |
|---|---|---|---|
| `test_stage_report.sh` | 110s | **1.3s** | `stage_model()` 每次呼叫都對整個平台做一次即時探測；harness 有七個 case，等於探測七次 |
| `test_model_registry.sh` | 62s | **11s** | 兩次 `grep -r` 掃到 `platform/backup/archives` 的 3.9GB |
| `test_static.sh` | 51s | 51s | 未動（既有的 `--include` 已經正確） |
| `test_bluegreen.sh` | 122s | 122s | **這個重是應該的**——它真的部署兩個顏色、等就緒、切流量、再切回來 |

**（1）探測一次，渲染多次。** `stage_report.py` 新增 `--from-board`，
吃 `dag.py --json` 產出的看板，而不是自己再探一次。
順帶關掉一個真實的分岔：排程裡 `dag` 與 `stagereport` 是**兩個各 15 分鐘的 job，
各自完整探測一次**，所以兩份產物描述的是兩個不同的時刻——
2026-09-08 就出現過看板說 FAILED、`Stage-Report.json` 說 DEGRADED，相差三分鐘。

安全設計：`--from-board` **拒絕超過 1800 秒的看板**，也拒絕沒有 `generated_at` 的檔案。
一個什麼 JSON 都肯讀的渲染器，就是把上週當成今天發布出去的那個機制。

測試改用 `fixture_board.py` 產生的合成看板，而它的節點清單是**從 `dag.NODES` 讀的**，
不是手抄——手抄的 fixture 會和 `dag.py` 分岔，然後這套件存在的理由
（「dag.py 有而報告沒有的節點」）就變成拿 fixture 檢查 fixture。
副作用：這些斷言從此是 deterministic 的（CLAUDE.md §5b），
以前它們的通過與否取決於當下有什麼在跑。

**（2）`grep -r` 讀了 3.9GB 的備份。** 實測單次 29 秒
（zh_TW.UTF-8 locale、BSD grep），一支套件裡兩次就是 58 秒。
**成本在原始碼裡完全看不出來**：那一行讀起來是「搜尋整個 repo」，
實際做的是每次呼叫解壓掃過一份備份，而且**每天晚上備份跑完就更慢一點**。

處置：`lib.sh` 新增 `repo_grep`（排除 `archives`／`venv`／`mirror`／`.git`／
`__pycache__`／`node_modules`），並在 `test_static.sh` 加一條規則：
**根在 repo 或 `platform/` 的遞迴 grep 必須帶過濾**，附正負合成控制項。
29s → 0.19s。

### 三、放著重的三個（磁碟）

| 路徑 | 大小 | 進 git？ | 現況 |
|---|---|---|---|
| `platform/backup/archives` | **3.9 GB**／47 組 | 否 | 有保留策略但**從未執行** |
| `platform/analytics/{venv,mirror}` | 96 MB | 否 | 可重建（mirror 9 秒） |
| `evidence/` | 17 MB／2,514 檔 | **是** | 健康快照已有彙總（ADR-0009） |

**備份那 3.9GB 不是失控，是被擋住的**：`sync_offsite.sh --prune-local N`
只會刪掉「異地已有經過驗證副本」的組，而異地同步還沒接上（B 項，使用者自己來）。
在那之前不刪是對的——**因為對方「應該有」就刪掉唯一一份，是備份變成小說的方式。**

順手修掉兩個和它連在一起的缺陷：

1. **158 個空的封存目錄。** `backup.sh` 先 `mkdir` 再判斷 `--check-only`，
   happy path 結尾會 `rmdir`，但**拒絕路徑會先 `exit 1`**——而拒絕正是
   `test_backup_coverage.sh` 每輪跑四次的東西。於是
   `ls archives | wc -l` 讀作 205 份備份，實際只有 47 份。已改成
   check-only 根本不建目錄，並清掉那 158 個（全部確認為空）。
2. **`--prune-local` 的算術把空目錄當成備份。** 「保留最新 N 組」的分母是
   `find -type d`，不是「有 manifest 的組」。已改成以 manifest 認定一組備份。
   之前擋著它的只有迴圈裡那一層 manifest 檢查——**只有一層不叫餘裕。**

### 四、可以一般化的三句話

1. **貴的是「一次即時探測」，不是「一支腳本」。** 找出那個單位，讓它產生一份產物，
   其他消費者吃產物而不是重跑——但**產物要能證明自己新鮮**，否則就是把陳舊當現況。
2. **遞迴掃描要說出自己不讀什麼。** 生成資料會長大，而 `grep -r` 的成本
   在原始碼裡看不見；規則要能執法，不能只寫在註解裡。
3. **成本要有歸屬才有辦法談。** 一個總數只能養成「大概八分鐘」這種印象；
   逐項數字才能分辨「這 122 秒是真的在部署」與「那 110 秒只是在證明三個檔案有被寫出來」。

## §35 mlops 這一層在 Prometheus 有 0 個指標（2026-09-09）

### 一、量到的不對稱

先量，再決定要不要修。2026-09-08 的實測：

```
Prometheus 總指標 99 個 ─ devops_* 20、dataops_* 15、mlops 0
```

mlops 這一層在 Prometheus 裡的全部存在是 `devops_node_state_code{layer="mlops"}`，
**一顆燈，不是一個量測**。三個沉默的後果：

1. **沒有任何模型可以被告警。** 線上模型退化到輸給基準時，看板轉黃，沒有人被通知。
2. **沒有趨勢。**「這個月比上個月好嗎」這個問題唯一的答案方式是開 psql。
3. 看板上唯一的真數字——對基準的相對優勢——**只活在 `dag.py` 一個 f-string 裡**。
   字串畫不出線、比不了自己的過去。

這是本平台已編目的形狀「登記為存在，但不執行」往上一層：mlops 登記在看板上，
底下沒有量測。而它之所以躲過每一次檢視，正是因為那幾顆燈是綠的。

### 二、順著這條線倒推出來的三個事實（都是量的，不是猜的）

| 事實 | 數字 | 為什麼重要 |
|---|---|---|
| **t+1 從來沒有贏過持平基準** | 當前 feature set 三筆 run 全滅：HGB 差 12.08%、Ridge 差 21.99% | 那個時程從未發布過任何東西。閘門是綠的，但它擋住的是我們自己 |
| **整個試點的 ML 價值建立在 t+2 的 0.55% 上** | 線上 run 12：`mae 0.0016800` vs 基準 `0.0016894` | 這個優勢**比 ADR-0016 要求汰換現役所需的 2% 還小** |
| **事後評分 n=1，且每週只長一筆** | `retrain` 是週排程，t+1 不發布，所以只有 t+2 累積 | 要到能講話的 n≈30 是七個月。這是 T20 的真正前提，不是「還沒做」 |

後兩者都是**站著不動的事實**，不是事件。這決定了它們該長什麼樣子：

### 三、最難的一半是決定「什麼不該是告警」

`mlops.yml` 刻意**不**對這兩件事告警：

- `mlops_horizon_gate_passed{horizon="1"} == 0`
- `mlops_deployed_margin_ratio < mlops_replacement_margin_ratio`

兩者都是真的、都重要，也都會**從第一次評估就燒到永遠**。半夜被叫醒的人對它們無事可做。
本平台已經移除過一條這種燈（§23 的 `IngestRunsFailing`）。規則：

> **對「可以處置的變化」告警，不對「當前科學的既有性質」告警。**
> 既有性質照樣要被量——那正是匯出器存在的理由——只是它們不 page。

實際設的兩條：`DeployedModelLosesToBaseline`（margin `<= 0`，持續 6h）與
`ModelNotRetrained`（超過 14 天＝漏掉兩次週重訓）。兩條現在都不燒。

### 四、做了什麼

| 檔案 | 內容 |
|---|---|
| `platform/mlops/pipeline_metrics.py` | 15 個 `mlops_*` 指標。只出數字不下判斷（與 dataops 同一條紀律） |
| `platform/observability/prometheus/alerts/mlops.yml` | 兩條告警，以及「為什麼那兩件事不是告警」的完整理由 |
| `.../rule_tests/mlops_test.yml` | 五個合成案例，其中**兩個斷言不發火**——今天的真實值必須是安靜的 |
| `platform/observability/grafana/dashboards/mlops-model.json` | 九個面板。站著不動的兩個事實放在這裡，不放 pager |
| `platform/tests/test_mlops_metrics.sh` | 20 條斷言 |
| `platform/scheduler/jobs.conf` ＋ `exporter-freshness.yml` | 每小時；門檻 10800 秒（＝3×，與其他六個匯出器同一條推導） |

驗收（端到端，不是解析）：`mlops` 指標 **0 → 15**，node-exporter 讀到 60 行，
Prometheus 抓到，`mlops-model` 群組兩條規則在 `/api/v1/rules` 裡，
Grafana 九個面板全部回傳資料（`test_dashboards.sh` 的 "every panel returns data
rather than an empty frame"）。

### 五、連帶掀出來的三個東西

**5-1 評分 SQL 差點被複製。** 那段查詢的第一版漏掉 `geo_code` 與 `visit_type`，
LEFT JOIN 把 2 筆預測扇成 44 筆——一個完全由重複列組成、看起來很健康的樣本數。
匯出器需要同一段查詢，所以把它抽成 `dag.FORECAST_SCORE_SQL`，**一個定義兩個讀者**，
並加斷言鎖住「只定義一次」與「仍然 join 在 geo_code 上」。
順帶把它改成逐時程分組，看板端 `score_totals()` 加總回去——輸出逐字相同。

**5-2 看板稽核有一個偽陽性，而偽陽性比偽陰性更傷。** `dashboard_audit.py` 把
`max by (horizon) (...)` 裡的 `horizon` 當成「沒有人產生的指標」而擋下。
它從來沒被觸發過，因為**在這之前沒有任何面板做過聚合**——缺陷在無害的時候是看不見的。
已修（`GROUPING_RE`），並確認稽核仍抓得到它原本的五種合成錯誤。

**5-3 合成控制項的取樣間隔超過 lookback，會測到夾具而不是規則。**
`ModelNotRetrained` 的案例第一版用 `interval: 1h`，完全不發火，看起來像規則寫壞了。
規則是對的：Prometheus 的 lookback 是 5 分鐘，間隔一小時的樣本在多數評估點是 stale 的，
運算式是在對空向量求值。改成 4 分鐘後通過。

### 六、還是沒做的

- **T23**（逐折誤差）現在更該做了：ADR-0016 的觸發條件原本寫「挑戰者落在 1–3% 之間說不清楚時」，
  而那個條件已經成立——只是落在區間裡的不是挑戰者，是**現役模型對基準的優勢（0.55%）**。
- ~~**發布策略回測**~~ **2026-09-09 做掉，見 §36**。兩種模式都做了（可換家族／鎖定家族），
  因為那確實是兩個不同的問題。結果 n=383，而且是負的。
- **ubu 端到端**：2026-09-09 兩次嘗試都連不到（見下）。

### 七、ubu：不是 mDNS 壞了，是機器不在這個網段上

使用者告知 ubu 已開機。四種方式都找不到它，這裡記下**分辨的方法**，因為 T2 要的就是這個：

| 檢查 | 結果 | 排除了什麼 |
|---|---|---|
| `dns-sd -B _ssh._tcp local` | 只列出 `mac` | **不是 mDNS 失效**——mDNS 正常運作，它找得到別的主機 |
| 已知位址 `192.168.1.143`／`.144` | 都無回應 | 不是名稱解析的問題 |
| /24 全網段 ping + arp | 五台：`.1` 路由器、`.124`＝`mac.local`、`.132` iPad、`.145` 本機、`.146`／`.161` 無 ssh | ubu 不在 `192.168.1.0/24` 上 |
| 本機介面與路由 | `en0` 與 `en7` 都在 `192.168.1.0/24`，單一預設路由 | 不是我們在別的網段 |

結論：**機器開著但沒有連上這個區網**（或連到了別的 SSID／介面）。
這正是 B7 那條固定 IP 的用途——不是為了 kubeconfig（§26 已更正過那個理由），
而是**在 mDNS 之外留一條可診斷的路**。ubu 一旦出現在區網上，
`platform/tests/run_on_ubu.sh` 一道指令就能把下面這些 `UNVERIFIED` 收掉：
`probe_prod_cluster` 的 jsonpath 端到端、promtool 規則測試在 Linux 上、
macOS-only 寫法巡查。

---

## §36 把 n=1 變成 n=383：答案不是「比較差」，是「分不出來」（2026-09-09）

### 一、為什麼要重放，而不是等

看板的 mlops 那一列建立在 **n=1** 上：`forecast` 有兩筆已發布，其中一筆的目標週到了。
那是這個平台預測能力的全部實測紀錄，而它每週只長一筆——`retrain` 是週排程，
且 t+1 從未通過閘門。要累積到能講話的樣本數是好幾個月。

但**回答那個問題所需要的成分早就都在庫裡**。每一週決策的每一個環節——特徵、配適路徑、
閘門、汰換規則——都是決定性的，而且每一週的歷史都有。所以

> 「如果這套系統一直在跑，它**發布出去**的數字會不會贏過持平？」

今天就能回答，n 是好幾百。`pilots/station2-twin/mlops/policy_backtest.py`。

**這不是模型回測。** `backtest.py` 已經在對折評分一個模型。這裡評的是**決策**：
每個原點閘門會選哪個家族、會不會發布、發出去的那個數字對上真的發生的那一週如何。
閘門正確拒絕發布的原點是系統的成功，沒有 MAE。

### 二、結果

| | 原點 | 發布次數 | 勝過持平 | MAE 發布 | MAE 持平 | 相對優勢 |
|---|---|---|---|---|---|---|
| **t+2（可換家族）** | 450 | 383 | 196（**51.2%**） | 0.1559 pp | 0.1505 pp | **−3.60%** |
| **t+1（可換家族）** | 451 | 40 | 22（55.0%） | 0.1740 pp | 0.1611 pp | **−8.03%** |
| t+2（鎖定 Ridge） | 450 | 105 | 55（52.4%） | 0.1988 pp | 0.1858 pp | −7.00% |

三個獨立的切法，三個點估計都是負的，勝率都貼著五成。

### 二之二、但是點估計不是結論——區間才是

`platform/mlops/replay_significance.py` 用產物裡那 383 組**配對誤差**做了三件事
（固定 seed、純標準庫、可重跑）：

| | n | 勝率 | 符號檢定 p | 相對幅度 | 95% 配對 bootstrap CI | lag-1 自相關 |
|---|---|---|---|---|---|---|
| t+2 | 383 | 51.2% | **0.683** | −3.60% | **[−11.92%, +3.43%]** | +0.286 |
| t+1 | 40 | 55.0% | 0.636 | −8.03% | [−46.57%, +5.61%] | −0.202 |

**兩個時程的區間都包含 0，符號檢定都遠離顯著。** 所以可以說的話不是
「這套系統比持平差」，而是：

> **在 n=383 之下，這套系統發布出去的數字與持平基準分不出差別。**

這兩句話差很多。前者是一個發現，後者是「這個模型目前買不到任何可偵測的東西」——
仍然是決策相關的（一個在 383 週上證明不了自己的模型，沒有賺到它的複雜度），
但它不是「更差」。

**而且區間如果錯，是錯在太窄。** lag-1 自相關 +0.286 說週誤差不獨立——
流行週後面接著流行週——而符號檢定與 bootstrap 都假設獨立。標準修法是 moving-block
bootstrap；**沒有做**，所以數字帶著這個限制報出來，而不是安靜地當成沒這回事。

因此匯出器**不會單獨發出點估計**：`mlops_policy_backtest_margin_ratio` 一定與
`_ci_low`／`_ci_high`／`_sign_test_p` 一起出現。一個沒有區間的點估計，
就是這個 repo 已經編目過的那個形狀往上一層——**一旦都是表格裡的數字，
估計值跟量測值就長得一模一樣**。

判定分布 t+2：`REFUSED 67／BOOTSTRAP 1／REFRESH 382`。
實際服務過的家族只有 HGB——2% 的汰換門檻讓 Ridge 一次都沒進來，那是規則在正確運作。

### 三、這跟回測數字不一致，而不一致本身就是發現

回測說 t+2 的 HGB 贏持平 **+0.55%**（`model_run` 12／14）。重放說發布出去的數字
輸持平 **−3.60%**。兩個都是對的，因為**它們量的不是同一件事**：

- 回測的 +0.55% 是**折內彙總**：553 折的平均誤差，跟基準在同一組折上比。
- 重放的 −3.60% 是**被發布出去的那些週**：383 個原點，選擇是用當時看得到的資訊做的。

差距的來源是**選擇**。閘門用「過往誤差」挑贏家，而過往誤差領先**沒有轉移到之後那一週**：
勝率 51.2%（p=0.68）就是擲硬幣。回測的 +0.55% 沒有被證明是假的，
它只是**沒有出現在真的會被發出去的那些數字上**。

> 這是「擋住壞的不等於放進來的是對的」的下一層：
> **閘門放行的那個，在它被放行之後的表現，跟它被放行的理由沒有關係。**

### 四、洩漏有三道門，逐一堵

1. **配適**：`fit_one` 走 `rolling_origin` 嚴格在前的訓練列——與真回測同一條路徑，不是複製品。
2. **選擇**：第 i 個原點的閘門只能用第 i 個原點**之前**觀察到的誤差。
   拿「事後知道哪個家族整體會贏」來選，是重放報出一個沒有人當時拿得到的戰績的經典方式。
3. **基準**：持平只在模型被評分的那些原點上評分。在不同子集上算的基準不是同一條基準。

第 2 道門是這支程式的全部難度所在，也是 `MIN_HISTORY = 20` 存在的理由：
低於這個數，「冠軍」只是連對兩次擲幣的那個，重放量到的會是雜訊選擇不是政策。

### 五、實作上的四個決定

| 決定 | 為什麼 |
|---|---|
| 點估計永遠與區間一起發出（`_ci_low`／`_ci_high`／`_sign_test_p`／`_lag1_autocorrelation`） | −3.60% 讀起來像「比較差」，區間 [−11.92%, +3.43%] 說的是「分不出來」。只畫點估計的面板會安靜地把後者覆寫成前者 |
| 指標前綴 `mlops_policy_backtest_*`，與實績完全分開 | 實績 n=1、重放 n=383，加起來就是一半量測一半模擬的戰績。**一旦都是表格裡的數字，估計值跟量測值就長得一樣** |
| `mode` 標籤（`policy`／`locked`） | 可換家族測的是「這套流程」，鎖定測的是「那個模型選擇」——兩個不同的問題，不能共用一格 |
| 窗口旗標拒絕 0，無上限另給名字 `--all-origins` | 被 `guard-bash` 的 `limit-zero` 規則擋下才發現。**零就是零**；零被讀成「全部」是有界執行變成全量執行的方式 |
| `--json -` 走標準輸出，摘要改走 stderr | `run.sh` 只掛載 `/mlops`，容器物理上寫不進 `evidence/`。混在同一個串流會產出一個「合法文字、非法 JSON」的檔案，而 `test_evidence_contract.sh` 只會在事後才說 |

成本：每時程 21 秒（450 原點 × 2 個家族各配適一次），已接進 `retrain.sh` 的第 5 步，
非致命——重放失敗不該讓一次成功的重訓變成失敗。

### 六、這一節沒有回答的

**「所以要不要繼續？」是使用者的決定，不是我的。** 能講的是選項與各自的代價：

1. **接受**：把試點的價值定位在「管線與治理」而不是「預測精度」，
   看板明說預測目前**不優於**持平（不是「差於」——區間包含 0）。
2. **換特徵**：556 列裡目前只有單一疾病的全國週率。倉庫有 653 萬筆事實，
   地理維度、其他疾病、就診型別都還沒進特徵集——這是 T8 那一類的新範圍。
3. **換題目**：持平在**週資料、兩週延遲**的設定下極難擊敗。方向（升/降）或
   閾值跨越（會不會超過流行閾值）可能才是決策相關的量，而那是新的標籤定義。

三條都是新範圍，依 §27 只登記不實作。

---

## §37 三個維度進特徵集、第二個預測題目，以及「假設只有一個」的四處（2026-09-09）

### 一、schema 早就有，特徵沒有用

`feature_set` 自 migration 013 起就帶著 `geo_code`／`disease_id`／`visit_type`
三個欄位。建構器只建**一個**組合：臺中市／門診／類流感。
這是同一個已編目的形狀「登記為可擴充，但只實作了一種」——**比模型註冊表高一層**，
而模型註冊表的同一個問題在 2026-09-08 才剛修掉。

倉庫有 653 萬筆事實、14 支疾病、22–368 個地理、最多 3 種就診型別。
建模表 556 列。**556 是切片的結果，不是資料的極限。**

### 二、加了什麼（migration 017／018）

| 欄位 | 維度 | 填充率 |
|---|---|---|
| `inpatient_lag_1` | 就診型別（住院＝嚴重度） | 556/557 |
| `national_lag_1` | 地理（全國加總） | 556/557 |
| `geo_share_lag_1` | 地理（本市／全國） | 556/557 |
| `uri_lag_1` | 疾病（急性上呼吸道感染） | 556/557 |
| `pneumonia_lag_1` | 疾病（其他肺炎） | 556/557 |

**全國是「和的率」不是「率的平均」**——後者會讓連江縣與新北市等重。

### 三、急診沒進來，而理由是量出來的

`er_lag_1` 是 017 加的，理由充分：急診就診在同一波裡**領先**門診，是唯一有機制上
理由「早」的特徵。兩次量測把它否決：

1. `急診` 在 `nhi_visits` 底下是空的。急診資料在 **`rods_ed_visits`**，
   來自即時疫情監測系統，與目標所用的健保申報**不同來源**。
2. `rods_ed_visits` **完全沒有分母**：442,783 筆全空。它是原始就診**次數**不是率。

把計數放進一排率旁邊，就是這個 repo 已經付過一次的單位錯誤——`dag.py` 的評分註解
記著把計數加總去「比對」0.0198 得到 18,286，差三個數量級而看起來仍像一個合法比較。
**兩次都是建構器印的逐欄填充率當場抓到的**，那行輸出的存在理由就是這個。
登記為 T26。

### 四、第二個題目：流感，而它比類流感好預測得多

`influenza` 在這個倉庫裡是**獨立的一支**（188,920 筆、2016–2026），不是
`influenza_like_illness` 的同義詞。所以第二個預測題目**不需要新資料，只需要一個參數**。

| 題目 | 時程 | 模型 MAE | 持平 MAE | 對基準 |
|---|---|---|---|---|
| 類流感 | t+1 | 0.1320 pp | 0.1179 pp | −12.0% |
| 類流感 | t+2 | 0.1655 pp | 0.1694 pp | **+2.3%** |
| **流感** | t+1 | 0.0693 pp | 0.0692 pp | −0.1% |
| **流感** | t+2 | 0.0994 pp | 0.1109 pp | **+10.4%** |

**控制項**：舊特徵集 55（五個新欄位全 NULL）跑**新程式碼**，t+2 仍是 **+0.6%**——
與它歷史上的 +0.55% 一致。所以類流感 t+2 從 +0.55% 到 +2.3% 的改善**來自新特徵**，
不是來自程式碼改動或多的那一週。

### 五、但重放才是判準（§36 的規則）

| 題目 | 時程 | n | 勝率 | 相對幅度 | 95% CI | 符號檢定 p |
|---|---|---|---|---|---|---|
| 流感 | t+2 | 431 | 52.0% | **+6.58%** | [−3.09%, +14.80%] | 0.441 |
| 類流感 | t+2 | 431 | 52.9% | +0.01% | [−7.36%, +6.28%] | 0.248 |
| 流感 | t+1 | 203 | 41.9% | −6.36% | [−21.76%, +6.27%] | **0.025** |
| 類流感 | t+1 | 39 | 48.7% | −11.77% | [−60.28%, +3.47%] | 1.000 |

可以說的話：

- **流感 t+2 是目前唯一值得繼續的組合。** 點估計 +6.58%，是汰換門檻的三倍，
  區間有八成在零以上——但**區間仍包含 0**，所以還不能說它被證明了。
- **新特徵把類流感 t+2 從 −3.60% 拉到 +0.01%**：補掉了赤字，沒有買到優勢。
- **流感 t+1 是唯一顯著的一格，而它顯著地「更差」**（p=0.025）。
  t+1 上這個模型是在幫倒忙。

### 六、加第二個目標，暴露出四處「假設只有一個」

這是這一輪真正的收穫。四個地方都**寫在當時是對的**，都在有第二個目標的那一刻變錯，
而且四個都**不會報錯**：

| 位置 | 原本 | 加第二個目標後會發生什麼 |
|---|---|---|
| `backtest.py` | 取 `built_at` 最新的 feature set | 要求類流感的執行會評分流感，並把數字記在類流感的時程下 |
| `publish_forecast.py` 的比較範圍 | 同上 | 排程會發布流感、讓類流感的預測放著變舊，**沒有任何產物會說服務的疾病換了** |
| `publish_forecast.py` 的現役查詢 | 只用 `horizon` | 發布流感時抓到類流感的現役 run，因為兩者都是 HGB 而配對成功，回報 `REFRESH`——**拿流感的 MAE 去比類流感的 MAE** |
| `dag.py` 的 `MODEL_GATE_SQL` ＋ `FORECAST_SCORE_SQL` | 只用 `horizon`；疾病寫死在 WHERE | 板面兩個疾病輪流佔同一格；事後評分把流感預測對上類流感的實際值（大四倍的數字） |

四處都已修，並各自帶斷言。**形狀值得記住：一個「目前只有一個」的維度，
它的缺席不會產生錯誤，只會產生一個看起來完全正常的錯誤答案。**

### 七、還沒做的

- **T26** 急診（RODS）整合：要先決定分母。
- **T27** ~~`dataops_*` 沒有 `project` 標籤~~ **本輪做掉**（ADR-0017 已更新）。
- **T28** ~~事後評分未依疾病切~~ **本輪一併修掉**（見上表第四列）。
- **T25** ~~networkpolicy 前置控制項偶發紅~~ **本輪做掉**（重試 ＋ `UNMEASURED` 判決）。
- **T29／T30** LLM 複審缺 golden set；`llmreview` 節點仍 SUPERSEDED（2026-09-09 從
  已刪除的生態系掃描文件遷移登記）。
- 地理仍固定在臺中市：`--geo` 早就是參數，但**每個地理一個 feature set** 會讓
  feature set 數量 ×22，而閘門與發布都是逐 set 執行的。那是排程與成本的問題，
  不是建模的問題，需要先決定。

---

## §27 待辦登記簿（2026-09-04 起，逐一完成）

**規則：這一節只登記，不實作。** 需求不擴張，功能逐步收斂落地。
每一筆都要有「為什麼現在不做」與「什麼時候該做」。

| # | 待辦 | 為什麼現在不做 | 觸發條件 |
|---|---|---|---|
| T1 | **備份歸檔沒有保留策略** | 見下方分析：現在不痛，但單調成長 | 磁碟告警再燒，或歸檔超過 10G |
| T2 | **`probe_prod_cluster` 分辨三種連不上**（mDNS 失效／SAN 不符／機器睡著） | **2026-09-05 做掉了其中的缺陷那半**（見下）；剩下的「mDNS 失效 vs 機器睡著」需要第二條命名路徑與**處置決定**，而處置還沒定 | ubu 停用休眠之後——在那之前「睡著」會蓋掉另外兩種 |
| T15 | **`probe_prod_cluster` 四條回傳路徑零測試覆蓋**（現已補兩條，仍缺 no-context 與逾時的真實誘發） | 四種故障都已證實可在秒級無損誘發，但補齊要新增誘發器與夾具 | 下次動這個探針時一併補 |
| T16 | **覆蓋缺口記錄沒有主機狀態欄位** | 睡眠窗與「醒著但一直失敗」寫出的記錄逐欄相同；要分辨得新增採集 | 出現第一次「缺口記錄看不出原因而誤判」時 |
| T17 | **`record_gap.py` 零測試斷言，且門檻常數與 `status.sh` 各寫一份** | 是缺陷不是新功能，但屬 scheduler 範圍，本輪未動該區 | 下次動 scheduler 時一併補 |
| T18 | **`CTX=ubu` 部署會在 prod 機器上建出預設允許的 namespace**；部署證據檔名寫死 `deploy_develop_<sha>.json`；`sync_vault_secret.sh` 只讀一份寫死的 AppRole 檔；備份／還原演練綁死 k3d context | 四項都是 T7 的**前置缺陷**，在 pilot 真的上 ubu 之前不會造成傷害，但會在第一次上線時同時發作 | T7 動工時，**在第一次 `CTX=ubu` 部署之前** |
| ~~T19~~ | ~~**`scheduler` 探針把「本機睡著」報成「排程沒在跑」**~~ **2026-09-08 已決定：睡眠窗算違反 SLA，維持現狀不豁免**（理由見下方 §31） | — | — |
| T20 | **概念漂移（model drift）沒有任何偵測**——repo 裡所有 "drift" 都是資料漂移 （2026-09-08 跨 session 稽核找到：2026-09-02 曾被問「mlops 有定期更新 model and drift detect 嗎」，重訓做了，drift detect 沒做，也沒登記） | **前提還沒滿足**：模型漂移是「模型在新資料上的表現 vs 它上線時的表現」，而「預測 vs 實際」的歷史今天才開始有第一筆（§31 二之二）。用 n=1 建漂移偵測，偵測到的會是雜訊不是漂移 | 事後評分累積到能分辨訊號的筆數——**這個門檻本身要先量**，不要憑感覺挑一個 n |
| T21 | **`forecast` 表沒有存實際值，事後評分每次都要重算** | 現在只有 2 筆，重算是毫秒級；加欄位要寫 migration，而 migration 是不可逆的 | 事後評分的筆數讓重算變慢，或 T20 動工需要穩定的歷史快照時 |
| ~~T22~~ | ~~**閘門從不拿候選模型跟線上模型比**，只跟持平基準比~~ **2026-09-08 做掉**：規則在 `platform/mlops/promotion_policy.py`，門檻 2%（同分留任）在 `publish_forecast.py`，決策紀錄 ADR-0016，六種判定各有可重跑案例（`--explain-gate`） | 一併修掉了原本沒看見的那半：舊選法**跨 feature set 比 MAE**，551 折與 553 折算出來的數字印起來一樣意思不一樣 | — |
| T23 | **同折配對檢定做不了，因為 `model_run` 只存彙總誤差**（**2026-09-09 更新：觸發條件已成立**，見 §35 六——落在 1–3% 區間的不是挑戰者，是現役模型對基準的 0.55% 優勢） | ADR-0016 的 2% 是**政策**不是統計論證。要回答「這個差距是不是真的」需要逐折誤差；加逐折儲存是新 schema，且在只有兩個模型家族時收益有限 | 出現第一次「挑戰者落在 1–3% 之間、要不要換說不清楚」時；或 T20 動工需要穩定歷史時一併做 |
| T24 | **`test_static.sh` 現在是最貴的 tier 1 套件（122s／20.7%）** | 它沒有明顯的浪費——387 條斷言、約 100 支腳本各跑 `bash -n` 與 3.2 相容性解析，成本是**真的在做事**。要再快只有兩條路（只掃改動過的檔案、或把掃描合併成單次走訪），兩條都會讓「全樹掃過」這個保證變成條件式的，而那正是它存在的理由 | 有人真的被這 2 分鐘擋住開發節奏時，或是它再長 50% 時 |
| ~~T25~~ | ~~**`verify_networkpolicy.sh` 的前置控制項會偶發紅**~~ **2026-09-09 做掉**：`BEFORE` 探測改成三次重試（照抄 `test_bluegreen.sh` 的就緒探測），且判決從 `FAIL` 改為新增的 `UNMEASURED`——「實驗沒跑成」跟「系統壞了」是不同的主張，而把前者報成後者會訓練所有人重跑到綠為止，那正是真失敗被放行的方式。`UNMEASURED` 印在總結行且**不併入 passed** | — |
| T26 | **急診（RODS）序列沒有進特徵集** | 它在 `rods_ed_visits` 底下、與目標不同來源，而且**完全沒有分母**（442,783 筆全空）——是次數不是率。要用就得選一個分母，那是有後果的建模決定，且這個特徵的價值尚未證明。`feature_row.er_lag_1` 欄位留著、有 COMMENT、不填值 | 有人想做急診領先指標時；或流感 t+2 的區間需要再收窄時 |
| ~~T27~~ | ~~**`dataops_*` 沒有 `project` 標籤**（ADR-0017）~~ **2026-09-09 做掉**：313 條序列全部帶上，唯一例外是檔案自己的產生時間戳。比預估便宜——13 個發射點共用一個 `base_labels()`，告警走 `by (source)` 不受影響。**原本的觸發條件「等第二個專案」是反的**：那等於要在最忙的那一天同時改三個地方 | — |
| T28 | ~~**事後評分沒有依疾病切**~~ **2026-09-09 一併修掉**：`FORECAST_SCORE_SQL` 的 `actual` CTE 原本把疾病寫死在 WHERE，而預測那側沒有過濾——第二個題目上線的那一刻，每一筆流感預測都會被拿去對上類流感的實際值 | — |
| T29 | **LLM 複審只能偵測「不確定性」，不能偵測「品質退化」** | `system_digest` ＋ `inputs_digest` ＋ `temperature=0` 已經能抓到「同樣輸入得到不同結論」。但改了 `SYSTEM_PROMPT` 之後 digest 會變、determinism 檢查照樣通過，**複審變好還是變壞沒有任何機制回答**。要回答需要一組已知答案的題目（5–10 個「該被抓到」的 commit 當 golden set），那是新範圍。**這一筆原本只寫在 `Ecosystem-Actions-2026-08.md` 裡，2026-09-09 該檔刪除時遷移過來** | `llmreview` 接回產物之後——在那之前所有 prompt/eval 的討論都是關於一個沒在跑的元件 |
| T30 | **`llmreview` 節點自退役 Compose 路徑之後一直是 SUPERSEDED** | 板面誠實顯示 `superseded`（不是綠也不是紅），所以它不是沉默失效。接回去要決定 Kubernetes 產物的形狀，屬 T7 範圍 | T7 動工時一併決定產物路徑 |
| T33 | **`prodk8s` 與 `llmreview` 的擁有者從 `eng` 改判為 `decision`（2026-09-10）** —— 不是待辦，是登記這個改判的理由 | 量測結果：amd64 映像已在 ghcr（`pilot-image.yml` 原生建置，09-09 驗過），ghcr token 在 Vault 裡，**映像那一半是做完的**。擋住的是 manifest 指的 `host.k3d.internal:18200`（Vault）與 `:15432`（Postgres）**都只綁 127.0.0.1**——從 ubu 實測兩個都 connection refused。這不是工程能推進的 | 見板面 ask `prod-workload-reachability` |
| T34 | **異地備份沒有「另一台機器」這條路** | `sync_offsite.sh` 只吃檔案系統目的地，`sync_remote.sh` 只吃 rclone crypt remote，而 rclone 本機沒裝、全域安裝是禁止的。ubu 是現成的第二台機器（83G 可用、ssh 金鑰已通），但要走 ssh 就得寫第三支 sibling，而**目的地選哪裡本來就是使用者的決定**——先問，再寫 | 使用者選定目的地之後 |
| T35 | **來源發布週期只有 `declared` 與 `structural` 兩種證據，沒有「我們自己觀測到的」那一種** （2026-09-10 新增的 `srcfresh` 節點第一天就 WARN：`cdc-tb-caremag` 4.4 天沒有新內容，門檻 3 天，而那個門檻來自發布者在 CKAN 上自己宣稱的 `updated_freq='day'`） | `ingest_runs` 裡就有我們每次抓取的變動史，足以算出**實際**發布間隔。但把 `observed` 加成第三種證據會改變 `SourcePublishedNothingNew` 的判定基準，而那條規則現在是照它自己的定義正確地燒。先確定是來源真的停了還是宣稱值不對，再改門檻——反過來做就是把告警調到不響 | 下一次有第二個來源因為 `declared` 週期而誤報時；或有人要回答「這個來源到底多久發一次」時 |
| T36 | **DAST 只掃得到 10 條路由裡的 4 條** —— 2026-09-10 新增的 `dastcov` 節點第一天就是黃的 | 掃不到的六條不是掃描器故障：3 條要參數、2 條沒有被連結到、1 條是寫入。要涵蓋它們得給 ZAP 一份認證後的 context 與參數字典，或改用 API 規格驅動的掃描——那是**新的掃描設定**，不是修一個壞掉的東西。而且要先決定「寫入端點該不該被自動掃」 | 有人要把 DAST 當成覆蓋率宣稱（而不是煙霧測試）時；或 pilot 新增未連結的端點時 |
| T37 | **健康檢查的覆蓋率是 90%，而 41% 的樣本是 DEGRADED** —— `rollup` 節點現在會說了，但沒有人查過那 41% 是什麼 | 那是一個月的歷史，episodes 已經列出最長的幾段（最長 2026-08-21 到 08-24 共 3 天，alertmanager/prometheus 都不可達）。要回答「現在還會不會再發生」需要逐段對照當時的事件，是一次調查不是一個修法 | 下一次 DEGRADED 佔比再上升時；或有人要用這條線做 SLA 宣稱時 |
| T31 | **Telegram bot token 明文出現在 `docker logs`** | 是上游函式庫（telebot）把整個 sendMessage URL 寫進錯誤字串，不是設定錯誤。要遮蔽得改 Alertmanager 的日誌管線或包一層 proxy，兩條都是新元件；而現況的實際曝險範圍是「能對這台機器下 `docker logs` 的人」，與能讀 `~/.env` 的是同一群人 | 這台機器上出現第二個不該看到這把 token 的使用者時；或 token 要用於這個平台以外的地方時 |
| T32 | **§零 只驗「列出來的檔案指得對」，不驗「該列的都列了」** | 2026-09-10 新增的守衛能抓到「文件指向一個腳本不會產生的路徑」（`.telegram.env` 就是這樣被抓到的），但反方向抓不到：一個平台真的需要、卻沒被寫進 §零 的 gitignored 檔案，仍然會在全新 clone 時安靜地缺席。要抓得到，得先有一份「哪些 gitignored 檔案是承重的」的機器可讀來源，那要各層自己宣告 | 下一次「全新 clone 起不來而 §零 沒說」發生時；或有人真的在第二台機器上從零 clone 時 |
| T3 | **從社群的教訓反向補守衛** | 見下方分析 | 每次遇到「本機綠、別處紅」時追加一條 |
| T4 | **loader 寫得出失敗狀態**（§23） | `IngestRunsFailing` 才有有意義的版本可以回來 | 出現第一個「25 支來源裡 1 支失敗」的情境 |
| T5 | **conflict 變化的基線**（§23） | 只有變化才是新聞，而基線還沒存 | T4 之後 |
| ~~T6~~ | ~~空抓取偵測（§19）~~ **已完成 2026-09-04** | — | — |
| T7 | **pilot 上 prod**：Vault ＋ 資料庫 on ubu | 映像已通，剩這兩個；會產生 unseal key，存放位置要與時程一起定 | ubu 停用休眠之後 |
| T8 | **`moi-ris-village-age-marital`（ODRP052）從未載入** | 那是新範圍不是修正 | 需要年齡／婚姻維度時 |
| T9 | **`prodk8s` 的 DAG 邊** | 誘人的 `registry → prodk8s` 是假的（arm64 registry 供不了 amd64 節點） | ghcr 進入部署路徑之後 |
| T10 | **板面內嵌 SVG**（§17） | 需 ~150MB Chromium，成本由使用者決定 | 使用者決定 |
| T11 | **追蹤 traces**（§18） | 三個前提未到 | 服務數量到位 |
| T12 | **偵測「被加進不會執行的分支」的檢查** | 沒有工具抓得到；唯一訊號是斷言總數沒增加，而那個數字目前沒人看 | 再發生一次，或 run_all.sh 開始記錄每個套件的斷言數基線 |
| ~~T13~~ | ~~**`WidespreadGeoDrift` 沒有分母下限**~~ **已完成 2026-09-04**（見下方診斷與驗收） | — | — |
| T14 | **`prev` 那一側沒有完整度守衛**（見下方診斷） | 目前只影響 1 支疾病且未造成誤報；修它要動 settle 規則，那是 §20 剛穩定下來的東西 | 第一次出現「去年同期不完整」造成的誤報，或 settle 規則因別的理由再動時 |

### T2 的缺陷那半：探針把 kubectl 唯一自我描述的那行丟掉了（2026-09-05 修）

T2 原本被當成一件「要新增分辨能力」的事。實際拆開之後，**其中一半根本不是新功能，
是缺陷**：`run()` 只回傳 `(rc, stdout)`，而 `probe_prod_cluster` 又寫成 `rc, _ = run(...)`，
於是 kubectl 寫在 stderr 的那一行——唯一會說出「到底哪裡不對」的訊息——被丟掉，
換成一句事先寫好的固定句子。三種原因收斂成同一句話，有一半是這樣來的。

**修法**：新增 `run_diag()`（保留 stderr；獨立於 `run()`，因為 `run()` 有十個呼叫者、
其餘九個不需要第三個回傳值）。不可達分支改成**回報 kubectl 說了什麼**。

**只有 SAN 不符被具名**，因為只有它的訊息是確定的
（`x509: certificate is valid for …, not …`，實測以 `--tls-server-name` 可在秒級無損誘發）。
逾時**刻意不分支**：同一台不可達主機實測回過四種不同字串
（`context deadline exceeded`／`request canceled while waiting for connection`／
`no route to host`／`Host is down`），對這些做分支等於加一條**靠運氣才對**的守衛。
其餘情況一律把原始那行帶出來——**讀者能據以行動的證據，勝過我們猜的原因**。

**驗收**：三個合成控制（stub 掉 `run`／`run_diag`）——SAN 案例必須具名、
未具名的失效必須帶出 kubectl 自己的話、健康路徑必須仍然拒絕讀成綠。
第三個是讓前兩個保持誠實的控制項：健康路徑若哪天開始回報錯誤，前兩個仍會過。
斷言數 37 → 41。

**過程中犯的錯，記下來**：新的 `run_cmd` 被插進既有斷言區塊的**中間**，
而 `assert_output_contains` 讀的是**最後一個** `run_cmd` 的輸出——
三個 alertmanager 斷言於是被靜默改指到別的輸出而變紅。已修，並在該處留下警告註解。
這是 §28 坑 #6 的近親：**檢查放錯位置，而位置本身不會報錯**。

**四種故障對真實 ubu 的實測（2026-09-05，ubu 關機前的窗口內取得；全部唯讀、秒級）**

| 誘發方式 | kubectl 說了什麼 | 可否當判別依據 |
|---|---|---|
| `--tls-server-name=nope.invalid` | `x509: certificate is valid for …, not nope.invalid` | **可以**，字串穩定 |
| `--server=https://ubu.local:6444`（同主機關閉的埠） | `The connection to the server ubu.local:6444 was refused` | **可以**——這是「機器醒著、服務沒在跑」，是四種裡唯一能證明主機活著的 |
| `--server=https://ubu-nope.local:6443`（名字不存在） | `context deadline exceeded`／`…(Client.Timeout exceeded while awaiting headers)` | **不可以** |
| `--server=https://192.168.1.253:6443`（同網段黑洞） | 三次重跑三種字串：`context deadline exceeded (…)`／`no route to host`／`host is down` | **不可以** |

**最後一列是這一節的重點。** 同一個故障、同一個指令、連跑三次，得到三個不同字串。
所以任何建立在逾時訊息上的判別分支都是**靠運氣才對的守衛**——
它會在寫的當天通過，然後在某個沒人看的時刻悄悄給出錯誤答案。
`probe_prod_cluster` 因此只具名 SAN 一種，其餘帶出原文不下結論。

**還沒接進探針的一條**：`was refused`。它穩定，而且回答的是別的問題——
「機器活著但 k3s 沒在跑」。接它的成本很低，但**處置未定**（要不要自動重啟 k3s？），
所以留在 T2 而不是順手做掉。

**仍未做（留在 T2）**：分辨「mDNS 失效」與「機器睡著」。這需要第二條命名路徑
（路由器的 DHCP 主機名 DNS——實測**已經存在**且對不存在的名字會給 `NXDOMAIN`，
正是 mDNS 缺少的否定回答），以及**處置決定**：mDNS 失效要不要自動改走另一條路？
睡著要不要發 WoL？k3s 停了要不要自動重啟？三個都是政策，不是工程。

### T13／T14 兩個正在燒的 `WidespreadGeoDrift`：診斷（2026-09-04，量測）

**這兩個告警不是同一個故事，卻共用同一條規則。** 診斷前它們在板面上長得一模一樣。

告警的前提寫在規則旁邊：「單一地區變動是流行病學；四分之一地區同向變動比較像管線」。
量測顯示，兩個正在燒的實例**各自違反這個前提的不同一半**。

量測（`platform/analytics/mirror`，2026w34 對 2025w34，`YOY_FLOOR=20`）：

| 疾病 | 本週 | 去年同週 | join 到的地區 | 可比地區 | n_up | n_down | share |
|---|---|---|---|---|---|---|---|
| COVID-19 | 21,256 | 5,157 | 22 | 19 | **19** | 0 | 1.00 |
| 猩紅熱 | 49 | 183 | 22 | **3** | 0 | **3** | 1.00 |
| 急性出血性結膜炎 | 190 | 204 | 19 | **3** | 0 | 0 | 0.00 |
| （對照）類流感 | 104,486 | 92,301 | 22 | 22 | 0 | 0 | 0.00 |

**COVID-19 是真訊號，不是管線。** 兩側覆蓋率都是滿的 22 個地區
（先驗證過：`cur` 與 `prev` 的 geo 數皆為 22，等於前 12 週中位數），
19 個可比地區**全數**上升，全國 4.12 倍。這是規則的前提**接不住**的情況：
一場真正的全國性流行，在這條規則眼裡和一次管線變更**完全同形**。
告警文字說「比較像管線」，而這一筆不是——**訊號正確，標籤誤導**。

**猩紅熱是 N=3 的假影。** 22 個地區裡只有 3 個的去年同期值過得了地板
（46／29／23，其餘是 14 到 0），三個都跌 → 3/3 = 100% → 燒。
「超過 1/4 的地區」字面為真，流行病學上空洞：這是一個小數目疾病，
全國一週 49 例。**每個地區有地板（`YOY_FLOOR=20`），但 share 的分母沒有下限。**
這是本 repo 失效形狀目錄裡「空集合上的恆真句」的鄰居——**小集合上的必然真句**。

**不是只有猩紅熱。** 急性出血性結膜炎的可比地區同樣是 3。它今天 share=0，
但那三個地區同向動的任何一週它就會燒。**缺陷是規則的，不是那支疾病的。**

**被推翻的假設（記下來，免得再走一次）**：先懷疑是「拿完整週比部分週」
——即 `cur` 有完整度守衛（覆蓋率 ≥ 前 12 週中位數）而 `prev` 沒有。
查了：這兩支疾病的 `prev` 側都是滿的 22 地區，**假設不成立**。
但同一個查詢找到 T14：**急性出血性結膜炎的 `prev` 側確實是 PARTIAL**
（20 個地區，中位數 21）——`prev` 缺守衛是真的，只是不是這次的成因。
`pipeline_metrics.py:404` 的註解說「不要靜默地拿部分週比完整週」，
而那個保護只加在比較的一邊。

**現況（如實記錄）**：這兩個告警自 2026-09-04T03:13 起 firing，
在此之前的 evidence 檔（08-29 起）也可見同名告警。**在本次診斷之前沒有人看過它們的分母。**

### T13 修法與驗收（2026-09-04 完成）

**改的是分母下限，不是門檻。** `dataops_yoy_geo_comparable_count >= 11`
加進 **recording rule `dataops:yoy_geo_drift_share`**。11 ＝ 台灣 22 個縣市的一半，
也就是這個維度本身的一半：**低於半張地圖，「普遍」就不是資料撐得住的宣稱**，
share 是多少都一樣。觀察到的分佈缺口很寬（3、3、8 ｜ 18、19×3、20、21×2、22×3），
所以這個門檻不是立在刀鋒上。

**同時修了誤導的文字**（不是新功能，是讓既有告警誠實）：description 現在明講
這條規則**分辨不出**真流行與管線變更，並給出判別方式（只有一支疾病動＝較可能真疫情；
多支同時同向＝較可能管線）。COVID-19 那一筆仍然會燒，**這是對的**——
它 19 個可比地區全升，本來就該被看見，只是不該被貼上「像管線」的標籤。

**驗收（依 [ADR-0007](decisions/0007-verify-by-evaluation.md)：以評估，不是以解析）**

- 新增 `rule_tests/dataops-geodrift_test.yml`，四個案例，數值全部取自
  2026-09-04 的真實量測而非杜撰：N=19 必燒／**N=3 必靜**／N=11 邊界必燒／
  N=22 但 share 低於門檻必靜。最後一個是**原條件的控制項**：
  若 `on(...)` 的標籤寫錯導致每個序列都被丟掉（就是 2026-08-28 那個缺陷重演），
  規則會永久靜音，而那與「沒有東西在漂移」從輸出上分不出來——
  沒有這個案例，N=3 那一項會因為錯誤的理由通過。
- **兩個突變都被殺死**（`test_dataops_metrics.sh` 內，不是另開檔案）：
  下限拿掉 → 猩紅熱案例重新燒 → 測試紅；下限改 12 → 邊界案例不燒 → 測試紅。
  兩次都 `cp` 還原並以 `cmp` 斷言 byte-identical。
- **斷言數 30 → 34**，確認新檢查落在會執行的分支
  （§28 坑 #6：唯一會露餡的訊號就是斷言數沒有增加）。
- **活的平台端到端**：SIGHUP 重載（`--web.enable-lifecycle` 沒開，這是刻意的），
  expr 求值由 2 筆序列降為 1 筆，規則狀態與 Alertmanager 皆由 2 筆 firing 降為 1 筆
  （只剩 COVID-19）。猩紅熱**沒有被靜音，是不再成立**。

**沒有做、仍然登記的**：把「全國性同向大幅上升」拆成有自己名字與 runbook 的
獨立規則。那是新增一條告警＝新增範圍，而目前 description 已經誠實說出它分辨不了。
觸發條件：第二次出現「真流行被當成管線問題調查」的時候。

#### 追記 2026-09-05：下限修好之後，才看見它擋在前面的第二個缺陷

下限讓猩紅熱不再燒之後，剩下的唯一告警 COVID-19 **在板面上時有時無**。
倒推之下，這不是資料問題，是 **`for` 的連續性假設在會睡覺的宿主上不成立**。

**量測（Prometheus `query_range`，不是推論）**

| | |
|---|---|
| COVID-19 條件 | 連續 30 小時未變（19/19 可比地區上升，share 1.0） |
| 實際告警狀態 | firing 09-04 11:17–18:17（7.0h）→ pending → firing 21:47–00:02（2.2h）→ pending → … |
| 抓取空洞 | 16 小時內 9 次，每次 4–14 分鐘 |
| 最長連續清醒窗 | 269／209／131／87／75／59 分鐘 |

所以 `for: 2h` 在十六小時內**只有三次機會**被滿足。機制：宿主睡眠停止求值，
醒來後第一次求值時最後一個樣本已超過 5 分鐘 staleness 窗，瞬時向量為空，
`for` 從零重數。**觀察到的形狀是震盪，不是靜默**——
一開始我以為訊號完全沒進 Alertmanager，範圍查詢推翻了那個說法。

**修法**：`expr: max_over_time(dataops:yoy_geo_drift_share[1h]) > 0.25`。
1 小時是實測最大空洞（14 分鐘）的約 4 倍。代價是遲滯：條件消失後最多多燒一小時——
**在這裡近乎為零，因為底層資料是週資料**，這個 share 一小時內不可能有意義地變動。

這**不修監控空洞本身**，它修的是「空洞把已經成立的訊號抹掉」。
空洞的來源是**這台 Mac** 的電源行為，已記載為筆電的物理限制而非程式缺陷
（[`Plan.md`](../Plan.md):354-356、本檔 §12 第 3 項）。
**不要引 B7／§13**——那兩處講的是 ubu，是另一台機器；
第一版的註解就引錯了，對抗式複審抓到。

**驗收**：規則測試新增第五個案例——序列存在 60 分鐘、**缺 15 分鐘**、再恢復，
斷言 t=130m 時仍在 firing（有回看窗：activeAt 仍是 0，已累積 130 分鐘；
無回看窗：計時器在 t=75 重數，只累積 55 分鐘，不燒）。這一個斷言就是全部差別。
兩個突變都被殺死（拿掉回看窗／把窗縮到小於實測空洞），還原後 `cmp` 為 byte-identical。
斷言數 34 → 37。重載後 `health: ok`／`lastError: none`——依 ADR-0007，
解析通過不算數，要看它**求值**得動。

**生產環境上仍是 `UNVERIFIED`，不要當成已證明。** 時間軸對過：
`lastConfigTime = 2026-09-04T22:51:03Z`（本地 09-05 06:51），
而最後一次 `activeAt` 重設是 `21:48:58Z`（本地 05:48:58，緊接 05:48:29 那次 DarkWake 之後 30 秒）
——**重設比修正早一小時**，所以那次不是修正失效；但也代表**修正還沒遇過任何一次睡眠**。
確定性證據（promtool ＋ 兩個突變控制）已經有了；
「它在真實睡眠窗後仍保住計時器」這件事要等下一次睡眠才會有答案。
判準：下次醒來後 `ALERTS_FOR_STATE{alertname="WidespreadGeoDrift"}` 的值**沒有前進**，
就是修正在生產環境上成立。

#### 第一版把下限放錯地方（同日修正，記錄下來因為它是本檔最常重演的缺陷）

下限**先是只加在告警的 expr**，recording rule 沒動。當天倒推展示鏈路時發現：
Grafana 面板「地區同向漂移比例」讀的正是 `dataops:yoy_geo_drift_share`，
於是板上會顯示猩紅熱 100%、旁邊卻沒有任何告警——而**該面板的說明白紙黑字寫著
「與 WidespreadGeoDrift 告警同一個定義（不是第二份副本）」**，那句話因此變成假的。

這正是這個檔案開頭那段註解警告過的事（「一個定義，兩個讀者」），
也是 Backlog 記過最多次的缺陷形狀：**閾值寫在兩個地方，今天同步，明天沒有守衛**。
守衛存在、註解存在，仍然踩了——因為改動只看了告警那一側。

修法：下限移進 recording rule，告警回到 `dataops:yoy_geo_drift_share > 0.25`。
驗證：規則測試（4 案例）與兩個突變控制不變且仍全過；重載後 recorded series
由 26 條降為 20 條（3 支小 N 疾病 × 2 個方向被排除），面板與告警讀同一份。
**低於下限的疾病沒有序列，不是零**——零會宣稱「量過了，沒有在漂移」，那是另一個沒有根據的主張。

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

### T3 從社群的教訓反向補守衛（規格 2026-09-04 修正）

**使用者的更正**：要的**不是**關鍵字搜尋或社群隨口提到的東西，
而是**被特地整理過、而且經過討論**的語料——而且範圍不只是 bug，
還包含**假影（hallucination／artefact）**與**「總是做推翻動作」**這類行為模式。

這個區別是實質的。隨手搜到的 issue 是**單一觀察**；
被整理並討論過的清單是**已經收斂過的形狀**——後者才是這個 repo 要的東西，
因為它整場在做的事就是維護一份失效形狀目錄，而不是一份 bug 清單。

**四類語料，各自的判準不同**

**動機（使用者提出）**：我們自己踩到的坑會變成守衛，但別人踩過的坑
不該等我們再踩一次。

**這一輪的三個坑全是同一類**：`stat -f`、`sed -i ''`、`dd bs=1m`——
BSD 與 GNU 的介面差異。這不是稀有知識，是有名的坑，
而我們是靠 CI 紅四次、再靠第二台機器開機才逐一發現的。

| 類別 | 語料要件 | 為什麼這個 repo 用得上 |
|---|---|---|
| **可機器讀的規則集** | 有編號、有理由、有社群維護（如 `shellcheck` 的 SC2xxx、`hadolint`、`actionlint`） | 每一條都能直接對應成一條靜態規則 ＋ 一個合成控制，形式與現有守衛完全一致 |
| **被討論過的事故彙編** | 有事後檢討、有討論串，不是新聞條目（如 `danluu/post-mortems`、`hjacobs/kubernetes-failure-stories`） | 提供的是**失效形狀**而不是修法，正好是這個 repo 的資產形式 |
| **假影／幻覺的分類法** | 有分類架構與例證，經過同儕討論，不是單篇抱怨 | 對「LLM 產出的程式碼」這個來源，需要的是**假成功的形狀**目錄：可解析但不可執行、可達但不再為真、註解描述的機制不存在——這三個這個 repo 都已獨立踩到過 |
| **「總是做推翻動作」的行為模式** | 對 agent／助手行為的整理性討論，不是個案 | 這是**過程**的失效不是產物的失效：反覆改寫同一段、把先前的結論推翻再推翻、用新的抽象掩蓋未解的問題。它不會出現在任何測試裡，只會出現在 diff 的形狀裡 |

**第四類最難也最值得**，因為它是唯一一種**測試抓不到**的。
本輪就有實例可以對照：我在同一個檔案裡把 `on_exit` 套錯又改回、
把靜態規則寫了又改兩次、`run_cmd` 的修法做了兩版——
每一次都有理由，但**「同一段在一個 session 內被改三次」本身就是一個訊號**，
而目前沒有任何東西在看它。

**可行的形狀**（登記，不實作）：

- 這個 repo 已經有的資產是**失效形狀目錄**與**每個守衛都有合成控制**。
  外部教訓應該以**同樣的形式**進來：一條靜態規則 ＋ 一個能紅的控制項，
  而不是一份「注意事項」文件——後者會退化成信念（本輪已有兩個實例：
  `service-health.yml` 說「沒有 node-exporter」、手冊說兩個缺口未修）。
- 來源優先序：**先做第一類**（可機器讀的規則集）。`shellcheck` 是最直接的入口，
  因為它同時滿足「被整理過」「被討論過」「可機器讀」三個條件，
  而且本輪三個坑（`stat -f`、`sed -i ''`、`dd bs=1m`）**它全都認得**。
  第二、三、四類需要人讀完再蒸餾成形狀，成本高但單位價值也高。
- **判準沿用 [[no-frankenstein]] 的三條**：外部方案先寫 watchlist，
  不直接納入。一條外部教訓要變成這裡的規則，必須先在這個 repo 裡
  找得到「它會發生」的證據，否則就是照抄別人的焦慮。

**為什麼現在不做**：這會新增一個工具與一批規則，而目前的方向是收斂。
等下一次「本機綠、別處紅」發生時，用那一次的具體案例當入口，
比一次導入一整套規則更容易站得住。

**驗收要件（做的時候）**：每一條從外部引入的規則都必須附一個**在這個 repo 裡
找得到的實例**，或一個能紅的合成控制。沒有實例也沒有控制的規則不准進來——
那是照抄別人的焦慮，而焦慮不是證據。

---

## §38 第二個 pilot 選什麼：推翻「先做 RL」，並指出倉庫裡已經躺著一個（2026-09-09）

### 先把兩個目的分開，因為它們要的東西相反

「找第二個 pilot」這句話同時裝了兩個目的，而它們拉向不同的方向：

| 目的 | 判準 | 什麼東西合格 |
|---|---|---|
| **A. 證明專案區隔是真的** | 讓現在只有一個值的維度**真的出現第二個值** | 越便宜越好、越快接上越好 |
| **B. 展示代表性與未來方向** | 給人看、能講故事、對得上職涯方向 | 越有企圖心越好 |

**這一週被咬了六次的都是 A 類問題**（§37）。用 B 類的東西去解 A 類的需求，
會得到一個很好看、但一年內接不上來的 pilot，而那六個假設會繼續是單值的。

### 對「digital twin in RL」的評估：方向對，順序錯，而且這台機器做不了訓練

**同意的部分**：digital twin 是對的方向，而且比再做一個時間序列預測有代表性。

**不同意的三點，每一點都有硬根據**：

1. **這台機器做不了 RL 訓練，而且不是錢的問題。** NVIDIA Isaac Sim／Isaac Lab
   要 RTX GPU 與 CUDA；這是 Apple Silicon 上**架構層面不可能**，不是授權貴或
   免費額度不夠。你擔心「很難前期 pilot 先行訓練」是對的，但理由比你說的更硬。
2. **本機憲章 §5c 直接擋住 RL 訓練。** 「>10 分鐘的持續滿載」是明文禁止的，
   理由是被動散熱會降頻，**測到的是散熱曲線不是程式行為**，結論不可重現。
   RL 訓練的本質就是長時間持續滿載。要跑，得先有容器或雲端環境——那是
   另一個題目，不是第二個 pilot。
3. **RL-in-sim 沒有「事後評分」這一格，而那是這個平台最新、最貴的一層。**
   `backtest-is-not-a-live-score` 記的形狀是：五個節點全綠，而**從來沒有一筆
   預測被拿去跟真實發生比過**。模擬器裡的「實際發生」就是模擬器自己。
   拿 RL-in-sim 當第二個 pilot，等於**照著設計把剛修好的那個失效重建一次**。

### 而且 digital twin 不等於 RL——順序本來就該反過來

Twin 是「一個你可以拿來跑反事實的系統模型」。RL 是**長在 twin 上面的策略層**。
Isaac 自己的流程也是這個順序：先有 sim，才在裡面訓練 policy。
先做 twin、後做 RL，好處是 twin **可以被真實資料校準、也可以被事後評分**——
它有 A 類價值；直接做 RL 則兩者皆無。

### 倉庫裡已經躺著一個更好的第二個 pilot：結核病

`surveillance_fact` 現在裝的東西比類流感 pilot 用到的多得多：

| metric | 列數 | 時間層級 | 地理數 | 期間 | 分母 |
|---|---:|---|---:|---|---|
| `nhi_visits` | 1,980,585 | epi_week | 22 | 2016–2026 | **全部有** |
| `tb_under_management` | **1,368,039** | **day** | **367（鄉鎮）** | 2016-01-01 – **2026-09-03** | 無 |
| `tb_confirmed_under_management` | 1,368,039 | day | 367 | 同上 | 無 |
| `tb_mdr_under_management` | 1,368,039 | day | 367 | 同上 | 無 |
| `rods_ed_visits` | 442,783 | epi_week | 22 | 2007–2026 | 無（T26） |

**結核病資料已經載好、而且是最新的**（最後一天 2026-09-03，量測當天的三天前）。
它讓現在單值的維度全部出現第二個值：

- `time_level`：pilot 只用 `epi_week`，TB 是 `day`
- 地理粒度：pilot 用 22 個縣市，TB 有 367 個鄉鎮
- `metric`：pilot 只碰 `nhi_visits`
- **流量 vs 存量**：ILI 是發生率（flow），`tb_under_management` 是在管人數
  （stock）。整條特徵管線目前假設分子／分母同步到達——TB 的分母只有
  `demographic_fact` 的**年度**人口（7,626 個地理、2021–2025），
  **分子日、分母年**。這正是特徵建構器沒被試過的地方。
- 疾病學形狀完全不同：慢性、變化慢、有治療中斷與抗藥（MDR）這種
  ILI 沒有的結構。

### 建議的順序

1. **第二個 pilot ＝ 結核病**（A 類）。資料已在，成本主要是建模決定不是工程；
   它會把 §37 那六個「假設只有一個」真的推到第二個值。
2. **digital twin 當第三步**（B 類），而且**不從 RL 開始**：先做一個能被真實
   資料校準、預測能被事後評分的 twin。`rods_ed_visits` 沒有分母而被 T26 擋下來
   ——**計數當作率是壞的，當作到達過程卻正是對的**，被拒絕的那份資料在這裡
   反而是合格的輸入。
3. **RL 等到有容器或雲端 GPU 環境再談**。在那之前它在本機是憲章禁止的動作，
   不是「還沒排時間」。

### 這一節沒有回答的

- 結核病要預測什麼還沒定（在管人數？MDR 比例？鄉鎮層級的新發？），
  而**「預測什麼」是這個 pilot 唯一真正困難的決定**——資料工程幾乎是零。
- 日分子／年分母怎麼配對是一個有後果的建模決定，和 T26 的分母問題同一類。
- 未在此登記為 T 項目：這是**選型建議**，等使用者決定要不要走。

---

## §39 RL 的前置練習：這個平台已經有一個序列決策問題，而它的動作空間只有一格（2026-09-09）

### 不用蓋模擬器就能做的 RL 練習：上線閘門本身

「先做 RL」被推翻的理由是模擬器裡沒有真實回饋（§38）。**但這個 repo 已經有一個
有真實回饋的序列決策問題**——每週的上線閘門：

| RL 的元件 | 這個平台已經有的東西 |
|---|---|
| 狀態 | 各候選模型的滾動誤差、現役是誰、持平基準的滾動誤差 |
| 動作 | 續用現役／換成挑戰者／**拒絕發布** |
| 回饋 | 發布出去那個數字對上**真的到來的那一週**的誤差 |
| 已記錄的軌跡 | `policy_backtest.py` 的 **451 個 origin、431 次發布** |

這是 **offline / off-policy evaluation**，不是模擬。回饋來自現實，
跑完六個設定不到十分鐘，不需要 GPU，也不違反憲章 §5c。

### 第一次掃描的結果：`REPLACEMENT_MARGIN` 從未改變過任何決策

`--margin` 掃 `0.00 / 0.01 / 0.02 / 0.05 / 0.10 / 0.20`，
六個結果**逐位元相同**（證據：`evidence/mlops/policy_margin_sweep_*.json`）。

原因用 `--lock-family` 分離出來了：

| 只准這個家族上線 | 通過閘門 | 勝率 | 對持平基準 |
|---|---:|---:|---:|
| `HistGradientBoostingRegressor` | **431 / 451** | 52.0% | **+6.58%** |
| `Ridge` | 151 / 451 | 43.7% | **−7.13%** |

**margin 仲裁的是接近的平手，而這裡沒有平手。** ADR-0016 花了很多篇幅在
「相對 2%、同分留任」，那條規則是對的、也是必要的護欄——
**但在 431 次真實決策上，它一次都沒有生效過。**它不是錯的，是**未被現實測試過的**。

### 所以 RL 的前置條件不是算力，是動作空間

**一個每個狀態下都由同一個動作支配的問題，學不出策略。** 目前的動作空間
實際上只有一格。要讓它變成真的可學，需要的是**便宜的第三、第四個候選**
（季節性 naive、指數平滑、對數尺度的 HGB——都是秒級），
讓閘門真的面臨選擇。那時候：

1. margin 掃描才會畫出一條真的曲線，而不是一條水平線
2. 431 筆軌跡才是一個 contextual bandit 的資料集
3. **offline RL 的核心難題會自己出現**：軌跡是由**一個**策略產生的，
   評估一個差很多的策略會遇到分布偏移——那正是要練的東西，
   而且是用真實資料練，不是在模擬器裡自己跟自己玩

### 建議的三步（每一步都可獨立交付）

| 步 | 做什麼 | 為什麼是這個順序 |
|---|---|---|
| 1 | 加 2–3 個便宜的候選模型家族 | 沒有這一步，後面兩步都在一個單臂問題上做 |
| 2 | 把 margin 掃描變成排程產物，並在板面上畫策略價值曲線 | 這是 off-policy evaluation 的最小可用版本，回饋來自現實 |
| 3 | 校準式 twin（結核病的 stock/flow）＋在 twin 裡做策略 | **twin 的預測可以被事後評分**，所以可以先回答「這個模擬器值不值得在裡面最佳化」 |

**第 3 步才是 RL 的入口，而它的前提是第 2 步證明了 off-policy evaluation 這件事
在這裡做得起來。** NVIDIA Isaac 之類的平台跳過的正是第 2 步——
它給你一個很好的模擬器，卻不會告訴你那個模擬器像不像真的。

### 未登記為 T 項目

同 §38，這是**選型與順序的建議**，等使用者決定。唯一已經做掉的是掃描本身
與它的證據檔。

---

## §40 RL 的醫療版前置練習：疫情示警政策，以及它在選波峰不是選起點（2026-09-09）

### 先修正上一節（§39）的框架

§39 說「平台裡已經有一個序列決策問題」，指的是**上線閘門**。那是對的，但它是
**MLOps 的決策不是醫療決策**——換不換模型跟臨床或公衛沒有關係。使用者要的是
醫療相關的，而平台裡真正醫療的那個序列決策在另一個地方。

### 醫療的那一個：每週、每縣市、每疾病，要不要示警

| RL 的元件 | 平台裡已經有的東西 |
|---|---|
| 狀態 | 本週率、去年同週率、年比、鄰近幾週趨勢、跨縣市擴散程度 |
| 動作 | 示警／不示警（未來可以是分級） |
| 回饋 | **後來真的發生了什麼**——資料庫裡已經有 |
| 決策點 | **1,041,073** 個（11 疾病 × 22 縣市 × 557 週，2016–2026） |
| 有可比較去年同週且過分母門檻的 | **84,186** |

**不需要模擬器**，回饋來自現實；不需要 GPU；一次掃描是一句 SQL。
可重跑：`platform/dataops/outbreak_alert_sweep.sql`。

### 第一次掃描的結果：現行門檻比隨機還差

`DRIFT_HIGH = 2.0`（`platform/dataops/pipeline_metrics.py`）是手設的，
從來沒有對照過後果。把它掃過去：

| 年比門檻 | 示警數 | 佔全部格子 | **下週仍在上升** |
|---:|---:|---:|---:|
| 1.5 | 14,396 | 17.03% | 45.8% |
| **2.0（現行）** | **7,805** | **9.23%** | **46.2%** |
| 2.5 | 4,913 | 5.81% | 46.0% |
| 3.0 | 3,480 | 4.12% | 47.0% |
| 4.0 | 2,106 | 2.49% | 48.8% |
| 6.0 | 1,206 | 1.43% | 52.7% |
| **（無條件基準率）** | — | 100% | **49.5%**（n=94,302） |

**現行門檻選出來的那些週，下週繼續上升的機率（46.2%）比隨機挑一週（49.5%）
還低。** 把門檻拉高 4 倍，示警量少 6.5 倍，而結果只從 46.2% 動到 52.7%。

**這在流行病學上完全講得通**：一個 2 倍的年比躍升，通常代表波峰**已經到了**，
而波峰之後是下降。**這個政策在選異常的大小，不是在選事情的開始**——
而它的名字（drift／示警）與門檻的形狀都在暗示後者。

### 這一節沒有證明什麼

- **沒有證明這個告警沒用。** 波峰值得知道，它只是跟「起點」不是同一件事。
- **回饋代理很粗**：「下週的率比這週高」是一個一週、二元的代理。真正的起點是
  一個跨數週的形狀，而**「什麼算該被抓到的疫情起點」是臨床／流病判斷，不是
  工程判斷**。這是整件事唯一的硬前提。
- 實際部署的 `WidespreadGeoDrift` 還額外要求漂移**跨多個縣市**；上表是那層
  彙總底下的逐格觸發率。

### 所以前置練習的順序

| 步 | 做什麼 | 為什麼是這個順序 |
|---|---|---|
| 1 | **定義獎勵**：什麼算「該被抓到的疫情起點」 | 這是臨床決定。沒有它，後面每一步最佳化的都是「下週有沒有變高」，而那接近擲硬幣 |
| 2 | 找一個真的有鑑別力的狀態表徵 | 年比的鑑別力已經量出來是負的。**一個學不出東西的特徵，換多強的演算法都學不出東西** |
| 3 | 在 84,186 筆軌跡上做 off-policy evaluation | 這時候門檻掃描才會畫出一條真的曲線 |
| 4 | 才是策略學習 | 前三步任何一步沒完成，第四步都是在最佳化雜訊 |

**第 1 步不需要程式，需要的是跟公衛或臨床的人坐下來把它寫成一句可判定的話。**
這是這整條路上唯一不能由這個 repo 自己完成的一步。

### 跟 §39 的關係

兩個都是序列決策、都有真實回饋、都不需要模擬器。差別是：

- **§39 上線閘門**：451 個 origin，但**動作空間實際上只有一格**（HGB 支配
  Ridge），所以學不出策略。
- **§40 疫情示警**：**1,041,073 個決策點**，動作空間真的有兩個選項，
  但**目前的狀態表徵鑑別力是負的**。

**兩種缺陷不一樣，而且都不是算力問題。** 一個缺動作，一個缺特徵。

### 未登記為 T 項目

同 §38／§39，這是選型與順序的建議。已經做掉的是掃描本身、可重跑的 SQL
（`platform/dataops/outbreak_alert_sweep.sql`）與證據檔
（`evidence/mlops/outbreak_alert_policy_sweep_*.json`）。

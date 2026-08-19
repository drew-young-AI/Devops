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
| 2 | station2-twin 接進 blue/green | ❌ 被取代 | **不要投入** |
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

## 2. station2-twin 接進 blue/green — 不要投入

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

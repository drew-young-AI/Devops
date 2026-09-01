---
type: explanation
title: 存取控制現況與權限區隔路徑
description: "What the LAN can reach today, why each listener is where it is, and the concrete path to role separation in Grafana when more than one person needs access."
tags:
  - access-control
  - grafana
  - security
  - lan
timestamp: 2026-08-27T00:00:00+08:00
---

# 存取控制現況與權限區隔路徑

寫給日後要討論權限的人。**現況是一個刻意的決定，不是還沒做完的狀態**——決定的內容、理由、和它的代價都寫在下面，這樣討論才有東西可談。

## 一、現在區網上有什麼

平台在 2026-08-26 之前全部綁在 `127.0.0.1`，只有本機看得到。當天起，三個服務改為區網可達。

| 位址 | 服務 | 認證 | 誰做的決定 |
|---|---|---|---|
| `:18085` | 階段燈號（html / json / md） | 無（非機密、允許清單） | 平台 |
| `:13000` | Grafana | **有**（匿名關閉，admin 密碼存 Vault） | 平台 |
| `:19090` | Prometheus | **無** | 平台擁有者明示決定 |
| — | Alertmanager / Loki / node-exporter / nginx TLS vhost | — | 維持 loopback |

`platform/tests/test_network_exposure.sh` 每次跑測試都重新量一次，10 項斷言。**它先證明探測方法真的連得上，才准相信任何一個「拒絕」**——第一版用 mDNS 名字探測，名字同時解析到 `::1`，整趟走了 loopback，那些「拒絕」從頭到尾沒被測過。

## 二、Prometheus 無認證是明示接受的風險

決定日期 2026-08-26，決定者為平台擁有者，理由是「大家一起承受」。記錄在此，讓它保持為一個決定而不是變成沒人記得的意外。

**已做的緩解**（實測而非推論）：

- `--web.enable-lifecycle` 與 `--web.enable-admin-api` 皆未啟用 → 這個監聽埠是**唯讀**的
- 實測 `POST /-/reload` → 403、`POST /-/quit` → 403、admin 刪除序列端點拒絕且資料完好

**剩餘的暴露**：區網上任何人可讀取平台全部指標——服務名稱、節點狀態、資料筆數、模型分數。無法讀取日誌內容（Loki 仍為 loopback），無法靜音告警（Alertmanager 仍為 loopback）。

## 三、關鍵限制：Grafana 的權限只擋得住走 Grafana 的人

這是討論權限區隔時**必須先講的一句話**，否則後面的設計會建立在錯的前提上。

Grafana 的 Viewer 角色可以限制某人在 Grafana 裡看得到哪些儀表板。但 Grafana 的資料來自 Prometheus，而 **Prometheus 在同一個區網上、沒有認證**。任何被限制成 Viewer 的人，只要直接打 `:19090`，就能拿到 Grafana 不給他看的同一批指標。

**所以：Grafana RBAC 的實際強度 = 最弱的那個對外端點。** 只要 Prometheus 維持無認證且區網可達，Grafana 的角色區隔是「介面上的分工」，不是「存取控制」。

這不表示現在做角色區隔沒有意義——分工本身有價值（不同人看不同的預設畫面、避免誤改）。但它不能被當成安全邊界向長官陳述。

## 四、要做真正的權限區隔時，路徑是這樣

**前提步驟（沒有它，後面全是裝飾）**

0. **Prometheus 移回 loopback，或放到需認證的反向代理後面。** 兩個選項：
   - 移回 `127.0.0.1`，所有人一律經由 Grafana 讀指標
   - 保持區網可達，但改由 nginx 代理並加上驗證（平台已有 nginx，這是既有能力）

**Grafana 側（依序）**

1. **停止共用 admin 帳號。** 目前只有一個帳號，密碼存在 Vault。多人共用管理員帳號的稽核軌跡等於零——日誌只會說「admin 做了某事」。
2. **每人一個帳號，指派 Org 角色**：`Admin`（你）／`Editor`（工程）／`Viewer`（長官與其他檢視者）。
3. **用資料夾切分儀表板**，權限下放到資料夾層級。長官只需要「三線階段燈號」，不需要看到節點層級的除錯儀表板。
4. **程式存取一律用 service account token，不要用人的帳號。** 人的帳號離職就該停用，而停用一個被腳本使用中的帳號會讓自動化在無關的時間點壞掉。
5. **納入既有的憑證輪替機制**：`platform/vault/scripts/rotate_secret.sh` 已能輪替 Grafana 憑證，`setup_grafana_identity.sh` 已會寫入 Vault。

**每一步都要有負向驗證**，與平台其他部分同一標準：建立 Viewer 之後，實際用該帳號嘗試修改儀表板並確認被拒；而不是看設定畫面上的角色欄位寫著 Viewer 就當作完成。

## 五、還沒證明的事

- **UNVERIFIED**：`test_network_exposure.sh` 已證明它的斷言會紅（把探測指向 loopback → 3 項轉紅），但**尚未證明它會抓到真實的 compose 變更**（實際把 Alertmanager 推上區網再還原的突變測試被權限機制擋下，未執行）。
- 筆電闔上時，上述三個區網位址全部消失。這不是設定問題，是這台機器的性質。任何以「隨時可查」為前提的討論都要先處理這一點。

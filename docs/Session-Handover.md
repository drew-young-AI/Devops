---
type: reference
title: 新 session 的接手路由
description: "What a fresh session must read, in what order, and what it must not re-derive. A router, not a status page."
tags:
  - handover
  - onboarding
timestamp: 2026-09-04T00:00:00+08:00
---

# 新 session 的接手路由

**這份文件裡沒有任何數字。** 這是刻意的。

這個 repo 的規矩是**現況頁必須產生式**（[Doc Provenance](Reachability.md)）——
手寫的現況會退化成信念，而本專案已經有三個實例：
`service-health.yml` 說「沒有 node-exporter」時它已跑了數週；
`Ubu-Prod-Bringup.md` 說兩個缺口未修時它們早已修好；
`Backlog.md` §20 的頻率表把每日更新的來源記成「年」，差兩個數量級。

所以這裡只放**兩種東西**：

1. **指標** —— 去哪裡取得當下的真相（都是可重跑的指令）
2. **不可推導的判斷** —— 讀完整個 repo 也得不到、只有踩過才知道的東西

`verify`：`platform/tests/test_static.sh`（含本檔所有路徑的存在性檢查）

---

## 一、開場的四個指令（不要用讀的推測狀態）

```bash
platform/recover.sh --check          # 什麼東西沒在跑（會不會需要 unseal）
platform/tests/run_all.sh            # 契約是否成立（tier 1-3，約 6-7 分鐘）
platform/scheduler/status.sh         # 排程有沒有在跑、哪些從未被觸發
python3 platform/statusdag/dag.py --json | python3 -m json.tool | head -40
```

第四個是**平台對自己的判定**。它的 `verdict` 與每個節點的 `detail`
就是「現在哪裡是紅的」的權威答案，不需要任何人整理。

**如果 Docker 沒有回應**（指令掛住而不是快速失敗）：引擎可能死了但
socket forwarder 還在接連線。處置見下方「三、會再遇到的坑」。

## 二、讀的順序，以及每一份負責什麼

| 順序 | 檔案 | 它回答什麼 | 不要用它回答什麼 |
|---|---|---|---|
| 1 | [`README.md`](../README.md) | 總表：有什麼、在哪裡、怎麼跑 | 現在的狀態 |
| 2 | [`docs/Backlog.md`](Backlog.md) **§27** | **待辦登記簿**——每筆都有「為什麼現在不做」與「什麼時候該做」 | — |
| 3 | [`docs/Backlog.md`](Backlog.md) §19–§26 | 最近幾輪的完整推理與量測 | — |
| 4 | [`docs/decisions/`](decisions/) | 每個決定的理由，**每筆都附 `rerun:` 指令** | — |
| 5 | `~/.claude/projects/-Users-drew/memory/MEMORY.md` | 跨 session 的耐久事實 | 專案內的細節（那些在 repo 裡） |

**§27 是接手的主入口。** 它是這個 session 建立的登記簿，
規則寫在該節開頭：**只登記，不實作；需求不擴張，功能逐步收斂落地。**

## 三、會再遇到的坑（讀 repo 得不到的）

### 1. 兩台機器、兩個作業系統——本機綠不代表別處綠

`ADR-0008` 從 2026-08-31 就宣告平台橫跨 macOS(arm64) 與 Linux(amd64)，
但在第二台開機前沒有任何東西檢查另一邊。開機當天就找到**四個已經推上去的缺陷**。

**推之前跑 `platform/tests/run_on_ubu.sh`**（rsync 工作目錄到 ubu，跑 CI 那一層）。
它不取代 CI，只是把「四個 commit 之後被 CI 告知」變成「推之前就知道」。

已知的 macOS-only 寫法（都已有靜態規則＋合成控制，但**寫的時候就要想到**）：

| 寫法 | Linux 上會怎樣 |
|---|---|
| `/System/Volumes/Data` | `df` 直接失敗；Linux 用 `/` |
| `sed -i ''` | GNU sed 把 `''` 當腳本、腳本當**檔名**，靜默什麼都沒改 |
| `stat -f` | 不存在 |
| `dd bs=1m` | `invalid number '1m'`，且錯誤訊息去了被重導掉的 stderr |
| 直接呼叫 `docker` | 不存在 → 未捕捉的 `FileNotFoundError` 變成假缺陷 |

**ubu 上沒有免密碼 sudo，也沒有任何建置工具**（無 docker/podman/buildah，
只有需要 root 的 `ctr`）。這是走 GitHub Actions 建置的實際原因，不是偏好。

### 2. Docker 掛住而不是失敗

引擎死掉後 backend 的 socket forwarder 仍會接受連線，於是每個 `docker`
指令**掛住**。`docker desktop restart` 可能因 backend 不理會 TERM 而失敗；
那時要 `kill -9` 該 process 再 `open -a Docker`，引擎約 2 分鐘回來。
回來後跑 `platform/recover.sh`（Vault 會是 SEALED，那是預期的）。

### 3. 磁碟：先看 `$TMPDIR`，不要先看 Docker

2026-09-03 那場停機的根因**不是 Docker**，是測試套件的 sandbox 洩漏
（421GB 在 `$TMPDIR`）。已修並有 `test_sandbox_hygiene.sh` 守著，
但下次磁碟又緊時的正確順序是：

```bash
du -sh "${TMPDIR%/}"                             # 先這個
platform/observability/host_disk_metrics.sh --stdout
platform/observability/docker_reclaim.sh --dry-run
```

**`ls -lh` 對 `Docker.raw` 顯示 926G 是假警報**——那是 sparse image 的
apparent size，真實佔用要看 `stat -f %b × 512`（約 22GB）。
**不要用 `docker system prune -a`**：它會刪掉本機建置、無處可補的
`station2-ingest:local`、`station2-mlops:local` 與 registry 的 `v15`/`v15-green`。

### 4. `test_static.sh` 的守衛會匹配到自己的散文

**本 session 發生六次。** 這不是疏忽，是方法的定義性質：
**一個文字比對的守衛，活在它所搜尋的語料裡。**
在該檔新增規則時，**預設它會發生**——把樣式用字元碼或變數組裝，
讓字面字串根本不出現在檔案裡。既有的 `scan_bsd_sed` / `scan_bad_dd` /
`scan_uppercase_image` 都是這樣寫的，照抄形式即可。

### 5. 子 shell 是狀態去被遺忘的地方

`X="$(f)"` 是命令替換＝子 shell。函式裡對**陣列**的追加會隨子 shell 消失。
本 repo 已因此付出兩次代價：一個合成控制的計數器永遠到不了 3；
sandbox 註冊表**從來沒有清理過任何東西**（421GB 的成因）。
需要跨子 shell 累積時**用檔案，不要用陣列**（見 `lib.sh::SANDBOX_REGISTRY`）。

### 6. 把檢查加進不會執行的分支

本 session 發生一次：新增的驗證區塊被插進 `if [ ! -x venv ]` 的 SKIP 分支，
**從來沒有執行過，而套件報綠**。唯一露餡的是**斷言總數沒有增加**。
沒有工具抓得到（語法正確、在檔案裡、看起來像被執行）。
**新增斷言後，比對套件的斷言數是否真的增加。** 登記為 T12。

## 四、目前的三條紅線（狀態請以指令為準，這裡只說形狀）

1. **`mgate`**：閘門有在擋（贏才准上線），但**模型輸給持平基準**。
   系統在做對的事，不是故障。要不要動模型是**新增範圍**的決定。
2. **`prodk8s`**：ubu 叢集就緒但**沒有任何工作負載**——刻意回報 WARN 而非 OK，
   因為空叢集只證明 API server 會回應。pilot 上 prod 卡在 Vault 與資料庫
   （`deployment-template.yaml` 的 `PGHOST`/`VAULT_ADDR` 指向 k3d 專屬名字）。
3. **只有 Telegram 通知得到人**；email 缺的是憑證不是實作（B4）。
   **Telegram bot token 已外洩到 Loki 日誌（B10），需要輪替**——
   只有使用者能對 BotFather `/revoke`。

## 五、只有使用者能做的（不要嘗試代勞）

見 [`docs/Backlog.md`](Backlog.md) 的 B1–B10 表。本輪新增／仍未解的：

- **B10 Telegram token 輪替**（有時效性）
- **停用 ubu 休眠**（ubu 上沒有免密碼 sudo）——會休眠的筆電不是生產主機
- **固定 IP**（路由器保留位址）——理由**不是** kubeconfig（它走名字），
  是診斷路徑寫死了 IP，以及 mDNS 可以單獨失效時需要第二條路

## 六、這個 repo 真正的資產

工具會換掉，這三樣不會（[`docs/Reachability.md`](Reachability.md)）：

1. **失效形狀目錄** —— 「登記為存在，但不執行」／「空集合上的恆真句」／
   「可達不等於還是真的」／「兩份索引是分岔問題」／「註解描述的機制不等於機制存在」／
   「執行了，但沒有效果」／「監控系統被它沒有監控的東西弄停了」
2. **證據紀律** —— 每個數字都要有 provenance；
   **估計值在表格裡和量測值長得一模一樣**
3. **每個守衛都有證明它會紅的合成控制** ——
   沒有被證明能失敗的守衛，和不能失敗的守衛，從輸出上分不出來

**接手時如果只記得一件事：不要用讀的推測狀態，跑第一節那四個指令。**

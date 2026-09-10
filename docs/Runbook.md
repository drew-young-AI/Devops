---
type: reference
title: 必備操作手冊：沒有 agent、沒有網路，一個人怎麼把它跑起來
description: "The minimum a human needs to start, check, recover and stop this platform without an AI agent and without internet access. Commands only; every one of them is verified to exist by platform/tests/test_runbook.sh."
tags:
  - runbook
  - operations
  - handover
timestamp: 2026-09-09T00:00:00+08:00
---

# 必備操作手冊

**這份文件的前提是最壞的情況：沒有 AI agent、沒有網路、只有這台機器和這個
repo。** 所以它裡面沒有任何外部連結，不解釋設計理由（那些在各層的 README
裡），只有**做什麼**與**怎麼判斷**。

**每一條指令都由 `platform/tests/test_runbook.sh` 驗證存在且可執行。**
這份手冊指到不存在的東西時，測試會紅——這是它跟一份會腐爛的散文的差別。

---

## 一、四條指令（記住這四條就夠）

```bash
cd /Users/drew/ENV/Devops

platform/recover.sh                 # 起：把所有東西拉起來並解封 Vault
platform/recover.sh --check         # 查：什麼沒在跑（唯讀，不改任何東西）
platform/observability/check_health.sh   # 判：整個堆疊的確定性判定
platform/tests/run_all.sh 2>&1 | tail -20   # 證：契約還成不成立（約 6 分鐘）
```

`check_health.sh` 的**退出碼就是答案**，不需要讀輸出：

| rc | 意思 | 該做什麼 |
|---:|---|---|
| 0 | HEALTHY | 不用做事 |
| 1 | DEGRADED | 看輸出裡的 `runbook:` 那一行，每條告警自己帶處置 |
| 2 | CRITICAL | 同上，但先做 |
| **3** | **UNKNOWN** | **監控自己壞了**，健康狀態無法判定。先修監控再談其他 |

**rc 3 是這支腳本存在的理由**：壞掉的 Prometheus 回報「零個告警」，健康的
Prometheus 也回報「零個告警」。

`platform/scheduler/status.sh` **也用退出碼講話**，而且數字的意思跟上面那張表
不一樣——不要把兩張表記混：

| rc | 意思 | 該做什麼 |
|---:|---|---|
| 0 | `ALL_FRESH` | 不用做事 |
| 1 | `DEGRADED_OR_LATE` | 有工作 degraded／not-configured／遲到。看那一列的名字 |
| 2 | `CRITICAL` | 有工作 failed／timeout |
| **3** | **`STALE_OR_UNKNOWN`** | **有工作的紀錄過期了**——「四天前回報 ok」不是 ok，是一個過期的宣稱 |

**rc 3 排在 rc 2 前面是刻意的。** 一個失敗的工作看得見，一個不再回報的工作
看起來跟成功一模一樣。

**剛喚醒的筆電第一次跑會是 rc 1 或 3，而排程沒有壞**——睡眠期間不會觸發。
等一個週期再看（見第五節第 3 點）。

---

## 二、開機之後一定要做的一件事

**Vault 重開機後是封起來的（sealed）**，而封著的時候沒有任何憑證可用——
身分、CI、Grafana 管理員、稽核寫入全部停擺。而排程器**照常每分鐘觸發**，
於是狀態是「每個工作準時執行、全部失敗」。

```bash
platform/recover.sh            # 它會順便解封
# 或只解封：
platform/vault/scripts/init_and_unseal.sh
```

自動解封**刻意沒有接**：解封金鑰就在這台機器的
`platform/vault/.init-output.json` 裡，開機自動解封並不會讓安全性差多少，
但「反正已經不安全了」不是拿掉最後一道人為關卡的好理由。

---

## 三、憑證：不是「有一把密碼」，是「你自己拿得到」

**這一節的判準是：一個沒有 AI、沒有網路的人，照著做就拿得到，不用問任何人。**
上一版只寫了「解封金鑰在 `.init-output.json`」——那句話告訴你密碼存在，
沒告訴你怎麼用，而讀的人會撞在 `permission denied` 上然後卡住。

**這裡不寫任何密碼的值。** 寫的是帳號、位置、與取出的指令。

### 第 0 步：所有東西都在 Vault 後面，先進得去

```bash
cd /Users/drew/ENV/Devops

# 1. Vault 封著的話先解封（重開機後一定是封的）
platform/vault/scripts/init_and_unseal.sh        # 需要 5 把裡的 3 把，腳本自己讀

# 2. 拿 root token（它在這個檔的 root_token 欄位）
VT=$(python3 -c "import json;print(json.load(open('platform/vault/.init-output.json'))['root_token'])")

# 3. 列出有哪些機密
docker exec -e VAULT_TOKEN="$VT" -e VAULT_ADDR=http://127.0.0.1:8200 \
  vault-vault-1 vault kv list secret/devops

# 4. 取一筆（-field 只印那一個欄位，不會把整包倒出來）
docker exec -e VAULT_TOKEN="$VT" -e VAULT_ADDR=http://127.0.0.1:8200 \
  vault-vault-1 vault kv get -field=username secret/devops/grafana-admin
docker exec -e VAULT_TOKEN="$VT" -e VAULT_ADDR=http://127.0.0.1:8200 \
  vault-vault-1 vault kv get -field=password secret/devops/grafana-admin
```

**`VAULT_ADDR` 一定要給。** 少了它，`vault` 指令會去問 `https://127.0.0.1:8200`
（預設是 https），Vault 是 http，於是錯誤訊息講的是 TLS 而不是位址。

### 憑證清單

| 要什麼 | 帳號 | 真實來源 | 實體檔案 | 進版控？ | 怎麼拿 |
|---|---|---|---|---|---|
| **Vault 主鑰** | — | 這個檔本身 | `platform/vault/.init-output.json` | **否**（gitignored） | 5 把 unseal key（門檻 3）在 `unseal_keys_b64`，root token 在 `root_token` |
| **Grafana 管理員** | `admin` | Vault `secret/devops/grafana-admin` | `platform/observability/.grafana.env` | **否** | 上面第 4 步；或 `grep GF_SECURITY_ADMIN_PASSWORD platform/observability/.grafana.env` |
| **GitHub token** | — | Vault `secret/devops/github` | — | — | 上面第 4 步，`-field=password` |
| **GHCR（映像庫）** | — | Vault `secret/devops/ghcr` | — | — | 同上 |
| **pilot 資料庫** | `twin` / db `twin` | 容器環境變數 | `pilots/station2-twin/.env`（由 `config.example.env` 複製） | **否**（範例檔才進版控） | `docker exec station2-twin-db-1 sh -c 'printf %s "$POSTGRES_PASSWORD"'` |
| **pilot AppRole** | — | Vault（動態核發） | `platform/vault/.station2-twin-approle.json` | **否** | `platform/k8s/station2-twin/sync_vault_secret.sh` 重新核發 |
| **生產節點 ssh** | `drew` | 你的 ssh 金鑰 | `~/.ssh/` | **否** | `ssh drew@ubu.local`（**用主機名，那台沒有保留 IP**） |

**三個 `.` 開頭的檔都是 gitignored。** 意思是：**換一台機器 clone 這個 repo，
這三個檔都不會跟過去**——`.init-output.json` 沒有備份就等於整個 Vault 沒了，
另外兩個可以由腳本重建（見下）。

### 不一致或不見了怎麼辦

| 症狀 | 做什麼 |
|---|---|
| Grafana 登不進去 | `platform/observability/scripts/setup_grafana_identity.sh` — 從 Vault 取值、重設現行密碼、重寫 `.grafana.env`，並驗證 `admin/admin` 已不被接受。**過程中不印密碼。** 瀏覽器存的舊帳密要自己更新（帳號是 `admin`） |
| `.grafana.env` 不見 | 同上一格。它是**可丟棄的傳遞檔**，不是第二個真實來源 |
| AppRole 過期／不見 | `platform/k8s/station2-twin/sync_vault_secret.sh` |
| `.init-output.json` 不見 | **沒有救。** 這是唯一一份主鑰。這也是為什麼 `platform/vault/README.md` 說要把它移到這台機器以外 |

### 已知缺口：程式引用了一筆不存在的機密

`platform/notify/setup_mail.sh` 讀 `secret/devops/smtp`，而 Vault 裡**沒有這一筆**
（`vault kv get` 回 `No value found`）。這就是板面上 `alertmgr` 說
「宣告了但沒接上: email」的實際原因——不是程式壞了，是那筆機密從來沒被建立。
建立它需要一組真的 SMTP 帳密，那是使用者的事（Backlog B 系列）。

---

## 四、打開哪裡看

| 看什麼 | 網址 | 要登入 |
|---|---|---|
| 三線階段燈號（給人看的總覽） | `http://mac.local:13000/d/platform-stages/` | Grafana 帳號 |
| 靜態階段報告（可離線轉寄） | `http://mac.local:18085/Stage-Report.html` | 否 |
| 原始指標查詢 | `http://mac.local:19090/` | 否（刻意） |
| pilot 應用 | `http://127.0.0.1:18090/` | 否 |

主機名由 `scutil --get LocalHostName` 決定，不是寫死的。**`mac.local`
解析不到時就用 `localhost`**——所有服務在本機都通。

---

## 五、東西壞了：三個判斷順序

### 1. `docker` 指令掛住而不是快速失敗

引擎死了但 socket forwarder 還在接連線，所以指令會**卡住**而不是報錯。
**不要反覆重試**——重開 Docker Desktop，再跑 `platform/recover.sh`。

### 2. 磁碟

先看 `$TMPDIR` 所在的磁碟，不要先看 Docker。

```bash
df -h /                                    # 主磁碟
platform/observability/host_disk_metrics.sh   # 平台自己量的那份
```

磁碟填滿會停掉整個平台，而它曾經是唯一沒被量的數字。

### 3. 剛喚醒的筆電

睡眠期間排程不會跑，醒來後第一次檢查會回報 `FAILED`／覆蓋缺口，
**而排程沒有壞**。等一個週期再看，或直接：

```bash
platform/scheduler/status.sh
```

---

## 六、資料與備份

```bash
platform/backup/backup.sh          # 備份（排程每天跑，這是手動觸發）
platform/backup/restore_drill.sh   # 還原演練——沒還原過的備份不算備份
platform/db/migrate.sh             # 套用 pilot 的 schema migration
```

**還原演練不是可選的。** 這個平台上曾經有 158 個空目錄讓 47 份備份看起來
像 205 份；備份存在與備份可用是兩件事，只有演練能分辨。

---

## 七、Kubernetes

```bash
platform/k8s/bootstrap_k3s.sh                  # 建本機練習叢集（k3d）
kubectl --context k3d-devops-lab get pods -A   # 本機
kubectl --context ubu get nodes                # 生產節點（Ubuntu）
ssh drew@ubu.local                             # 生產節點的殼
```

**用主機名 `ubu.local`，不要記 IP。** 那台機器沒有 DHCP 保留位址，
IP 已經在 `.143` 與 `.144` 之間漂移過三次；記在文件裡的數字會讓人停止查證。

ubu 上**沒有 Docker**（它跑 k3s over containerd），所以任何需要容器映像的
腳本在那裡不能跑。

---

## 八、平台完全不見了：從零開始的順序

```bash
cd /Users/drew/ENV/Devops
platform/recover.sh                          # 1. 拉起 vault / observability / nginx / pilot 並解封
platform/observability/check_health.sh; echo "rc=$?"   # 2. 判定
platform/k8s/bootstrap_k3s.sh                # 3. 只有在 k3d 叢集也不見時才需要
platform/db/migrate.sh                       # 4. 只有在資料庫是新的時才需要
platform/tests/run_all.sh 2>&1 | tail -20    # 5. 證明契約還成立
```

第 5 步印近 1,100 行斷言，**只留結尾**：它要嘛 `ALL SUITES PASSED`，
要嘛在結尾列出 `FAILED SUITES`。

---

## 九、重點文件在哪：一個問題對一份檔案

**第一次接手的人（或能力較弱的 agent）最容易卡在「這件事該去哪裡查」。**
下面是最小的對照表，順序就是第一次 review 的建議順序。

| 你要問的 | 去這一份 | 它答得了什麼、答不了什麼 |
|---|---|---|
| **怎麼把它跑起來、憑證怎麼拿** | `docs/Runbook.md`（本檔） | 只給必備操作。**不給設計理由** |
| 現在哪裡是紅的 | `platform/statusdag/dag.py --json` 的輸出 | 這是平台**對自己的判定**，不是文件記載。跟任何文件衝突時以它為準 |
| 做完多少了 | `docs/Stage-Report.md`「三條線的完成度」 | 分母是節點，並附阻擋者的歸屬。**產生式，不要手改** |
| 某個決定為什麼是這樣 | `docs/decisions/index.md`（18 筆 ADR） | 帶量測的都附 `rerun:` 指令。**它答不了「現在的狀態」** |
| 還沒做的、以及什麼時候該做 | `docs/Backlog.md` §27 | 每一項附觸發條件。B1–B10 是**只有使用者能做**的 |
| 某一層怎麼運作 | 該層的 `platform/<層>/README.md` | 每份末尾都有一張能力表（何時跑／做什麼／保證什麼） |
| 這個 pilot 怎麼跑、資料從哪來 | `pilots/station2-twin/README.md` | 含啟動方式與為什麼不能自己 `compose up` |
| **AI agent 接手** | `docs/Session-Handover.md`（Claude）、`AGENTS.md`（其他家） | 開場指令、讀的順序、**會再遇到的 10 個坑** |
| 生產節點（Ubuntu） | `docs/Ubu-Prod-Bringup.md` | 用 `ssh drew@ubu.local`，**不要記 IP** |

### 給能力較弱的 agent 的三條路由規則

1. **不要用讀的推測狀態。** 現況一律由指令產生（上表第二、三列）。
   手寫的現況頁在這個 repo 已經有過兩份，其中一份對長官說反了。
2. **跟不了反引號。** 文件裡寫成 `` `platform/x/README.md` `` 的東西，
   agent 點不進去也搜不到；能點的連結才算可達。這條規則的來歷見
   `docs/Reachability.md`。
3. **改東西之前先看 `docs/Backlog.md` §27。** 規則是「只登記，不實作」，
   例外是**修好既有東西的缺陷**——那不算新增範圍。

---

## 十、「做完多少了」——不要用讀的，用產生的

```bash
python3 platform/statusdag/stage_report.py     # 重新產生三種格式
grep -A 8 "三條線的完成度" docs/Stage-Report.md
```

那張表的分母是**節點**（不是階段），並附上每一條線的阻擋者依**歸屬**分類。
**歸屬那一欄比百分比重要**：只有 `工程自理` 是這個 repo 自己關得掉的。
`外部單位` 在等別人、`研究議題` 是模型真的還沒贏過基準、`待您決定` 在等人拍板。

**把後兩類逼成綠色只有兩條路：等別人，或讓某個節點不再說一句真話。**

---

## 十一、這份手冊沒有寫的，以及它們在哪

| 要找什麼 | 去哪 |
|---|---|
| 為什麼這樣設計 | 各層的 `platform/*/README.md` |
| 某個決定的理由與量測 | `docs/decisions/index.md`（18 筆 ADR） |
| 還沒做的事與觸發條件 | `docs/Backlog.md` §27 |
| AI agent 接手 | `docs/Session-Handover.md`（Claude）、`AGENTS.md`（其他） |
| 只有使用者本人能做的事 | `docs/Backlog.md` 的 B1–B10 |

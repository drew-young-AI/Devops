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

## 三、憑證在哪（不要去別的地方找）

| 要什麼 | 在哪 | 怎麼拿 |
|---|---|---|
| Vault 解封金鑰／root token | `platform/vault/.init-output.json` | 這是唯一一份，**沒有備份就沒有 Vault** |
| Grafana 管理員 | Vault `secret/devops/grafana-admin` | `grep GF_SECURITY_ADMIN_PASSWORD platform/observability/.grafana.env` |
| 資料庫 | 容器環境變數 | `docker exec station2-twin-db-1 sh -c 'printf %s "$POSTGRES_PASSWORD"'` |

`.grafana.env` 是**可丟棄的傳遞檔**，不是第二個真實來源。密碼跟 Vault 不一致
時（例如瀏覽器存了舊的），重置並覆蓋：

```bash
platform/observability/scripts/setup_grafana_identity.sh
```

它從 Vault 取值、重設 Grafana 現行密碼、重寫 `.grafana.env`，並驗證預設的
`admin/admin` 已不被接受。**過程中不印出任何密碼。**

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

## 九、「做完多少了」——不要用讀的，用產生的

```bash
python3 platform/statusdag/stage_report.py     # 重新產生三種格式
grep -A 8 "三條線的完成度" docs/Stage-Report.md
```

那張表的分母是**節點**（不是階段），並附上每一條線的阻擋者依**歸屬**分類。
**歸屬那一欄比百分比重要**：只有 `工程自理` 是這個 repo 自己關得掉的。
`外部單位` 在等別人、`研究議題` 是模型真的還沒贏過基準、`待您決定` 在等人拍板。

**把後兩類逼成綠色只有兩條路：等別人，或讓某個節點不再說一句真話。**

---

## 九、這份手冊沒有寫的，以及它們在哪

| 要找什麼 | 去哪 |
|---|---|
| 為什麼這樣設計 | 各層的 `platform/*/README.md` |
| 某個決定的理由與量測 | `docs/decisions/index.md`（18 筆 ADR） |
| 還沒做的事與觸發條件 | `docs/Backlog.md` §27 |
| AI agent 接手 | `docs/Session-Handover.md`（Claude）、`AGENTS.md`（其他） |
| 只有使用者本人能做的事 | `docs/Backlog.md` 的 B1–B10 |

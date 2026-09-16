---
type: how-to
title: 落地之後怎麼持續觀察——人怎麼看，agent 怎麼下指令
description: "Two audiences, two interfaces, one source. What a person opens and how often; what an agent runs, what each command proves, and what a stale answer looks like so it is not mistaken for a healthy one."
tags:
  - runbook
  - observability
  - handover
  - monitoring
timestamp: 2026-09-16T11:00:00+08:00
---

# 落地之後怎麼持續觀察

`verify`：`bash platform/scheduler/status.sh && python3 platform/statusdag/dag.py --selfcheck`

落地不是終點，是**開始有東西可以退化**。這份文件回答兩個問題：
**人打開什麼**、**agent 跑什麼**。

兩邊看的是**同一份證據**（`evidence/` 底下的產生式檔案），只是介面不同。
沒有任何一邊有「自己的一份狀態」——那正是這個 repo 反覆踩過的坑。

---

## 一、人怎麼觀察

### 每天一次，30 秒：一個網址

**http://mac.local:13000/d/platform-stages/** —— 三線階段燈號。

看三個字就好，它們現在是**算出來的**，不是誰寫的（ADR-0021）：

| 判定 | 意思 | 你要做什麼 |
|---|---|---|
| `LANDED` | 沒有東西卡在我們手上，平台也夠綠 | 不用做事 |
| `ENG-DEBT` | **還有東西卡在工程手上** | 不用做事——這是 agent 的工作，但你會看到它多久沒動 |
| `CEILING-BOUND` | 工程已經做到頂，**剩下的要你決定或是研究議題** | **這一格才需要你** |

**只有 `CEILING-BOUND` 和「`ENG-DEBT` 連續多天沒有變化」需要你出手。**
其餘時間這張圖應該是無聊的，而無聊就是它在正常運作。

### 每週一次，5 分鐘：一頁靜態報告

**http://mac.local:18085/Stage-Report.html** —— 不需要登入、可以直接轉寄。

它會把「誰欠什麼」列成具名的 ask，每一筆都帶**選項**而不是只帶問題。
`決定` 開頭的那幾筆是你的；`工程自理` 那幾筆不是。

### 什麼時候應該懷疑這張圖在騙你

三個訊號，任何一個出現就不要相信畫面上的顏色：

1. **時間戳不動**。報告頁底部有產生時間。超過一小時沒動，你看的是歷史。
2. **全綠而且一直全綠**。這個平台從來沒有連續一週全綠過。真的全綠時，
   先跑下面 agent 那一節的 `--selfcheck`。
3. **數字變好但沒有人做事**。百分比自己往上跑，通常是分母變了不是分子變了。

### 你**不需要**打開的東西

Prometheus（`:19090`）是原始指標查詢，**刻意不放權限控制**，也刻意不給人看
（ADR-0003）。它不是儀表板，讀它得到的結論多半是錯的。

---

## 二、agent 怎麼下指令觀察

### 開場三條（順序有意義）

```bash
cd /Users/drew/ENV/Devops

# 1. 排程還在跑嗎 —— 如果排程死了，下面兩條讀到的都是歷史
bash platform/scheduler/status.sh

# 2. 重新產生看板，然後讀判定 —— 不要讀 docs/ 底下的舊檔
python3 platform/statusdag/dag.py --prometheus evidence/statusdag/dag.prom
python3 platform/statusdag/stage_report.py
python3 -c "import json;d=json.load(open('docs/Stage-Report.json'));\
[print(l['id'], l['completion']['verdict'], l['completion']['pct_strict'],
       l['completion']['blocking_by_owner']) for l in d['lines']]"

# 3. 探針自己有沒有壞 —— 綠燈也可能是探針瞎了
python3 platform/statusdag/dag.py --selfcheck
python3 platform/statusdag/stage_report.py --selfcheck
```

**第 1 條先跑是硬規則。** 排程停掉時，`evidence/` 底下每一個檔案都還在，
每一個都還可以被讀成「當前狀態」，而它們全部是過去式。
先問「這些數字是什麼時候產生的」，再問「這些數字說什麼」。

### 每一條指令**證明什麼**，以及它答不出什麼

| 指令 | 它證明 | 它**答不出** |
|---|---|---|
| `scheduler/status.sh` | 每個作業上次何時跑、是否逾期 | 作業跑了有沒有**效果**（`ok` 只代表 rc=0） |
| `dag.py` | 每個節點此刻的顏色與理由 | 有沒有**該有而沒有**的節點 |
| `stage_report.py` | 誰欠什麼、三態判定 | ask 寫的是不是還成立 |
| `--selfcheck` | ask 對不對得上現況、探針有沒有讀不到證據 | 探針的**邏輯**對不對 |
| `xref.py` | 名字有沒有指向已刪除的東西 | 名字指到的東西是不是**還是對的** |
| `capability_graph.py --check` | 有沒有沒人找得到的腳本 | 找得到的腳本是不是還能跑 |
| `run_all.sh` | 所有守衛此刻都通過 | 守衛**涵蓋**的範圍夠不夠（見 T40） |

### 封閉檢查（問「有沒有東西沒人在問」）

```bash
python3 platform/docs/xref.py            # 名字的生命週期
python3 platform/docs/capability_graph.py --check   # 孤兒能力
python3 platform/docs/doc_graph.py       # 連不到的文件
bash platform/tests/run_all.sh           # 全套件（約 400s，45 suites）
```

這四條回答的不是「東西壞了嗎」，是「**有沒有東西是沒有人在問的**」
（ADR-0019）。它們比看板更值得定期跑，因為看板只會顯示它知道要看的東西。

### 持續監控：怎麼掛，以及**不要**怎麼掛

排程本身已經在跑（`platform/scheduler/install.sh --status`）。
agent 要持續盯，用**條件式等待**而不是輪詢：

```bash
# 對的：等一個條件成立，成立就結束
until [ "$(bash platform/scheduler/status.sh | head -1)" = "scheduler: OK" ]; do sleep 60; done
```

```bash
# 對的：把「有東西變了」變成事件流（Monitor 工具）
#   command: tail -f evidence/notify/events.jsonl
#   或      bash -c 'while true; do python3 platform/statusdag/dag.py --json \
#             | python3 -c "..."; sleep 900; done'
```

**不要**每隔幾秒重跑 `dag.py`：它的輸入是排程每 15 分鐘寫一次的證據，
跑得比證據更新還快，只會拿到同一個答案。**觀察頻率不該高於產生頻率。**

### 一個 stale 的答案長什麼樣

這是最重要的一節，因為**過期的綠燈和真的綠燈在畫面上一模一樣**。

| 形狀 | 怎麼看出來 |
|---|---|
| 排程死了，看板還在 | `status.sh` 第一行不是 `OK`；每個作業的 `LAST RUN` 一起變老 |
| 單一作業死了 | 該作業 `FRESH` 欄位是 `late`，其他正常 |
| 作業在跑但沒效果 | `status.sh` 全 `ok`，但 `dag.py` 的節點 detail 裡的時間戳沒動 |
| 探針讀不到證據 | `--selfcheck` 會講；節點會是 `unknown` 不是 `ok`——**`unknown` 不是壞消息的靜音版，是「我沒看到」** |
| ask 已經不成立 | `stage_report.py --selfcheck` 報 `NOTE ... 條件已消失` |

**`unknown` 和 `ok` 的差別要看清楚。** 這個 repo 的探針被設計成「看不到就說
看不到」，而不是「看不到就當作沒事」。一個 `unknown` 節點需要的動作跟一個
`warn` 節點不同，但都不是「忽略」。

---

## 三、這段觀察期要證明什麼

落地判定是一個**瞬間**的讀數。持續觀察要回答的是另一個問題：
**這三條線在沒有人盯著的時候會不會自己退化。**

具體要看的三件事：

1. **判定會不會自己變差。** `LANDED` → `ENG-DEBT` 代表有新的工程債冒出來，
   那通常是某個作業開始失敗。這是**預期會發生**的，重點是多久被發現。
2. **`CEILING-BOUND` 那條線會不會被誤讀成 `LANDED`。** MLOps 讀 87.5%，
   而且不會自己變成 90%——如果哪天它變了，先問是不是分母動了。
3. **有沒有節點長期 `unknown`。** 那代表某條證據路徑斷了而沒有人發現，
   是所有形狀裡最像「沒事」的一種。

相關：[Runbook](Runbook.md)、[接手路由](Session-Handover.md)、
[ADR-0021 落地三態判定](decisions/0021-landing-is-a-three-state-verdict.md)、
[ADR-0019 守衛是一份過去失敗的清單](decisions/0019-guards-are-a-list-of-past-failures.md)

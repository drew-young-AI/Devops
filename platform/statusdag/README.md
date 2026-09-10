---
type: platform-adapter
title: 狀態 DAG 與階段看板
description: Traffic lights on the platform's own mechanisms, and the blast radius only a DAG can express.
tags:
  - statusdag
  - observability
  - board
timestamp: 2026-09-01T09:53:38+08:00
---

# platform/statusdag — what is broken, and what it takes down with it

## Two boards, different questions

```
valuestream/board.py   "where is my work?"           nodes are commits
statusdag/dag.py       "what is broken right now,    nodes are mechanisms
                        and what does it take down?"
```

## Start here

```bash
python3 platform/statusdag/dag.py            # node states
python3 platform/statusdag/stage_report.py   # the reviewer-facing HTML board
```

The board is served at `http://mac.local:18085/Stage-Report.html`.

## What only a DAG can express: blast radius

Vault sits upstream of identity, CI credentials, the Grafana admin login and the
audit trail. A flat status list shows four green rows and one red one, and says
nothing about the fact that the four are green only because nothing has asked
them anything yet. The edges are the point.

## The rule this directory keeps re-learning

A node added to `dag.py` and not to the report's `LINES` **disappears from the
report**, and a missing stage reads exactly like a healthy one. That coverage
guard lives in `platform/tests/test_stage_report.sh` and is the reason that
suite exists.

The same shape has now occurred four times across the platform: a threshold in
`install.sh` and again in its test; `LINES` in `stage_report.py` and again as a
regex in a dashboard; `RANK` in `dag.py` and again as a Grafana value mapping; a
drift expression in an alert and again in a panel. **One definition, many
readers** — never two copies.

## 2026-09-10：退役節點被刪掉，而不是被計進分母

`ci`／`trivy`／`registry`／`prodlike` 已移除。它們原本是 `superseded`——對每一個
單獨看都誠實，**加總起來不誠實**：`pct_strict` 除的是全部節點，四個永遠不會再變綠
的節點等於在 90% 的標準上壓了一個 85.7% 的天花板，**板面在報告一個做多少事都關不掉
的差距**。

一個被取代的節點也是孤兒：沒有東西指向它、證據只在 `evidence/_retired/` 底下、
探針存在的唯一目的是說一句「這件事搬走了」。**那句話屬於文件，不屬於分母。**
每一個的去向寫在 `dag.py` 的節點表註解裡（`ci`→`gha`、`prodlike`→`bluegreen`、
`trivy`／`registry`→ 沒有量測，寫進下面的登記簿）。

依賴邊跟著搬：`sast`／`secrets` 現在指向 `gha`（原本指向已刪的本機 `ci`），
`gate`→`bluegreen`，`bluegreen`→`nginx`／`prometheus`。並新增 `gha`→`prodk8s`——
原本的註解說「amd64 建置鏈沒有節點，因為那個 workflow 從未執行」，**那句話已經過期**：
它跑過三次，amd64 映像實際列得出來。

## 覆蓋率登記簿：為什麼每一輪都會找到新缺口

`dag.py` 的 `COVERAGE` ＋ `platform/tests/test_coverage_closure.sh`。

**根因不是執行不力，是方法的結構性上限**：這個 repo 的每一個守衛都是某次失敗之後
寫的，所以守衛集合是一份**過去失敗清單**，不是覆蓋集合。它的成長方式是「有人剛好
看到」。再寫一支測試只是在清單上多加一筆。

而且測試回答的問題不對。測試回答「這個東西壞了嗎」；**沒有任何測試回答「有沒有東西
是沒有人在問這個問題的」**——只有第二個問題會讓未知集合自己縮小。

封閉檢查列舉母體（每份 compose 的服務、每個排程 job），要求每一個都對應到節點，
或寫在 `UNMEASURED` 裡附上理由。實測往 `jobs.conf` 加一行就會紅。
完整理由與它抓不到的三件事：[ADR-0019](../../docs/decisions/0019-guards-are-a-list-of-past-failures.md)。

## 2026-09-10：八個「有腳本、沒節點」的表面

板面上多了 `certs`、`hostdisk`、`rotation`、`iac`、`srcfresh`、`prodhost`、`mirror`、`logcov`。八個都有既有腳本或既有指標、都沒有節點，
而且**都以同一種形狀失效**：一路正常，然後突然不正常，中間沒有斜率，也沒有人在看。

| 節點 | 它問的問題 | 沒有它的時候 |
|---|---|---|
| `certs` | 最快到期的憑證還剩幾天 | 憑證不會衰退，它到某個別人幾個月前訂下的時刻才一起停。整個平台**沒有任何地方**檢查過到期 |
| `hostdisk` | 主機磁碟還剩多少 | 曾經填滿並停掉整個平台，而它一度是唯一沒被量的數字 |
| `rotation` | 這次掃描**檢查了幾筆** | 掃描印 PASS 時不分「驗了 3 筆」還是「驗了 0 筆」。今天實測是 1/3，另外 2 筆豁免 |
| `iac` | 工作區裡的 IaC 現在驗不驗得過 | 這就是下面 gap #1 講了好幾個月的那件事 |
| `srcfresh` | 登記的來源**還在發布嗎** | `sources` 只數登記筆數，而登記筆數在來源停掉時不會變小。第一天就抓到一個 |
| `prodhost` | 生產**節點**本身健康嗎（kubelet 的壓力條件 ＋ 實際剩餘空間） | `prodk8s` 問的是「API server 回不回應、上面有沒有東西在跑」，這兩件事在一台磁碟滿了、kubelet 已經開始驅逐的機器上**都還是真的** |
| `mirror` | DuckDB 鏡像的列數還跟資料庫一樣嗎 | 鏡像是**複本**。落後的複本照樣回傳、照樣很快，而且不會說那是上週的——這是這裡唯一「失效形式是自信的錯答案」的元件 |
| `logcov` | 日誌**真的有進來**嗎 | `loki` 只看容器活著。活著而且什麼都沒收到，跟活著而且正常，在那個節點上長得一樣 |

`prodhost` 讀 kubectl 而不是 ssh + df，是刻意的：那些條件是 kubelet 自己的，
也就是**真的會導致驅逐的那一組**，而空間數字來自同一個 kubelet 的 stats 端點。
ssh 出來的數字沒有任何東西會據以行動。而且光看條件不夠——`DiskPressure` 要到
kubelet 的驅逐門檻（約 85–90% 滿）才會翻 True，那時 pod 已經在被殺了，所以剩餘
空間用**和 Mac 那台同一組門檻**另外判一次，取較早響的那個。兩台共用一份
`DISK_FAIL_PCT`／`DISK_WARN_PCT`，不是各寫一份。

**前四個節點加上去的那天全部是綠的，而那正是加它們的時機。** 也因為如此，每一條斷言
都配了會讓它變紅的控制項——包含一張**故意過期的憑證夾具**（`platform/tests/fixtures/`，
2026-09-05 到期，永遠不會再變有效）。守衛沒被看過失敗，和守衛不會失敗，從輸出上分不出來。

`srcfresh`（DataOps，同一天加的）是這句話的反例，而且是更重要的那一半：
`sources` 節點數 `data_source` 的列數，而**那個數字在一個 feed 停掉的時候不會變小**。
於是板面在「22 個登記來源」上綠著，而它命名的那件事已經停止發生。新節點第一天就是
黃的——`cdc-tb-caremag` 4.4 天沒有新內容，門檻 3 天。**DataOps 因此從 83.3% 掉到 71.4%。**
數字往下走是對的：它一直都該是那個數字，只是沒有人在量。

**分母變大會讓百分比上升，而那不是「做了更多事」。** DevOps 從 24 個節點變成 28 個，
strict 從 66.7% 變成 71.4%——多出來的是**覆蓋率**不是進度。要看進度看阻擋者的數量與
它們的擁有者，不要看那個百分比。

## Known gaps

1. ~~**No `iac` node.**~~ 2026-09-10 加上了，跑本機的 `tofu validate` ＋ `fmt -check`。
   刻意**不**去讀遠端工作流的判決——`gha` 已經在讀了，兩個節點報同一個量測就是這份
   README 自己警告的「一份定義、多個讀者」。這一個問的是不同的問題：**推出去之前**，
   工作區裡的 IaC 驗不驗得過。
2. ~~**No CI node.**~~ `gha` 節點 2026-08-31 就加了（GitHub Actions 紅了至少六天沒人知道
   之後）。這一條在這裡多留了十天，是這份文件自己的可達性缺陷。
3. `llmreview` is SUPERSEDED: its input comes from the retired Compose path and
   it has not been reconnected to the Kubernetes artefacts. **2026-09-10 改判擁有者**
   為「待您決定」——它要等 Kubernetes 產物，而那要等 prod 叢集能不能承載服務的決定。


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`dag.py`](dag.py) | 排程，每 15 分鐘 | 現場探測每個節點，產出值班者看的板子 | 一個節點一列，問的是「哪些容器活著」。**退役 Pilot 的證據會落到 `SUPERSEDED` 而不是被當成現況** |
| [`stage_report.py`](stage_report.py) | 排程，跟著 `dag` 走 | 把同一批探測重組成**階段**，一份模型三種輸出 | `html` 給人與長官、`json` 給程式、`md` 給 AI（4KB）。**新增節點沒加進 `LINES` 就直接拒絕產生報告**——消失的階段讀起來和健康的階段一模一樣 |

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

**登記簿立刻付了代價**：它把 9 個「沒有節點」逐條列出來之後，其中三條看一眼就知道
不該留著——`rollup`、`dastcov`、`catalog`。補上節點之後未量測降到 6 個。
這正是封閉檢查和多寫一支測試的差別：**它產生的是一張待辦清單，不是一次通過。**

### 第三個維度：讀的人和寫的人對不對得上

`dag.EVIDENCE_READS` ＋ 封閉檢查裡的 schema 契約。每支探針讀的都是**另一個程式**
寫的檔案；那個程式改一個鍵名的那一刻，讀的人就開始用完全的自信報告虛構的事實。

實際發生過：`probe_capability_catalog` 用四個**猜的**欄位名去找孤兒，四個都不存在
→ `.get()` 回 `None` → `not None` 為真 → 報告「102 支裡有 94 支沒有文件描述」，
而寫那個檔案的程式同時在說零孤兒。**欄位不存在 → falsy → 而 falsy 就是一個判決。**

現在改名會產生 `SCHEMA MISS: capabilities.json has no capabilities[].described`——
和「發現」不同的一句話。控制項直接拿那四個猜錯的名字去跑並斷言它們解析不到，
證明這個檢查當時就會抓到。理由見 [ADR-0019](../../docs/decisions/0019-guards-are-a-list-of-past-failures.md)。

**登記簿的內容也會寫錯。** `job:catalog` 的理由我第一次寫成「資料來源目錄」，
實際上是**能力目錄**（`capability_graph.py --catalog`）。列舉是機械的，理由是人寫的——
後者仍然會錯，只是現在錯在一個看得到的地方。
完整理由與它抓不到的三件事：[ADR-0019](../../docs/decisions/0019-guards-are-a-list-of-past-failures.md)。

## 2026-09-10：十三個「有腳本、沒節點」的表面

板面上多了 `certs`、`hostdisk`、`rotation`、`iac`、`srcfresh`、`prodhost`、`mirror`、`logcov`、`rollup`、`dastcov`、`capcat`、`fclead`、`ingestq`。十三個都有既有腳本、既有指標或既有資料表，都沒有節點，
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
| `rollup` | 健康檢查**跑了幾次**、其中多少時間是健康的 | 單次檢查只答得出「現在」。2,453 份快照裡覆蓋率 90%、健康 48%、降級 41%——這些數字每週產生，而沒有人讀 |
| `dastcov` | DAST **掃到幾條路由** | `dast` 只判最近一次的判決。實測**只掃得到 10 條裡的 4 條**，而「DAST PASS」在 40% 與 100% 覆蓋率上印的是同一個字 |
| `capcat` | 有沒有腳本是**沒有任何文件描述**的 | 兩份封閉檢查的另一份。`capability_graph.py` 每天跑，但答案只在套件裡，兩次跑之間新出現的孤兒是看不見的 |
| `fclead`（MLOps） | 最新預測**有沒有領先**最新實際值 | `forecast` 數列數，而列數不會變小。發布停掉一個月之後它還是說「4 筆已發布預測」，而那四筆早就變成對已知答案的「預測」|
| `ingestq`（DataOps） | 每個來源**最近一次**退回了多少列 | 上游改欄位 → 整批退回 → `lineage` 的恆等式照樣成立、`facts` 的列數不會掉、`srcfresh` 看到內容有變。三個綠燈蓋著一個已經不再貢獻資料的來源 |

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

## 2026-09-11：四個節點沒有任何文件提到

`geo`、`dcontract`、`k8s`、`gateleak` 在板面上亮著，而全倉庫的**非產生式**文件裡
一次都沒被提到。`docs/Stage-Report.md` 不算——它只列**不是綠的**節點，所以一個
節點今天綠了就從那份文件消失，用它當文件會讓「有沒有被記錄」隨天氣變動。

| 節點 | 它問的問題 | 為什麼值得一個節點 |
|---|---|---|
| `geo` | `geo_area` 有幾個行政區（縣市／鄉鎮／村里） | 地理權威是**分母**。它空了，所有「每十萬人」的率都算不出來，而算不出來和算出 0 在報表上長得一樣 |
| `dcontract` | 資料契約的判決產物還新不新（`data/contract_summary_*.json`，8 天） | 契約檢查停掉的時候，最後一份 PASS 會一直留在磁碟上。**過期的 PASS 和現在的 PASS 是同一個字** |
| `k8s` | k3d 叢集 `/readyz` 回不回應 | 目標執行環境（ADR-0010）。Compose 平台不依賴它，所以它掛掉不會有任何別的節點變紅——這正是它需要自己一盞燈的理由 |
| `gateleak` | 有沒有**繞過閘門**發布的預測 | `publish_forecast.py` 在發布時擋（`AND mr.beats_baselines`），那是對**一條程式路徑**的保證。`probe_lineage` 已經教過這個教訓：被刪掉的 CHECK 約束不留痕跡，被改掉的 WHERE 子句也不留 |

| `xref` | 這個倉庫裡的**名字還指得到東西嗎** | 見下一節。它是第三份封閉檢查，而且是唯一一份問「刪掉之後」的 |

`gateleak` 是 2026-09-11 這一輪新加的，而它自己就是這一節的例子：加了節點、寫了
探針、配了控制項，**沒有寫任何文件**。`platform/docs/xref.py` 才是發現它的東西。

## 2026-09-11：第三份封閉檢查——刪掉的名字還被誰講著

前兩份封閉檢查（`capability_graph.py` 的能力目錄、這份 README 上面的覆蓋率登記簿）
和倉庫裡另外三份（doc_graph、EVIDENCE_READS、SQL 契約）問的是**同一個形狀**的問題：
**「X 現在有沒有被涵蓋」**。沒有一份問：一個東西被**刪掉**之後，它的名字怎麼了。

所以 2026-09-10 那次刪四個節點，全部套件照樣綠，而：

- `NEW_SERVICE_GUIDE.md` 和 ADR-0018 繼續說 `prodlike` 是板面上的節點
- Alertmanager 的 `inhibit_rules` 還在比對一個三週前隨 production-like Compose
  一起刪掉的 alertname——**一條不可能觸發的路由規則**，躺在沒人重讀的檔案裡
- `platform/observability/README.md` 的規則表還列著那條告警

`platform/docs/xref.py` 用**一套機制**管四個命名空間（節點／ADR／Backlog 編號／
告警規則），而且 `RETIRED` 是從 **git 歷史推導**的：

```
RETIRED = （這個檔案曾經定義過的每個名字）－（現在定義的）
```

手寫一份「我們刪過什麼」的清單，只是多給忘記改文件的那個人一次忘記的機會。

四個方向，第四個最像健康：

| 方向 | 是什麼缺陷 |
|---|---|
| `DANGLING` | 已刪除的名字還被講著，而且沒有任何一行說它已刪除 → 讀的人被告知一件假的事 |
| `UNDEFINED` | 引用一個**從來沒有**定義過的編號 → 打錯字，或某人寫下了一個沒做的計畫 |
| `UNDOCUMENTED` | 定義了，但沒有任何非產生式文件提到 → 東西在，沒人找得到 |
| `COLLIDING` | **一個編號兩個主人**。既不懸空也不缺文件，四份檢查裡有三份是綠的 |

第四個是這一輪最貴的發現：`Plan.md` 的 **B10 是流行病學週↔日曆日**（卡疾管署），
`docs/Backlog.md` 的 **B10 是 Telegram token 輪替**（卡使用者本人）。`dag.py` 的
`probe_epiweek` 只寫了 `B10`——而這個 session 自己的接手筆記已經記成錯的那一份。
規則是：**共用編號可以，兩份清單都不講就不行**（單邊講也不行，因為看錯的那個人
手上拿的正是另一份）。

**產生式的頁面不算文件。** `docs/Stage-Report.md` 只列不是綠的節點，所以一個節點
今天綠了就從那裡消失——拿它當文件，會讓「有沒有被記錄」隨天氣變動。

## 2026-09-11：`epiweek` 原本量錯了對象

那個節點數的是 `time_period` 裡 `cal_date` 是 NULL 的列——4,933 個期間裡 1,048 個。
但那 1,048 個裡有 **1,027 個是「週」、21 個是「年」**，而兩者**都不是一個日期**：
週是一段區間，年不是某一天。所以這個節點**只能靠把誤導性的值寫進一個在別的列上
意思是「這一天」的欄位才會變綠**。它量的是模型的產物，不是一個能力。

真正的能力是**接得起來嗎**，而它現在成立了：`epi_year`／`epi_week` 已經從疾管署
自己發布的對照表填進「日」列，所以帶日期的事實可以彙總成 CDC 週，再和週事實在
`(epi_year, epi_week)` 上相接。3,885 天全數對到，558 個週期間接得起來。

**刻意不在「週」列寫日期**——那會讓 `cal_date` 一欄背兩種意思，正是
`platform/docs/xref.py` 叫做 `COLLIDING` 的那種缺陷。

**這個節點真正的沉默失效是對照表會用完**（快照到 2026-12-31）。到期之後新的日期
會安靜地對不到週，而每一張日 vs 週的比較圖都會悄悄少算。所以探針在到期**之前**
就先警告（剩 90 天轉黃），到期後轉紅。

**這個數字往好看的方向動了，而判定舊量法是錯的那個人就是受益者**——所以七個控制項
一個都不能省，包含「對照表已過期」「有日期對不到」「證據檔不存在」三條會讓它變紅
或變灰的分支，以及一組把 2007–2009 跨年週釘死的斷言，讓任何「簡化成算式」的改動
不可能安靜地通過。

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

---
type: explanation
title: 名字比它命名的東西活得久——刪除的爆炸半徑在散文裡是無界的
description: "Every closure check here asks whether a thing is covered; none asked what happens to its name when the thing is deleted. Identifier lifecycle across four namespaces, with the retired set derived from git history."
tags:
  - decision
  - testing
  - governance
  - reachability
timestamp: 2026-09-11T14:00:00+08:00
decision:
  id: 20
  status: accepted
  date: 2026-09-11
  measured: true
  rerun: platform/tests/test_xref_lifecycle.sh
  supersedes: []
---

# ADR-0020：名字比它命名的東西活得久

## 背景

ADR-0019 的結論是「守衛是一份過去失敗的清單」，解法是**封閉檢查**：不要問
「這個東西壞了嗎」，要問「有沒有東西是沒有人在問這個問題的」。那份 ADR 之後，
這個倉庫有五份封閉檢查：

| 檢查 | 問的問題 |
|---|---|
| `doc_graph.py` | 每份**文件**都連得到嗎 |
| `capability_graph.py` | 每支**腳本**都有文件描述嗎 |
| `COVERAGE`（dag.py） | 每個**服務**與**排程工作**都有節點在看嗎 |
| `EVIDENCE_READS` | 每個探針讀的**產物欄位**都存在嗎 |
| `test_sql_contract.sh` | 每個查詢用的**表／欄／值**都存在嗎 |

**五份都在問同一個形狀的問題：「X 現在有沒有被涵蓋」。**

## 問題

沒有一份問：一個東西被**刪掉**之後，它的名字怎麼了。

2026-09-10 從 `NODES` 移除四個節點（`ci`／`trivy`／`registry`／`prodlike`）。
`platform/statusdag/README.md` 手動改了。全部套件綠。而：

- `NEW_SERVICE_GUIDE.md` 繼續寫「`prodlike` 節點在板面上是 `superseded`」。
  那不是過期，是**假的**：它不在板面上，任何狀態都不是。
- ADR-0018 有同一句的複本。
- Alertmanager 的 `inhibit_rules` 還在 `source_matchers` 比對
  `ProductionLikeAllColorsDown` — 該告警已於三週前**移除**（commit d950a19，
  隨 production-like Compose 一起退場）。**一條不可能觸發的路由規則。**
- `platform/observability/README.md` 的規則表還列著它，還在下面宣稱它
  「fired critical」。

沒有任何東西會壞。抑制規則抑制不到東西，所以什麼都不會斷——**這正是它能活三週
的原因**。

**刪除的爆炸半徑在散文裡是無界的。** 刪的人看得到定義，看不到那 73 份可能提到
它的 markdown。一次發現一處手動修，就是製造出這個缺口的那個方法本身。

## 決策

`platform/docs/xref.py`：**識別字的生命週期檢查**，四個命名空間一套機制
（節點／ADR/Backlog 編號／告警規則）。

**推導，不宣告。**

```
RETIRED = （這個檔案曾經定義過的每個名字，來自 git 歷史）－（現在定義的）
```

手寫一份「我們刪過什麼」的清單，只是多給忘記改文件的那個人**一次忘記的機會**。

**四個方向，而且是四種不同的缺陷：**

| 方向 | 缺陷 | 首次執行找到 |
|---|---|---|
| `DANGLING` | 已刪除的名字還被講著，沒有任何一行說它已刪除 | 6 處（2 份文件 + 2 份 Alertmanager 設定 + README 規則表） |
| `UNDEFINED` | 引用一個從來沒定義過的編號 | 3 處 |
| `UNDOCUMENTED` | 定義了但沒有任何非產生式文件提到 | 4 個節點（`geo`／`dcontract`／`k8s`／`gateleak`）＋ 3 條告警 |
| `COLLIDING` | **一個編號兩個主人** | 9 個 B 編號 |

**已刪除的名字「可以」被提到**——歷史要寫得下來。但提到它的那份**文件必須自己
說一次它已經死了**，而且那句話必須**點名它**。

## 這一輪最貴的那個發現，是第四個方向

`COLLIDING` 既不懸空也不缺文件，另外三個方向全綠。**同名兩義是長得最像健康的
那種失效。**

- `Plan.md` 的 **B10 ＝ 流行病學週↔日曆日**（卡在疾管署）
- `docs/Backlog.md` 的 **B10 ＝ Telegram bot token 輪替**（卡在使用者本人）

而 `dag.py` 的 `probe_epiweek` 文件字串只寫了 `B10`。讀的人開哪一份就信哪一份，
**而這個 session 自己的接手筆記已經記成錯的那一份了**。

規則：共用編號可以（重新編號一份歷史計畫比那個歧義更糟），但**兩份清單都不講就
不行**。單邊講也不行——看錯的那個人手上拿的正是**另外**那一份。

## 控制項，其中兩個是我自己的 bug

檢查器在對之前錯了兩次，**兩次都錯在會回報「乾淨」的方向**。兩個都變成永久控制項：

1. **段落範圍的標記**。允許退役標記出現在同一個 markdown 段落內的任何地方，
   會讓這份檔案存在的理由本身消音：`NEW_SERVICE_GUIDE.md:225` 所在的那一節寫著
   「`Architecture.md` 已於 2026-09-09 刪除」——**一個關於別的名詞的標記**。
   一個沒有點名它所退役之物的標記，什麼都沒證明。
2. **把定義讀成表格列**。把 Backlog 編號的定義讀成「有一列開放中的 §27 表格列」，
   會把 T13／T22／T25 回報成「從來沒有定義過」，而它們在那個檔案裡出現了四次。
   **結案不是刪名字**：結案拿掉表格列，留下散文紀錄。

夾具是一個**真的**丟棄式 git repo（建好用完不到一秒），因為 `RETIRED` 是從 git
歷史推導的，而一個把推導 stub 掉的控制項，測的是那個 stub。

## 代價

- 全倉庫掃描 **3.1 秒**（跳過 venv／site-packages／evidence／.git）。
- 短識別字在散文裡**必須加反引號**。這不是新規定——所有現存文件本來就這樣寫，
  是量出來的不是假設的。
- 「產生式頁面不算文件」：`docs/Stage-Report.md` 只列不是綠的節點，用它當文件
  會讓「有沒有被記錄」隨天氣變動。

## 替代方案

- **手寫一份退役登記簿**：被否決。見上面「推導，不宣告」。
- **刪除時 grep 一次**：這正是產生這個缺口的方法。它依賴一個人記得做，而且只
  涵蓋他想得到的拼法。
- **禁止提到已刪除的名字**：會讓歷史寫不下來。ADR-0018 已經定下「刪一份文件要有
  ADR 說明理由」，那些理由必然要提到已經不存在的東西。

## 怎麼自己重跑

```bash
python3 platform/docs/xref.py          # 四個方向的報告，rc=1 代表有缺陷
python3 platform/docs/xref.py --json   # 機器可讀
bash platform/tests/test_xref_lifecycle.sh   # 24 條斷言，含兩個「我自己的 bug」控制項
```

板面上是 `xref` 節點（foundation 層），每天由排程工作 `xref` 寫
`evidence/docs/xref.json`——和 `capcat` 同一個理由：套件一次執行只答得出當下，
**兩次執行之間被改成指向不存在之物的文件是看不見的**。

相關：[[0019-guards-are-a-list-of-past-failures]]、
[[0018-delete-a-document-only-when-an-adr-carries-its-reason]]

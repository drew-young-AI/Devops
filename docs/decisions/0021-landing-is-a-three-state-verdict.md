---
type: explanation
title: 落地是一個三態判定，不是一個百分比——工程債與平台品質是兩個問題
description: "pct_strict answers how green the platform is; the owner breakdown answers whether anything is still stuck on us. Collapsing them into one number makes a line with zero engineering debt indistinguishable from one that nobody has worked on."
tags:
  - decision
  - governance
  - statusdag
  - completion
timestamp: 2026-09-16T10:00:00+08:00
decision:
  id: 21
  status: accepted
  date: 2026-09-16
  measured: true
  rerun: platform/tests/test_stage_report.sh
  supersedes: []
---

# ADR-0021：落地是一個三態判定，不是一個百分比

## 背景

`docs/Runbook.md` 定義落地為兩條同時成立：

| | 條件 |
|---|---|
| 1 | `pct_strict` ≥ 90% |
| 2 | 阻擋者裡 `工程自理` = 0 |

2026-09-16 實測三條線：

| 線 | `pct_strict` | `pct_ceiling_eng_only` | 工程自理 | 舊標準 |
|---|---|---|---|---|
| DevOps | 93.3%（28/30） | 96.7% | **1**（`alertmgr`） | ✗ |
| DataOps | 100.0%（9/9） | 100.0% | 0 | ✓ |
| MLOps | 87.5%（7/8） | **87.5%** | 0 | ✗ |

兩條線沒過，**而且是因為完全相反的理由**：

- DevOps 的百分比夠，但**還有東西卡在我們自己手上**。
- MLOps 沒有任何東西卡在我們手上，但**這個 repo 裡再多的工作也到不了 90%**
  ——`pct_ceiling_eng_only` 就等於 `pct_strict`，兩者都是 87.5%。

Runbook 早就寫下了後面那句話：

> **它低於 90% 的那一刻，代表這個 repo 裡再多的工作也到不了標準。**
> 那是關於標準的事實，不是關於努力的事實。

**這句話從來沒有被變成一個判定。** 它被寫在一段散文裡，每一輪重新爭論一次。

## 決定

落地是一個**三態判定**，逐線計算，兩個問題分開問、分開報：

| 判定 | 條件 | 意思 |
|---|---|---|
| `LANDED` | 工程自理 = 0 **且** `pct_strict` ≥ 90% | 沒有東西卡在我們手上，平台也夠綠 |
| `ENG-DEBT` | 工程自理 > 0 | **還有東西卡在我們手上**，不管百分比多高 |
| `CEILING-BOUND` | 工程自理 = 0 **且** `pct_strict` = `pct_ceiling_eng_only` < 90% | 工程已經做到頂；**剩下的不是工程問題** |

### `CEILING-BOUND` 不是 `LANDED` 的別名

這是這份 ADR 最容易被誤用的地方，所以講明白：

`CEILING-BOUND` **不主張這條線夠好**。它主張的是一件更窄、也更可驗證的事：
**所有還沒綠的節點，都已經由一筆具名的 ask 指派給 decision／research／external。**

MLOps 讀 **87.5%，而且這個數字不會因為這份 ADR 改變一分**。改的是「這一輪
要不要再投工程進去」的答案，不是把 87.5% 講成 90%。

### 為什麼這不是搬球門

三個結構性理由，每一個都可以被推翻：

1. **`工程自理 = 0` 這一條沒有被放寬，反而變成第一順位。** 舊標準裡它是第
   二條，可以被高百分比掩蓋——DevOps 今天就是這樣：93.3% 讀起來很好，而
   `alertmgr` 還在我們手上。新判定把它變成 `ENG-DEBT`，**比舊標準更嚴**。
2. **擁有者不能被安靜地軟化。** `stage_report.py` 的規則是「任何非綠節點，
   沒有對應的 ask 就預設為 `工程自理`」。要讓一個節點變成 decision／research，
   必須有一筆**寫下來的 ask**，帶著具體選項與 `ref`；而 `--selfcheck` 會把
   對不上現況的 ask 報出來。把工程債重貼成「決定」需要偽造一份文件，不是改一個欄位。
3. **`pct_ceiling_eng_only` 是推導的，不是宣告的。** 它是
   `(nodes_ok + eng_blockers) / nodes_total`，`assert_completion.py` 每次都驗它
   等於這個算式。沒有人可以手寫一個對自己有利的上限。

### 90% 沒有被取消

`pct_strict ≥ 90%` 仍然是**平台品質**的門檻，仍然每輪報出來。
變的是：它不再是唯一的字，而且**它答不出「還有沒有事情卡在我們手上」**——
那一直是另一個問題，只是以前被塞進同一個數字裡。

## 後果

2026-09-16 的三條線在新判定下：

| 線 | 判定 | 還缺什麼 |
|---|---|---|
| DevOps | `ENG-DEBT` | `alertmgr`：3 條 `WidespreadGeoDrift` 在燒（T49） |
| DataOps | `LANDED` | — |
| MLOps | `CEILING-BOUND` | `mgate`：`ili t+1` 輸持平基準 6.7%（T51） |

**DevOps 在舊標準下也沒落地**，這份 ADR 只是讓它顯示出來而不是被 93.3%
蓋過去。

## 怎麼重跑

```bash
python3 platform/statusdag/stage_report.py
python3 -c "import json;d=json.load(open('docs/Stage-Report.json'));\
[print(l['id'], l['completion']['verdict'], l['completion']['pct_strict']) for l in d['lines']]"
bash platform/tests/test_stage_report.sh
```

控制項在 `platform/tests/test_stage_report.sh`，三個判定各一個正向與一個
反向夾具，其中最重要的一條是：**一條 87.5%、上限 93.3%、工程自理 = 1 的線
必須讀成 `ENG-DEBT`**——如果 `CEILING-BOUND` 能吃下有工程債的線，這份 ADR
就真的只是搬球門。

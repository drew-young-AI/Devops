---
type: explanation
title: 睡眠期間的排程空窗算違反 SLA，不豁免
description: "The laptop is a development host standing in for a server. Exempting its sleep windows would make the probe measure the machine we have instead of the machine we are building for -- and would exempt real scheduler death along with it."
tags:
  - decision
  - scheduler
  - observability
  - sla
timestamp: 2026-09-08T00:00:00+08:00
decision:
  id: 15
  status: accepted
  date: 2026-09-08
  measured: true
  rerun: platform/scheduler/status.sh
  supersedes: []
---

# 0015 睡眠期間的排程空窗算違反 SLA，不豁免

## 決定

**維持現狀：`launchd` 在睡眠期間不觸發造成的空窗，照樣判 stale、照樣把
`scheduler` 節點打成 fail、照樣讓 `verdict` 變 `FAILED`。不加睡眠豁免。**

## 這是一個政策決定，不是技術決定

技術上兩種做法都不難。決定的依據是**這台機器代表什麼**：

MacBook Pro M5 是**開發階段的宿主，它站在未來那台 server 的位置上**。
量測的對象不是「這台筆電的排程有沒有跑」，而是
**「這個平台的排程契約有沒有被滿足」**。伺服器不會睡，所以在伺服器上
這個空窗不會發生；一旦它發生，就是真的違約。

把睡眠豁免掉，等於讓探針去適應**現在這台機器的特性**，
而那個特性在移植之後就不存在了——留下的會是一條**為了不存在的環境而寬鬆的守衛**。

## 豁免還會順帶豁免掉真正的故障

這是更硬的理由。睡眠窗與「機器醒著但排程真的死了」，在
`evidence/scheduler/<job>_last.json` 裡**逐欄相同**：都是「該跑而沒有紀錄」。
要分辨得另外採集主機狀態（已登記為 §27 的 T16）。

在 T16 之前，任何「睡眠豁免」的實作都只能靠時間窗猜，而猜錯的方向是
**把真的死掉的排程一起放行**。一條會在真故障時保持綠色的守衛，
比一條偶爾假紅的守衛糟得多。

## 量測（2026-09-08）

| 項目 | 值 |
|---|---|
| 最後喚醒（`sysctl -n kern.waketime`） | 10:31:51 |
| 空窗 | 09:53 → 10:31，38 分鐘 |
| 受影響任務 | `board`／`dag`／`stagereport`（皆 900s 間隔） |
| 未受影響 | `health`（同為 900s，10:32:59 喚醒後立刻補跑） |
| `.launchd.log` | 三支從頭到尾 `ok (rc=0)`，零次失敗 |
| 10:39 的 `verdict` | `FAILED` |
| 10:42 的 `verdict`（`docs/Stage-Report.json`） | `DEGRADED`，scheduler detail 已無 `not running` |

**紅燈的持續時間約等於喚醒後第一輪補跑的延遲**，實測 11 分鐘。

## 代價，明講

1. 每次喚醒後約 10 分鐘內開場指令會看到 `FAILED`。
   接手的人會誤診——所以判別法寫進 `docs/Session-Handover.md` 坑 #8，
   而不是靠人記得。
2. 若 pilot 進入需要 SLA 報表的階段，這些睡眠窗會計入不可用時間。
   **這是正確的**：那份報表要回答的是「這個平台可靠嗎」，
   不是「扣掉筆電睡覺以外這個平台可靠嗎」。

## 什麼時候重新檢討

平台移到常開主機（ubu 或真正的 server）之後。屆時這個空窗不該再出現；
**如果它還出現，那就是一個真的故障**，而這條守衛已經準備好抓它了。

相關：§27 的 T16（缺口記錄補主機狀態欄位）、AIS 知識記錄
`sleeping-host-breaks-continuity`（同一個機制在告警 `for:` 上的另一半）。

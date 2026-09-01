---
type: explanation
title: 通知分成狀態與事件兩條路，不共用同一個機制
description: "Alertmanager owns conditions that persist and repeat; one-shot events go through a deliberately dumber path, because an event sent as an alert either never resolves or resolves twice."
tags:
  - decision
  - alerting
  - notification
timestamp: 2026-08-27T00:00:00+08:00
decision:
  id: 4
  status: accepted
  date: 2026-08-27
  measured: false
---

# 0004 通知分成狀態與事件兩條路，不共用同一個機制

## 決定

| | 定義 | 走哪裡 | 行為 |
|---|---|---|---|
| **狀態** | 為真且持續為真（服務掛了、schema 版本未知） | Alertmanager `email_configs` + Telegram | 分組、**每 4h 重送直到解除**、可靜音、`send_resolved` |
| **事件** | 發生一次且已結束（換版成功、閘門擋下發布） | `platform/notify/emit_event.sh` | **送一次，永不重送** |

## 為什麼不能共用

把事件塞進 Alertmanager 只有兩種結果，都是壞的：

- 它**永遠不 resolve** → 每 4 小時重寄一次一件已經結束的事
- 它**立刻 resolve** → 同一件事變成兩封內容相反的信

這不是投遞問題，是用錯工具。所以第二條路刻意做得比較笨：送一次、記一次、不重試。

## 不要重複送

`backup`／`restore`／`rotation` 已經是排程工作，失敗時 `notify.sh` 的狀態轉換通知就會送。
**在那些腳本裡再加 `emit_event` 會寄兩封。**

真正沒被覆蓋而需要 `emit_event` 的只有兩個：

- **`promote`**——刻意永不排程（要真人打 PROMOTE），排程通知碰不到它
- **`model-gate blocked`**——retrain 成功、閘門拒絕發布，**job 是綠的所以沒有人被告知**

## 通知失敗不得改變呼叫者的結果

`emit_event.sh` **一律 exit 0**。備份成功了就是成功了，不能因為通知信寄不出去而被記成失敗。
投遞結果寫進 `evidence/notify/events.jsonl`，在那裡可以被看到，而不改變任何人的判斷。

## 一個會在設定 mail 那天才爆的 bug（已修）

`email_configs` 曾被插進 `telegram_configs` 的**中間**，把 telegram 的 `api_url`／`parse_mode`／
`message` 變成 email 欄位。YAML 合法、語意全錯。之前每一道檢查都只看文字替換，看不出來。

修法不是加一個測試，是讓**產生器自己用 Alertmanager 的解析器驗**（`amtool check-config`），
在設定產生的當下就擋——包含日後真的設定 mail 那一次。負向驗證過（塞無效欄位 → 拒絕並指出行號欄位）。

## 未完成

寄件信箱 `zhe0@hotmail.com.tw` 尚未接上。Alertmanager 只會基本驗證不會 OAuth2，
微軟是否允許該帳號用 app password **只有真的登入一次才知道**——
`platform/notify/setup_mail.sh` 寄成功才寫 Vault。

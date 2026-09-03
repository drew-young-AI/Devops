---
type: platform-adapter
title: 通知：事件與狀態的分流
description: Why one-shot events and persistent states use different mechanisms, and what happened when delivery was not wired.
tags:
  - notification
  - alerting
timestamp: 2026-09-01T09:53:38+08:00
---

# platform/notify — events, which are not alerts

## The distinction this directory enforces

| | Owner | Behaviour |
|---|---|---|
| **STATE** — a condition that is true and stays true (a service is down, a schema version is unknown) | Alertmanager | grouped, **repeated every 4h** while it holds, silenceable, sends a resolved notice |
| **EVENT** — something that happened once and is already over (a promote succeeded, a restore drill failed, the gate refused a release) | `emit_event.sh` | sent once; there is nothing to repeat and nothing to resolve |

Routing an event through Alertmanager produces a "problem" that never resolves.
Routing a state through the event path produces one notification for an outage
that is still happening an hour later. See ADR-0004.

## Start here

```bash
platform/notify/emit_event.sh "<title>" "<body>"     # one-shot event
platform/notify/setup_mail.sh <address>             # configure the mail channel
```

## Two channels, not a fallback

Telegram arrives in seconds and is where an outage should be noticed. Mail is
where it can be found again a week later and is what a reviewer actually reads.
Neither is a fallback for the other: a "fallback" that only sends when the first
fails is a channel nobody ever confirms is working.

`send_resolved` is on for both. Silence after a failure is indistinguishable
from the failure continuing.

## Why delivery is wired at all

It deliberately was not, once. On 2026-08-19 Vault came back sealed after a
Docker VM restart, `SchemaVersionUnknown` fired at 18:45 and **kept firing for
3h55m**. Every layer worked — the metric, the rule, the grouping, the API. The
chain ended in a null receiver and no polling agent was actually running.

An alert that fires into a null receiver is indistinguishable from an alert that
never fired.

## Known gap

Mail is not activated: `platform/notify/setup_mail.sh <address>` still needs an
app password. Until then Telegram is the only live channel, and the "two
channels, neither a fallback" design is a design rather than a fact.


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`setup_mail.sh`](setup_mail.sh) | 一次性／換憑證時 | 設定外寄郵件，**並在宣稱可用之前先證明它可用** | 這個平台為此付過一次代價：2026-08-19 告警正確觸發並持續 3h55m，而**收件端根本沒收到**。設定檔不會證明自己能送達，這支會 |


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到（能力必須是**該列的主詞**）。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`emit_event.sh`](emit_event.sh) | 一次性的平台**事件** | 送出單次事件，**刻意不是 Alertmanager** | **狀態 vs 事件的分野**：狀態是「為真且持續為真」（服務掛了、schema 版本不明），那是 Alertmanager 的；事件是「發生過一次」，重送就是重複 |

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

## 現在這兩條通道實際上是什麼狀態

**兩條都不算通的**，而這句話在 2026-09-10 之前沒有任何地方寫得出來。

| 通道 | 狀態 | 缺什麼 | 誰能補 |
|---|---|---|---|
| Telegram | **已修好**（2026-09-10） | — | — |
| Mail | **從未接上** | Vault 裡沒有 `secret/devops/smtp` 這一筆，`setup_mail.sh` 讀不到憑證 | 只有本人：需要一組真的 SMTP 帳號與 app password |

### Telegram 那三天：設定正確，而且送不出去

2026-09-07 到 09-10，Telegram **388 次送出裡有 287 次失敗**（74%），沒有任何人
知道。設定是對的、`amtool` 接受、測試訊息會通——失敗的只有**真實的大型告警群**：

```
telegram: Bad Request: can't parse entities:
Can't find end tag corresponding to start tag "code" (400)
```

Alertmanager 在**算繪之後**才把訊息截到 4096 runes。群夠大時就截在 HTML 標籤中間，
Telegram 拒收整封，重試 17 次後丟棄。訊息越重要（一次爆越多筆）越送不出去。

兩個修法，兩者都需要：

1. `parse_mode: ""`（純文字）——沒有標記就沒有標記可以被截壞。最壞情況從
   「永遠送不到」降級成「送到了，被截斷」。
2. 訊息只列前 5 筆並在開頭寫出總數——截斷變成例外而不是常態，而且被截的那封
   仍然告訴你少看了多少。

**為什麼沒人發現**：Prometheus 當時**沒有抓 Alertmanager**。唯一的證據是
`alertmanager_notifications_failed_total`，一個活在沒人抓的行程裡的累計計數器。
告警系統是這個平台唯一「壞掉時不會告訴你它壞了」的元件。現在它被抓了
（`prometheus.yml` 的 `job_name: alertmanager`）。

### 自己確認通道還活著

```bash
# 1. 近 6 小時有沒有送失敗（0 筆 = 好；沒有 series = 沒在抓，不是沒失敗）
curl -s --get 'http://127.0.0.1:19090/api/v1/query' \
  --data-urlencode 'query=sum by (integration) (increase(alertmanager_notifications_failed_total[6h]))'

# 2. 重新產生設定並實際送一則測試訊息（不通就 exit 1）
platform/observability/scripts/setup_notifications.sh

# 3. 看板怎麼說
python3 -c "import sys;sys.path.insert(0,'platform/statusdag');import dag;print(dag.probe_alertmanager())"
```

> **憑證會出現在容器 log 裡。** telebot 把整個 URL（含 bot token）寫進錯誤訊息，
> 所以 `docker logs` 拿得到 token。這是上游行為，不是設定錯誤；意思是**能下
> `docker logs` 的人就等於拿得到 Telegram bot token**。要換 token 的話：改
> `~/.env` 的 `TELEGRAM_BOT_TOKEN`，重跑上面第 2 步。

---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到（能力必須是**該列的主詞**）。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`setup_mail.sh`](setup_mail.sh) | 一次性／換憑證時 | 設定外寄郵件，**並在宣稱可用之前先證明它可用** | 這個平台為此付過一次代價：2026-08-19 告警正確觸發並持續 3h55m，而**收件端根本沒收到**。設定檔不會證明自己能送達，這支會 |
| [`emit_event.sh`](emit_event.sh) | 一次性的平台**事件** | 送出單次事件，**刻意不是 Alertmanager** | **狀態 vs 事件的分野**：狀態是「為真且持續為真」（服務掛了、schema 版本不明），那是 Alertmanager 的；事件是「發生過一次」，重送就是重複 |
| [`send_mail.sh`](send_mail.sh) | 由 `setup_mail.sh` 與告警路徑呼叫 | 用 `mail.conf` 的設定把一封信交給 smarthost | 沒有 `mail.conf` 就明確失敗，不會安靜地送到空的收件人 |

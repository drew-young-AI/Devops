---
type: platform-adapter
title: 資料庫遷移
description: A migration runner whose value is the three dangerous cases it refuses.
tags:
  - database
  - migrations
timestamp: 2026-09-01T09:53:38+08:00
---

# platform/db — migrations that refuse the dangerous cases

## Start here

```bash
platform/db/migrate.sh            # apply pending migrations, in order, once
platform/db/pilot_db.sh psql -c "select 1"   # talk to the pilot DB without typing a container name
```

## What it actually guarantees

A migration runner is easy. These three refusals are the reason this one exists.

1. **Re-applying a changed migration is a hard stop.**
   Someone edits `002_foo.sql` after it has already run. On a fresh database the
   new text applies; on the existing one it never re-runs. The two databases now
   differ permanently, with no error anywhere. Every applied migration is
   checksummed and a mismatch stops the run.

2. **Destructive changes are refused during blue/green.**
   Blue and green share one database. `ALTER TABLE ... DROP COLUMN` applied
   while the other colour is still serving takes it down.

3. **Order and exactly-once are enforced**, not assumed.

## How it connects

`psql` runs in a pinned container rather than from the host, so the client
version is the same everywhere and no host install is required. The pilot's
schema version is exposed at the app's `/health/ready`, which returns 503 with
`schema_mismatch` when the running code expects a version the database does not
have — that is what stops a blue/green colour from taking traffic against the
wrong schema.

## Known gap

The migration path has only ever been exercised against the Mac's Compose
database. The Kubernetes copy shares the same database today, so this is not yet
a second code path — but it becomes one the moment the Ubuntu production cluster
gets its own database.


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到（能力必須是**該列的主詞**）。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`pilot_db.sh`](pilot_db.sh) | 任何需要對 pilot 資料庫下指令的時候（探針、ingest、備份、測試） | 依 **compose 服務**解析出資料庫容器，並提供 `container` / `name` / `exec` / `psql` 四個動作 | 容器名是 `<專案>-<服務>-<n>`，由目錄名推導出來的**衍生字串**。2026-09-20 改名時，22 處寫死 `station2-twin-db-1` 的呼叫全部壞掉，錯誤訊息是「No such container」——講的是症狀不是原因。第一版的處置是在 compose 釘死專案名把舊容器名保住，那是**用凍結一個名字去保護不該依賴它的呼叫端**，已撤回。宣告的東西是 compose 檔與服務名 `db`，這支腳本問的是那個。資料庫沒在跑時回 **rc 3**，與 psql 查詢失敗（rc 1）分開——「資料庫掛了」和「查詢寫錯了」要做的事不同 |
| [`migrate.sh`](migrate.sh) | 每次結構變更 | 依序、只跑一次地套用遷移，**並拒絕危險的那些** | 寫一個遷移器很容易；真正造成停機的是它**拒絕**做的三件事，第一件是**重跑一個被改過的遷移**——checksum 對不上就停 |

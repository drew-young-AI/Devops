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
| [`migrate.sh`](migrate.sh) | 每次結構變更 | 依序、只跑一次地套用遷移，**並拒絕危險的那些** | 寫一個遷移器很容易；真正造成停機的是它**拒絕**做的三件事，第一件是**重跑一個被改過的遷移**——checksum 對不上就停 |

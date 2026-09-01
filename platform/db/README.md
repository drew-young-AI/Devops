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

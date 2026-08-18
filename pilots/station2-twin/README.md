---
type: platform-adapter
title: station2-twin（Pilot 2：有狀態服務）
description: "The digital twin query/API layer: the platform's first stateful pilot, and the migration, readiness and backup mechanisms it forced into existence."
tags:
  - pilot
  - stateful
  - database
  - migration
timestamp: 2026-08-18T10:20:00+08:00
---

# station2-twin

The digital twin query/API layer. A small HTTP service over PostgreSQL that
ingests asset observations and serves current state and history.

```bash
docker compose -f pilots/station2-twin/compose.yaml up -d
PGPASSWORD=twin-bootstrap platform/db/migrate.sh station2-twin
curl -s localhost:18090/health/ready
```

| endpoint | |
|---|---|
| `GET /health/live` | process is up. Failing means *restart me* |
| `GET /health/ready` | this instance can correctly serve. Failing means *route around me* |
| `GET /version` `GET /metrics` | contract endpoints |
| `POST /twin/<asset>/observation` | ingest `{"metric": str, "value": number}` |
| `GET /twin/<asset>` | latest observation |
| `GET /twin/<asset>/history?limit=N` | most recent N |

## Why this pilot exists

station1-hello is stateless. It holds nothing, so schema migration, dynamic
credentials, stateful backup and restore were all *untestable* — the
mechanisms could be described but never exercised. This service has a
database, and therefore has the problems a database brings.

It was chosen over the Spark streaming worker deliberately. Spark breaks the
platform's **deployment** model (blue/green means two consumers on one
stream), which is a separate and larger change. This breaks only the
**state** assumptions, one thing at a time.

## Readiness is not liveness

Conflating them is the classic stateful outage: a DB blip fails the liveness
probe, the orchestrator restarts every replica at once, and a recoverable
dependency failure becomes a full one with cold caches.

So the Docker healthcheck hits `/health/live`, which never touches the
database. Readiness is for *routing*, and it fails with a reason:

| | meaning |
|---|---|
| `ready` | schema matches, database answers |
| `db_unreachable` | database down. Restarting this container cannot fix it |
| `schema_missing` | migrations never ran against this database |
| `schema_mismatch` | **this code was written for a different schema version** |

`schema_mismatch` is the one people leave out. During blue/green the two
colours run different code against **one** database. If green expects v3 and
the database is at v2, green starts, passes a naive `SELECT 1` check, and
then fails on real queries — *after* taking traffic. Refusing readiness turns
that into a deploy that never receives traffic: a non-event, not an incident.

### Verified

| Injected condition | `live` | `ready` | container |
|---|---|---|---|
| normal | 200 | 200 `ready` schema 2 | healthy |
| `docker compose stop db` | **200** | **503** `db_unreachable` | **healthy, not restarting** |
| database restored | 200 | 200 `ready` | healthy, recovered on its own |
| code expects schema 99, DB at 2 | 200 | **503** `schema_mismatch` | starts, refuses traffic |
| database with no migrations | 200 | **503** `schema_missing` | — |
| `'  OR 1=1--` in the asset path | — | 404, treated as a literal string | — |

## The migration gate

`platform/db/migrate.sh <pilot>` — ordered, checksummed, one transaction per
file. It refuses three things.

**A changed migration that already ran.** Edit `002_foo.sql` after it has
applied somewhere and the two databases diverge permanently, with no error
anywhere: the existing one never re-runs it, a fresh one gets the new text.
Checksums are recorded; a mismatch is a hard stop.

**A destructive change that is not marked as a contract phase.** Blue and
green share the database, so `DROP COLUMN` while the old colour still serves
breaks the rollback target — the deploy becomes irreversible exactly when
reversing it is what you need. Expand (add nullable, add table, add index) is
always allowed; contract (drop, rename, retype, `SET NOT NULL`) requires an
explicit `-- CONTRACT-PHASE:` line stating why no live colour depends on the
old shape.

**Partial application.** Each file runs in one transaction with its own
ledger insert, so a file cannot end up applied-but-unrecorded (which would
re-run it next deploy) or half-applied.

### Verified

| Injected condition | Result |
|---|---|
| virgin database | 2 pending → applied → schema v2 |
| appended a line to an applied migration | **refused**, prints both checksums |
| `ALTER TABLE ... DROP COLUMN`, unmarked | **refused**, prints the offending line |
| same statement with `-- CONTRACT-PHASE:` | allowed |
| file whose 2nd statement fails | **rolled back**: column absent, version unrecorded |

## What this pilot found in the platform

**Its own volume was backed up by nothing.** `station2-twin-db` was covered by
no list, and `backup.sh` still reported success — a hand-maintained list
cannot report what is missing from it. Fixed by adding a coverage check: every
named volume on the host must be in `VOLUMES`, `PG_SERVICES`, or
`EXCLUDED_VOLUMES` with a reason, or the backup exits non-zero. Running it
immediately surfaced **`observability_alloy-data`** as well — Alloy's log read
positions, which nobody had considered. Losing them does not error; it makes
Alloy either re-read from the start (duplicate lines) or resume at the tail (a
silent hole). After a restore, a gap in logs looks exactly like a quiet period.

**Tarring a live PostgreSQL volume is not a backup.** The files mutate while
`tar` walks them, so the archive mixes pages from different instants — torn in
a way that produces no error at backup time and may only surface months later.
`backup.sh` now uses `pg_dump -Fc` when the container is running and `tar`
only when it is stopped (where the data directory is quiescent and tar *is*
correct).

Restore-drilled, not assumed: the dump was restored into a scratch container
and asserted on — 2 migration rows, schema v2, 2 observations, the `quality`
column from migration 002, the index, and the actual stored value `5.02`.

## Known gaps

- **Still using a static password.** The Vault dynamic-credentials seam
  (`database/creds/station2-twin`) is reserved but not wired; `PGPASSWORD` is
  a bootstrap credential. This pilot exists partly to make that work
  concrete — the pool already sets `max_lifetime` so credentials with a TTL
  recycle rather than being held forever.
- **Not in the blue/green deploy adapter.** Runs from its own compose file;
  it has not been onboarded to `platform/compose/deploy.sh`, so the
  schema-mismatch protection has not yet been exercised through a real
  colour switch.
- **No DAST run yet.** The write endpoint with a JSON body is the first thing
  on this platform worth scanning with a form-aware profile.
- **Not exposed through ingress.** Ceiling not yet set in
  `platform/ingress/targets.conf`; it holds data, so it should not inherit
  station1's `funnel` ceiling by default.

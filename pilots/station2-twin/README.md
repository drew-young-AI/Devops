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

## Where this pilot actually runs (measured 2026-09-01)

It exists in **two copies**. Each line below was read from the running system.

| | Compose (`:18090`) | Kubernetes (`station2/station2-twin-blue`) |
|---|---|---|
| `/health/ready` | `ready`, schema 15 | `ready`, schema 15 |
| Credentials | **`mode: vault`** — dynamic, `ttl_seconds: 1200`, username `v-approle-station2-…` | **`mode: static`** — username `twin`, no `VAULT_*` in the environment |
| Scraped by Prometheus | yes — job `station2-twin`, `environment=develop` | **yes, since 2026-09-01** — job `station2-twin-k8s`, `environment=k8s` |
| Architecture | `linux/arm64` | `linux/arm64` — cannot run on the amd64 prod cluster |

### The observability gap that was closed today, and why it existed

Until 2026-09-01 nothing scraped the Kubernetes copy — and it was not a missing
scrape entry. The copy sat on a ClusterIP while k3d published nothing but the
API port, so **Prometheus could not reach it even in principle**. Two active
targets; the migrated copy was neither of them.

`pilots/README.md` records the same defect from the station1-hello retirement,
with the roles reversed: monitoring left pointing at the copy that no longer
mattered, "儀表板對著錯的服務顯示「一切正常」，比沒有儀表板更糟".

What was added:

- `metrics-service.yaml` — a NodePort (30890) carrying the **same `color`
  selector** as the traffic Service, so metrics describe the copy that is
  actually serving. k3d maps it to host `18091`.
- `promote.sh` now moves that Service in the same step as the traffic Service,
  and reads the selector back — a lagging metrics Service would point Prometheus
  at the idle colour precisely when someone is watching a promote.
- `platform/tests/test_migration_observed.sh` — asserts the join between what is
  deployed and what is watched. Both of its assertions were verified by breaking
  them by hand and restoring.

**Still not visible:** the idle colour. A green deployment that is broken before
promotion cannot be seen from outside the cluster. The real fix is Prometheus
inside the cluster with `kubernetes_sd_configs`, which is what the amd64
production cluster should get.

## Known gaps

1. **Vault is wired in Compose only.** The dynamic-credential path
   (`database/creds/station2-twin`, AppRole, TTL 1200s) is live and verifiable
   on the Compose copy. The Kubernetes Deployment has no `VAULT_*` environment
   at all and uses the bootstrap password. Any claim that credentials were
   "fully migrated" is true of one copy and false of the other.
2. **The idle blue/green colour is unscraped.** The serving colour is watched;
   the standby one is not, so a green deployment that is broken before
   promotion is invisible until it takes traffic.
3. **arm64 only.** The image cannot run on the amd64 production cluster.
   See [ADR-0008](../../docs/decisions/0008-two-machines-two-architectures.md).
4. **No DAST run yet.** The write endpoint with a JSON body is the first thing
   on this platform worth scanning with a form-aware profile.
5. **Not exposed through ingress.** Ceiling not yet set in
   `platform/ingress/targets.conf`; it holds data, so it must not inherit
   station1's `funnel` ceiling by default.

Blue/green **is** done and exercised on Kubernetes (2026-08-25), and the
schema-mismatch protection has been verified: readiness returns 503
`schema_mismatch` when the running code expects a version the database
does not have.


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`app/app.py`](app/app.py) | 服務常駐 | 數位分身的查詢／API 層 | `/health/ready` 與 `/health/live` 分開：**readiness 不是 liveness**，不符即拒收流量 |
| [`app/surveillance.py`](app/surveillance.py) | 由 app 呼叫 | 分身的模型與**背離偵測** | 分身的價值不在複製現況，在於指出現況與模型預期**不一致**的地方 |
| [`ingest/run.sh`](ingest/run.sh) | 排程 | 載入管線的入口，容器化執行 | 有 `--network host`（要抓政府 API），與 `mlops/run.sh` 相反 |
| [`ingest/load_geography.py`](ingest/load_geography.py) | 資料來源更新時 | 載入官方行政區地理與**宣告過的名稱別名** | 別名是**宣告**的不是猜的——行政區改名會讓歷史資料對不上，猜一個對應就是造假 |
| [`mlops/run.sh`](mlops/run.sh) | 由 `retrain.sh` 呼叫 | 在釘住的執行環境裡跑 MLOps 腳本 | **沒有 `--network host`**：這一階段不得連外網——**能抓資料的特徵建置器就是能悄悄依賴未來資料的特徵建置器** |
| [`mlops/publish_forecast.py`](mlops/publish_forecast.py) | 由 `retrain.sh` 呼叫 | 用全部可得資料重新擬合並發布預測——**如果模型配得上** | 輸給天真基準就不發布。這是這條線目前最有價值的機制，而且它**正在正確地擋著** |

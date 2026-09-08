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

## 模型怎麼換（給要擴充的人）

模型不是寫死的：`mlops/backtest.py` 的 `MODELS` 是註冊表，
目前有 `HistGradientBoostingRegressor`（梯度提升樹）與 `Ridge`（統計／線性）兩個家族。

```bash
mlops/run.sh backtest.py --list-models
mlops/run.sh backtest.py --algorithm Ridge --horizon 1 --predict-delta --dry-run
```

加一個模型要動什麼、動之前必須先回答什麼（缺值 51.8%、556 列、這台機器的時間上限），
以及統計／深度學習／混合模態各自卡在哪，寫在
[`docs/MLOps-Model-Extension.md`](../../docs/MLOps-Model-Extension.md)。

## 這個 pilot 帶進來的兩個**業務層**問題（2026-09-08）

這一節記的不是平台的問題。平台的部分（守衛怎麼寫、控制項怎麼證明會紅）在
`docs/Backlog.md` §30。**這裡記的是「因為做的是公衛監測資料，才會存在」的問題**，
以及做決定時我們知道什麼、不知道什麼。之所以要分開放，是因為換一個 pilot
（例如換成院內檢驗值）這兩個問題會長成完全不同的樣子，而平台那半不會變。

### 背景：為什麼是「年對年、同一個疫情週」

三件領域知識決定了整個比較的形狀，缺一個都會做出錯的指標：

1. **這是季節性資料。** 流感、腸病毒、腹瀉都有明確的年週期。用「本週 vs
   前八週」這種滾動視窗，每個季節交替都會觸發一次，而且每次都是對的——
   一個準時喊狼來了的告警，比沒有告警更糟，因為它訓練人去關掉它。
   所以比較的對象是**去年的同一週**，季節項才會被消掉。
2. **時間軸是「疫情週」不是日曆週。** 疾管署的週監測資料以 epi-week 發布，
   一年 52 或 53 週，週界不對齊月份也不對齊年界。`period` 表裡有 4,933 個期間，
   其中 1,048 個沒有對應的日曆日（板面上那條 `epiweek` 黃燈就是它，
   **待疾管署查證，不是我們的 bug**）。
3. **地理維度是 22 個縣市。** 全國就是這 22 個。任何「多少地區同向變動」的
   判斷，分母都必須參照 22 這個數字才有意義——這是後面 `>= 11`（半數）
   那個門檻的由來。

### 問題一：「全國」這兩個字在這份資料上不是免費的

**現象。** `dataops_yoy_ratio` 的說明寫 "National total"，板面標題寫「全國」。
實際上分子與分母是在「今年與去年**都有回報**的地區」上加總的——
今年有、去年沒有的縣市，會從分子分母**同時消失**。

**量測（2026-09-08，13 支疾病）。** 12 支完全不受影響（兩年都是 22/22 個地區）。
1 支受影響：急性出血性結膜炎，今年 21 個地區共 193 例，去年 20 個，
配對後只剩 20 個地區、191 例。板面顯示 `0.900943`，真正的全國比值是
`193/212 = 0.910377`。

**為什麼不是「把數字改對」就好——這才是業務決策。**

兩種做法各自回答不同的問題：

| 做法 | 它回答的問題 | 在這份資料上的後果 |
|---|---|---|
| 各年獨立加總（真全國） | 「今年全國比去年多還是少」 | 一個縣市**這一年才開始回報**，會被讀成疫情上升 |
| 先配對地區再加總（現行） | 「在可比較的範圍內，變化多大」 | 該縣市的病例完全不進入比較 |

這個指標存在的目的是**偵測管線異常**（見 [ADR-0005](../../docs/decisions/0005-dataops-monitoring-scope.md)），
不是產出流行病學報表。對偵測而言，「沒配對到的地區」正是**最容易偽裝成真實變化**
的東西——它會讓一個純粹的行政區調整長得像疫情。所以**內連是刻意的，保留**。

**決定：修標示，不修查詢。** HELP 改寫成「只加總兩年都有回報的地區」並帶上
上面那組實測數字，panel 標題改成「年對年比值（**可比地區**，最近一個已結算疫情週）」。

**這個決定的代價，講清楚。** 長官若問「上週全國幾例」，這個數字**不能拿來回答**。
它回答的是「和去年同期比，可比範圍內差多少」。兩者在 12 支疾病上剛好相同，
在第 13 支上差 1.04%——而且**誤差沒有上界**：新增一個縣市回報，
它整筆會從分子消失。要能回答「全國幾例」，得另外做一個誠實加總的指標，
那是新範圍，已登記為 `docs/Backlog.md` §27 的 T14（`prev` 側完整度守衛）。

**沒有被驗證的假設，明講**：我們假設「今年有、去年沒有」是**回報涵蓋的變化**
（行政區調整、該縣市當年零通報而未產列）。也可能是**上游資料缺漏**。
這兩者在 `surveillance_fact` 裡長得一模一樣，我們沒有辦法從資料本身分辨。
真要分辨得回頭問疾管署那一年那個縣市是否確實零例——**這是業務問題不是工程問題**。

### 問題二：疫情週的編碼方式讓「已結算週」的判定每年一月失效

**背景：為什麼需要「已結算週」這個概念。** 監測資料會補報。拿一個還在填的週
去跟一個完整的週比，比出來的下降是假的。所以要先決定「最近一個可以用的週」。

**這個判定的歷史。** 第一版寫死「往前退 100」——`epi_year*100+epi_week` 的
100 就是**整整一年**。結果是：資料跑到 2026w32 時，它拿 2025w32 跟 2024w32 比。
**偵測器對「唯一可能被引入故障的那一年」結構性失明**，而且數字一直看起來合理。

第二版改成資料驅動：**取最近一週，其地區涵蓋數 ≥ 前 12 週的中位數**。
理由是實測的——2026-08-29 量過，13 支疾病裡有 12 支的最新一週，
回報地區數不低於前 12 週的中位數。**這個來源是整週發布的，不是逐日滴入的。**
資料驅動而不是寫死常數，是為了「萬一上游哪天開始發布不完整的週，它會自己往回退」。

**這一輪找到的問題。** 「前 12 週」寫成 `p.yw >= c.yw - 12`，而
`yw = epi_year*100 + epi_week`。**這個減法只在同一年之內是「往前 12 週」**。
在 2026w01，它要的是 `[202589, 202600]`——沒有任何一週能落在這個區間。

實測（真實鏡像）：week 1 的 191 個（疾病,週）組合**全部**被丟掉；
week ≤ 12 共丟 191 個；week 13–52 只丟 1 個（資料集的第一週，那是應該的）。

**後果是業務性的，而且每年一月準時發作一次**：把同一份鏡像截到 2026w01，
壞的寫法選出 `202553`、正確的選出 `202601`。也就是說**每年一月的第一週，
板面會把「一年前的那一週」貼上「最近一個已結算疫情週」的標籤，
然後拿它跟兩年前比**。這與第一版的 `- 100` 是同一個病復發。

**決定：改用窗口框，不改語意。**
`MEDIAN(geos) OVER (PARTITION BY disease_id ORDER BY yw ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING)`。
`ROWS` 數的是**排序後的位置**，年界對它不存在。判定規則本身一個字沒改，
改的只是「前 12 週」怎麼算。附帶效果是整段自連接消失，程式碼變少。

**為什麼這個修正需要一個「搬資料」的控制項。** 在九月跑測試，證明不了一月的事。
所以控制項是把同一份真實鏡像**截到 2026w01**，斷言仍選出 `202601`；
再加兩條負控制（截到 w02、完全不截）證明平時的行為沒有改變。
這是唯一能在一年中任何一天重跑的形式。

**仍然 UNVERIFIED**：真實的 2027w01 尚未到來。到那一週要看
`platform/dataops/settled_week.py` 的 `LAG_OK`。

### 這兩個問題的共通形狀（給下一個 pilot）

兩者都不是程式錯誤，是**領域編碼的後果**：

- 「全國」是一個**業務詞彙**，而資料裡的實體是「有回報的地區」。
  兩者在 12/13 的情況下相等，於是差異不會在測試裡出現，只會在報告裡出現。
- 「疫情週」被壓成一個整數以便排序，而**排序正確不代表算術正確**。
  這個形狀已抽成跨 AI 的知識記錄（AIS `packed-key-arithmetic`），
  因為它跟公衛無關——任何把 `year*100+week`、`20260908`、`major*1000+minor`
  拿去做加減的地方都會中。

**下一個 pilot 接進來時要先問的兩句話**：
1. 報表上的每一個業務名詞，在資料裡對應的實體是什麼？兩者何時會不相等？
2. 有沒有把多個欄位壓進一個數字的鍵？有的話，程式碼裡對它做過算術嗎？

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

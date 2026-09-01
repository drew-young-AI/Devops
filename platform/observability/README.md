---
type: platform-adapter
title: 可觀測性 Adapter
description: Metrics, logs, alerting, log data governance (classify then redact then separate), and human access control for Grafana.
tags:
  - observability
  - alerting
  - data-governance
timestamp: 2026-08-15T19:56:49+08:00
---

# Observability Adapter — Metrics, Logs, Alerting

Grafana + Prometheus + Loki + Alloy + Alertmanager, all bound to
`127.0.0.1` only.

```bash
cd platform/observability && docker compose up -d && cd -
platform/observability/check_health.sh          # deterministic verdict

```

| Service | Local port | Purpose |
|---|---|---|
| Grafana | `13000` | dashboards, alert view |
| Prometheus | `19090` | metrics, alert rule evaluation |
| Loki | `13100` | container logs |
| Alertmanager | `19093` | alert grouping, dedup, silencing |
| Alloy | — | ships Docker logs to Loki |

## Alerting — why it exists

Before this, "is the service healthy" was answered by a human looking at a
Grafana dashboard. That is not a deterministic answer: it is not
reproducible, it cannot be scheduled, and two people can read the same graph
differently. Alert rules move the threshold into version control
(`prometheus/alerts/*.yml`) so the answer is the same every time and for
everyone — including a scheduled agent, which cannot look at a graph at all.

### The rules

| Alert | Fires when | Severity |
|---|---|---|
| `DevelopServiceDown` | develop target unscrapable 1m | warning |
| `ProductionLikeAllColorsDown` | **no** blue/green color up for 1m | critical |
| `ScrapeTargetDownProlonged` | any non-blue/green target down 10m | warning |
| `HighErrorRate` | 404 ratio > 10% for 5m, with traffic > 0 | warning |

Two of these encode a non-obvious correctness requirement:

- **Blue/green makes a naive `up == 0` alert wrong.** Exactly one color
  serves traffic; the other is *supposed* to be down, and `deploy.sh promote`
  deliberately leaves the old color running for rollback. A per-target rule
  fires forever on the parked color. `ProductionLikeAllColorsDown` uses
  `sum(up{...}) == 0` instead, which is the real outage condition and keeps
  working when a promote flips which color is idle. This was not theoretical:
  the first version of `ScrapeTargetDownProlonged` was a bare `up == 0` and
  was observed sitting in `pending` on the parked green target within
  minutes, on its way to firing permanently.
- **`0/0` silently never fires.** An unguarded error-ratio expression yields
  `NaN` when there is no traffic, and `NaN > 0.10` is false — so the alert
  would look armed while being incapable of firing in exactly the low-traffic
  conditions where a bad deploy is easiest to miss. `HighErrorRate` has an
  explicit `and rate(...) > 0` clause so "no traffic" is a deliberate
  non-alerting state rather than an accidental one.

### Verified end-to-end (2026-08-13) — by breaking things, not by reading config

| Injected condition | Observed |
|---|---|
| `docker stop` develop container | rule `inactive → pending` in ~10 s, `→ firing` at ~71 s (`for: 1m`), alert delivered to Alertmanager with correct labels, summary and runbook |
| develop restarted | alert cleared and Alertmanager active list back to 0 within ~10 s |
| `docker stop` production-like blue (green already parked) | `ProductionLikeAllColorsDown` fired **critical** — and did *not* fire while blue was still up, confirming the blue/green aggregation is right |
| both restored | back to `HEALTHY`, NGINX develop (18443) and production-like (19443) vhosts both returning 200 |

## `check_health.sh` — the scheduled-agent interface

One command, one reproducible verdict, one exit code to branch on:

| Exit | Verdict | Meaning |
|---|---|---|
| 0 | `HEALTHY` | monitoring verified working, no active alerts |
| 1 | `DEGRADED` | monitoring working, worst active alert is warning/info |
| 2 | `CRITICAL` | monitoring working, a critical alert is active |
| 3 | `UNKNOWN` | **monitoring itself is broken — health is unknowable** |

`--json` for machine consumption, `--no-evidence` to skip writing an
evidence file. Each run otherwise writes
`evidence/observability/health_<ts>.json`.

### Exit 3 is the point of this script

A dead Prometheus reports zero active alerts. So does a perfectly healthy
one. **Those two states are byte-identical to any naive checker**, and the
naive checker calls both of them "fine" — which means the monitoring system
fails open, silently, exactly when you need it.

So `check_health.sh` refuses to interpret an empty alert list until it has
proven something was actually watching. It verifies, in order, before
looking at a single alert:

1. Prometheus is reachable
2. Prometheus has **more than zero** alert rules loaded (zero rules can
   never fire, which is a dead monitor wearing a healthy costume)
3. Every loaded rule is evaluating without error
4. Prometheus has an **active Alertmanager wired** (otherwise alerts fire
   into the void and the list stays empty forever)
5. Alertmanager itself is reachable

Any failure → `UNKNOWN`/exit 3, never `HEALTHY`. All four verdicts were
tested by injecting the real condition — a dead Prometheus URL, a dead
Alertmanager URL, one stopped container, two stopped containers — not by
reasoning about the code.

Scrape-target health is reported for diagnosis but deliberately does **not**
affect the verdict: a target being down is what the alert rules are for, and
the idle blue/green color is legitimately down.

## Why no notification receiver yet

Alertmanager's receiver is `local-null`: it accepts and holds alerts, and
sends nothing. Alerts are consumed by polling `/api/v2/alerts` (which is
what `check_health.sh` does).

Wiring a real destination — Telegram, email, webhook — needs a credential
and an egress decision, and both are the user's call, not something to
default into. The routing *shape* is already correct (critical is split into
its own branch with a shorter `repeat_interval`), so adding a destination
later is a receiver definition, not a redesign. This follows the same
"don't fake production capability" principle as `platform/vault/`'s
deliberate lack of auto-unseal.

`inhibit_rules` suppresses `ScrapeTargetDownProlonged` for a service already
reporting `ProductionLikeAllColorsDown`, so a real outage produces one
signal rather than two.

## Grafana Alertmanager datasource

Provisioned so the human view and the scheduled agent's view read the *same*
Alertmanager and cannot drift apart.

**Known quirk, verified not a misconfiguration**: Grafana's generic
`/api/datasources/uid/<uid>/health` endpoint returns `500 plugin
unavailable` for this datasource, because the Alertmanager datasource is a
core (non-plugin) type with no backend health handler. The datasource
genuinely works — confirmed by proxying real requests through Grafana
(`/api/datasources/proxy/uid/<uid>/api/v2/status` returns the live cluster
status, `/api/v2/receivers` returns `local-null`), which is the same path
the Alerting UI uses.

## Log data governance (2026-08-14)

Three mechanisms in the ingestion path, in this order: **classify → redact →
separate**.

### Classify

A service declares its own class with a Docker label:

```yaml
labels:
  platform.data_class: "restricted"

```

Declarative and owned by the service, not a hardcoded list in Alloy that
goes stale the moment a service is added. Anything that does not declare a
class is `internal` — the safe default is the one that does *not* grant the
wider audience access. The two relabel rules are exact complements, so no
container can land in both tenants or in neither.

### Redact (v1)

`loki.process` masks PII **at write time**, before the line reaches storage,
applied to both pipelines — PII leaks into whichever log the developer
happened to be writing, which is rarely the one anyone classified as
sensitive.

Write-time, not query-time, is the whole point: a query-time filter is a
promise that everyone who ever queries will remember to apply it, and once
an unmasked identifier is in storage the only real remedy is rebuilding the
store. This is the one mechanism where being late costs more than being
imperfect, which is why a v1 ruleset shipped now rather than a complete one
later.

**v1 scope, stated honestly**: three high-confidence patterns — Taiwan
national ID, email address, and credential-shaped tokens
(`ghp_`/`github_pat_`/`hvs.`). It will *not* catch free-text names,
addresses, or an identifier written in an unexpected format. Extending it
means adding a `stage.replace` block; nothing else changes.

### Separate

Different Loki **tenants**, not just different labels. A label can be
filtered out by a query someone chooses not to write; a tenant is enforced
by Loki on every request, and a datasource pointed at `platform` is
structurally incapable of returning restricted data.

| Tenant | Contents | Retention |
|---|---|---|
| `platform` | operational logs, default for anything unclassified | 168h |
| `restricted` | services declaring `data_class=restricted` | **72h** |

Restricted data is kept for **less** time, not more. How long sensitive
material continues to exist is itself a control. The audit-style long
retention a compliance body might require is deliberately not set — that
requirement does not exist yet, and guessing would mean holding sensitive
data longer than anyone asked for.

Note that `auth_enabled: true` in Loki does not mean Loki authenticates
anyone; it means Loki requires and honours `X-Scope-OrgID`. Authentication
of the caller stays with the surrounding layer (which Grafana datasource an
org can reach). Loki's naming misleads often enough to be worth stating.

### Verified end-to-end, by generating real PII

A throwaway container labelled `platform.data_class=restricted` emitted a
fake national ID, email and token:

| Check | Result |
|---|---|
| line stored in tenant `restricted` | `patient [REDACTED_TWID] contacted [REDACTED_EMAIL] token [REDACTED_TOKEN]` |
| same container queried from tenant `platform` | 0 lines — correctly isolated |
| raw PII regex across **both** tenants | 0 matches |
| query with no `X-Scope-OrgID` header | `401` — tenancy is enforced, not advisory |

### Disk pressure protection

Two layers, because they fail differently:

- **Loki limits** (`ingestion_rate_mb`, `per_stream_rate_limit`,
  `max_global_streams_per_user`) keep a noisy tenant from overwhelming Loki.
- **Docker `json-file` rotation** (`max-size: 10m`, `max-file: 3`) on every
  service is what actually protects the host disk. Loki's limits do nothing
  about a container writing a tight log loop into the daemon's own log files
  — that fills the disk and takes down every service including the
  monitoring that would have explained why.

## Human access control (2026-08-14)

`scripts/setup_grafana_identity.sh` — idempotent, sources the admin
credential from Vault (`secret/devops/grafana-admin`), writes the gitignored
`.grafana.env` delivery file, resets the live admin password, and verifies
both directions.

Anonymous access is **off**. It had been on with `Viewer` for everyone,
which made every human RBAC control elsewhere in the platform moot at the
one place people actually look at data.

### Grafana 登入帳號與密碼管理 (Access Credentials)

- **帳號 (Username)**: `admin` （注意：不是 `platform-admin`，那是 Vault 的人類 RBAC 帳號）
- **密碼來源 (Source of Truth)**: 統一儲存於 Vault 的 `secret/devops/grafana-admin` 路徑中。
- **本機臨時傳遞檔 (Disposable Env)**: `/Users/drew/ENV/Devops/platform/observability/.grafana.env`（gitignored，由腳本自動帶入）。
- **重設與同步指令**: 若需重新產生或同步 live 密碼，請直接執行：

  ```bash
  platform/observability/scripts/setup_grafana_identity.sh

  ```

### The trap this script exists to close

`GF_SECURITY_ADMIN_PASSWORD` is only honoured when Grafana initialises its
database for the **first time**. On an existing `grafana-data` volume it is
silently ignored and the admin account keeps whatever password it had.

Setting that variable and stopping there is *worse than doing nothing*: it
converts "everyone is a viewer" into "anyone who tries the most-guessed
credential on earth is an admin", while the config reads as locked down.
Observed exactly that — `curl -u admin:admin` succeeded after the variable
was set. The script now resets the live password via
`grafana cli admin reset-admin-password --password-from-stdin` and asserts
both that the Vault credential works **and** that `admin:admin` no longer
does.

Vault is the source of truth; `.grafana.env` is a disposable delivery
detail, regenerable by re-running the script. That is what distinguishes it
from the `.env`-as-secret-store pattern this platform moved away from.

## Known gaps

- **No container CPU / memory / restart metrics.** Nothing collects them —
  there is no cAdvisor or node-exporter. Alert rules for resource pressure
  and crash-looping are therefore *absent rather than broken*: writing rules
  against metrics that are never produced yields alerts that can never fire,
  which reads as "all clear" and is strictly worse than an acknowledged gap.
  Adding cAdvisor is the fix, and it is a deliberate open decision — it is
  another container, and `docs/Plan-detail.md` Station 8 requires every new
  tool to map to an identified control gap rather than being added by
  reflex. This gap is now identified; the decision is not made.
- **No latency metric.** `station1-hello` exposes only
  `station1_requests_total` and `station1_errors_total` — no histogram — so
  there is no p95/p99 rule. Adding one requires changing the pilot.
- **`station1_errors_total` counts 404s only, not 5xx.** `HighErrorRate`
  therefore detects bad routing/clients, not server faults. Naming it
  "error rate" without this note would overstate what it covers.
- **No scheduled runner yet.** `check_health.sh` is the interface; nothing
  calls it on a timer. That is the next step, and it is intentionally
  separate — the check has to be trustworthy before automating it.
- **Alert notification is unwired** — see above.
- **Redaction is v1.** Three patterns. Free-text names, addresses and
  unexpected identifier formats pass through. The mechanism is in place and
  verified; the ruleset is a starting point, not coverage.
- **Grafana org-level segregation is provisioned but not exercised.** Both
  Loki datasources currently live in the default org, so any authenticated
  Grafana user can reach the restricted one. Moving `Loki (Restricted)` into
  a separate org (Grafana OSS scopes datasources per org) is the remaining
  step, and it needs a second real human user to be meaningful.
- **No long-retention audit tier.** Deliberate: see "Separate" above.
- **Loki and Prometheus data are not backed up** — see
  `platform/backup/README.md` for why, and for the condition that would
  change it.

## 兩個新增的告警群組（2026-09-01）

### `platform-nodes.yml` — 讓狀態板真的會響

`dag.py` 匯出 `devops_node_state` 已經數週，**沒有任何規則消費它**。一個節點可以變紅、
板面可以把它畫成紅色，然後沒有人被告知——那只有在有人剛好打開網頁時才算通知。

| 規則 | 條件 | 為什麼是這個門檻 |
|---|---|---|
| `PlatformNodeFailed` | `devops_node_state{state="fail"} == 1`，持續 30m | `dag.py` 每 15 分鐘跑一次，所以節點必須連紅兩個評估週期。一個週期會對「正在重啟中的探針」誤報 |
| `PlatformBoardStale` | `dag.prom` 超過 45 分鐘沒更新 | **這條守著上面那條**：node-exporter 會繼續提供最後讀到的 textfile，所以 `dag.py` 停掉之後每個節點指標會凍結在最後一個值，而凍結的綠燈和健康的綠燈長得一模一樣 |

驗收方式是**評估**不是解析（[ADR-0007](../../docs/decisions/0007-verify-by-evaluation.md)）：
`/api/v1/rules` 的 `health` 必須是 `ok`，由 `test_dataops_metrics.sh` 對所有規則檢查。

### scrape job `station2-twin-k8s` — 監控遷移過去的那份

pilot 有兩份副本。在此之前 Prometheus 只抓 Compose 那份；K8s 那份掛在 ClusterIP，
而 k3d 只對外開 6443，所以**在原理上就抓不到**。

`environment=k8s`（不是 `develop`），因為兩份副本是真的不同的部署——不同的憑證路徑
（vault vs static）、不同的底座——把它們貼上同一個 environment 標籤，等於把「觀察它們
何時分歧」這件唯一有價值的事合併掉。

守衛：`platform/tests/test_migration_observed.sh`。

---

## `rollup_health.py` — 把 1,520 份快照收斂成一個答案（2026-09-01）

`check_health.sh` 每 15 分鐘寫一份 `health_<ts>.json`。三週後那是 1,520 份
結構完全相同的檔案。[ADR-0006](../../docs/decisions/0006-context-compaction.md)
量過這堆東西，結論是：

> 沒有任何 agent 會讀 1,215 個檔。它會讀一兩個然後外推——
> 而「讀了兩個就結論全體健康」正是 grounding gap 的定義，只是穿著證據的外衣。

並且指定了處方：**「收斂要用彙總，不是用 `find -mtime -delete`。」**
`rollup_health.py` 就是那份彙總。**它一份快照都不刪。**

```bash
python3 platform/observability/rollup_health.py          # 寫入彙總＋metrics
python3 platform/observability/rollup_health.py --json   # 完整結果到 stdout
python3 platform/observability/rollup_health.py --no-write --json   # 唯讀
```

耗時 0.12 秒／1,520 檔（純標準函式庫，無外部相依）。

### 它回答的三個問題

| 問題 | 為什麼單看一份快照答不出來 |
|---|---|
| 每項完整性檢查總共失敗幾次？ | 快照只講它被寫下的那一刻 |
| 是零星雜訊，還是**一段連續**的中斷？ | 24 次分散的失敗和一段連續六小時，次數相同、意義完全不同 |
| **有沒有時段根本沒寫下任何快照？** | 空窗在任何單一快照裡都不存在——它是檔案之間的東西 |

第三個是最重要的。**「看了，是壞的」是證據；「根本沒看」不是。**
兩者分開計算、從不相加，因為相加會得到一個沒有意義的數字。

### 第一次執行找到什麼

| 指標 | 值 |
|---|---:|
| 監測涵蓋率 | **83.6%**（實際 1,520 ／應有 1,818） |
| 最長連續中斷 | **73.7 小時**（2026-08-21 → 08-24，Prometheus 與 Alertmanager 同時 Errno 61） |
| 無紀錄空窗 | 54 次，最長 25.9 小時 |
| UNKNOWN 判定 | 259 份 |

那 73.7 小時裡，探針每 15 分鐘忠實地把「連線被拒」寫進證據，約 200 份。
**沒有人打開過任何一份。** 這就是 ADR-0006 說的事，只是規模比它記載的
11 小時版本大了近七倍。完整分析見
[ADR-0009](../../docs/decisions/0009-health-rollup-not-retention.md)。

### 它拒絕做的事

**空目錄一律拒絕，而且不寫任何 metrics。** 在零個樣本上，「每項檢查都通過」
是真的——而那份綠色的 `.prom` 會被 Prometheus 一路帶下去，板面顯示一切平靜。
`VACUOUS` 不是 `PASS`，這是整個平台的組織原則。

輸出：

- `evidence/observability/health_rollup.json` — schema `health-rollup/1`
- `evidence/statusdag/health_rollup.prom` — 直接落在 node-exporter 已經唯讀掛載的
  目錄（見 `compose.yaml`），所以不需要新的 scrape target

### 板面與告警

- **Grafana**「三線階段燈號」面板 100–104：涵蓋率、最長連續中斷、空窗次數、
  各檢查失敗數、判定分布
- **`PlatformHealthRollupStale`**（severity `info`）：彙總本身停掉時，涵蓋率會
  凍結在最後一個數字，看起來像「沒有新問題」，實際是「沒有再統計過」。
  與 `PlatformBoardStale` 同一個理由，只是換一個檔案

**不對涵蓋率設告警**：它是全期累計值，只會單調變化，設了會永遠響或永遠不響。
當下的健康由 `PlatformNodeFailed` 與 `check_health.sh` 負責。

### 守衛

`platform/tests/test_health_rollup.sh`（tier 1，16 項）。控制組全部是**合成的**：
偽造一段六小時中斷、偽造一個四小時空窗、餵一個空目錄，然後要求偵測器把它報出來。
拿真實目錄測幾乎證明不了什麼——那段歷史大部分是乾淨的，一個寫死回傳「沒有異常」
的偵測器每天都會通過。

突變測試（2026-09-01，四個突變全部被抓，還原後與基準逐位元相同）：

| 突變 | 結果 |
|---|---|
| `find_episodes()` 永遠回傳 `[]` | CAUGHT |
| `find_gaps()` 永遠回傳 `[]` | CAUGHT |
| 空目錄回傳 0（那個 vacuous pass） | CAUGHT |
| 中斷時長寫死為 0 | CAUGHT |

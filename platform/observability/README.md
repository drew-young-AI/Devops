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

## 誰負責哪一格（先看這張，因為這裡最常被記錯）

| 支柱 | 元件 | 狀態 |
|---|---|---|
| 指標 | **Prometheus** | 在跑 |
| 日誌 | **Loki** | 在跑。**Loki 才是 Grafana 生態系中負責儲存與查詢 log 的核心組件** |
| 追蹤 | — | **完全沒有** |
| 錯誤追蹤 | — | **完全沒有**（那是 Sentry 那一類的位置，traces 不能替代） |
| 採集器 | **Grafana Alloy v1.10.2** | 在跑。它是 **OpenTelemetry Collector 的一個發行版**，目前只採 Docker log |
| 介面 | **Grafana** | 在跑。**Grafana 不儲存任何東西**，它是查詢與呈現 |
| 告警 | **Alertmanager** | 在跑 |

**「Prometheus 和 Grafana 已經有了，所以 log 有人管」是錯的**——
Prometheus 不存 log、Grafana 不存任何東西。填那一格的是 Loki，
而在 2026-09-02 之前沒有任何東西檢查過 Loki 有沒有收到任何一行
（見下方 `loki_coverage.py`，以及 [ADR-0011](../../docs/decisions/0011-loki-not-elk.md)）。

**追蹤與錯誤追蹤的後端刻意不選、不裝**，應用端一律 OTLP；
**在 span 屬性的遮蔽做完之前不開 OTLP 接收端**——
追蹤是三種訊號裡 PII 風險最高的一種，而現有遮蔽只針對 log 行。
完整理由、三個前提與重審觸發條件見
[ADR-0012](../../docs/decisions/0012-otel-at-the-boundary-backend-deferred.md)。

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

---

## 遮蔽到底遮到多少（2026-09-01 量化）

上面「Verified end-to-end, by generating real PII」是 **2026-08-14 的一次手動驗證**。
一次性的手動驗證，正是這個 repo 在自己的 CI 裡批評過的形狀
（「previously only verified manually, once, ad hoc」）——在此之前，
**沒有任何測試斷言遮蔽有遮到任何東西**，任何一條 regex 今天壞掉都不會有人知道。

```bash
python3 platform/security/redaction_check.py
```

實測（全部使用合成值，本檔案不含任何真實識別碼）：

| 類別 | v1 | 說明 |
|---|---|---|
| 台灣身分證字號 | **OK** | |
| email | **OK** | |
| GitHub PAT | **OK** | |
| Vault service token | **OK** | |
| 健保卡號 | — | 12 位純數字、無字首，和任何長數字無法區分 |
| 病歷號 | — | 院內格式，需要 CYCH schema 才可能有 pattern |
| 手機號碼 | — | 與日期、port、列數衝突，除非錨定上下文 |
| 出生日期 | — | 形狀與這些日誌裡每一個時間戳完全相同 |
| 姓名（自由文字） | — | 沒有詞彙訊號，需要名單或 NER，不是 regex |
| 地址 | — | 自由文字，設定檔的註解本來就說了 |

**10 個類別中有 6 個「沒有被找過」。** 沒有被找過**不等於**不存在——
`config.alloy` 的註解本來就誠實地寫了「a mechanism with a starter ruleset」，
這裡只是把那句話變成一份**具名清單**，好讓 v2 有東西可以對照著界定範圍
（見 `docs/Backlog.md` §6）。

### 這次真正抓到的風險：同一組規則寫了兩遍

`config.alloy` 把三條規則各宣告兩次——`redact_internal` 一份、
`redact_restricted` 一份。**兩份副本就是它們分歧的方式**，而分歧時繼續洩漏的
會是 `restricted`——**比較敏感的那一條串流**。

這個平台在同一天已經被同一個形狀咬過一次：K8s 那份 pilot 副本的憑證模型是兩份
裡比較弱的，而沒有任何東西在比對它們。所以這裡直接加上斷言：
**兩個 block 的規則集必須完全相同。**

### RE2 相容性檢查，以及它為什麼不是多餘的

Alloy 用 Go 的 RE2 執行這些 regex，這支檢查用 Python 的 `re`。兩者在這裡用到的
子集上一致（字元類別、`\b`、`{n,}`、交替），所以比對結果是有意義的——
但它不是正式環境的引擎，而兩者可能**災難性地**不一致的方式只有一種：

**lookahead 或 backreference 在 Python 編得過，會被 RE2 拒絕。**
那會讓 Alloy 帶著一個「安靜地不存在」的 stage 繼續執行，而設定檔讀起來
仍然像是有在遮蔽。所以這一項是明確檢查的。

### 守衛

`platform/tests/test_redaction.sh`（tier 1，10 項，完全 hermetic——
不需要容器，規則從 `config.alloy` 讀出來套用在合成字串上）。

負向控制和正向控制一樣重要：**一般日誌行必須原封不動通過**。
一個把所有東西都遮掉的遮蔽器會通過每一項正向控制，然後把日誌毀掉——
這條斷言就是讓「多遮一點比較安全」永遠不能成為預設。

突變測試（四個突變，全部被抓，`config.alloy` 還原後逐位元相同）：

| 突變 | 結果 |
|---|---|
| **只有 restricted** 這一份掉了身分證規則 | CAUGHT |
| email 規則安靜地什麼都不匹配 | CAUGHT |
| 加一條 catch-all 把整行日誌吃掉 | CAUGHT |
| 加一個 RE2 會拒絕的 lookahead | CAUGHT |

---

## `loki_coverage.py` — 日誌管線到底有沒有在動（2026-09-02）

**「我們不需要 ELK，因為 Prometheus 和 Grafana 已經有了」——這句話的結論對，理由錯。**
Prometheus 不存 log，Grafana 不存任何東西。**填 ELK 那一格的是 Loki**，
而在這支腳本之前，**沒有任何東西檢查過 Loki 有沒有收到任何一行**。

`docker ps` 說 Loki 是 Up、compose 宣告兩個租戶、`config.alloy` 宣告寫入時遮罩、
ingress 守衛拒絕曝露 Loki——**四件都是關於設定的陳述，沒有一件是資料流過的證據**。

```bash
python3 platform/observability/loki_coverage.py          # 報告
python3 platform/observability/loki_coverage.py --check  # 有不可辨識的資料類別就 exit 1
```

量到的（重跑會再得到一次）：

| 項目 | 值 |
|---|---:|
| tenant `platform` 已接收行數 | 71,289 |
| 串流數 | 111 |
| 位元組 | 14,260,653 |

決策紀錄：[ADR-0011](../../docs/decisions/0011-loki-not-elk.md)。

### 順帶查到的兩件事

**1. `restricted` 租戶在生產上從未收過任何一條串流。** 它被合成容器端到端驗證過一次
（見本檔「Log data governance」一節），之後沒有真實流量。**這是正確的狀態，不是故障**——
目前沒有服務宣告自己是 restricted。所以這支腳本**報告它、但不因它失敗**：
一個設計上就是紅的檢查，最後會變成沒人看的檢查。

**2. 分類值打錯字會「開放失效」，而且完全無聲。**
`discovery.relabel` 只在**完全等於** `restricted` 時把容器留在 restricted 租戶，
internal 管線是它的**精確補集**。這個分割可證明窮盡——那正是它安全的原因，
**也正是打錯字看不見的原因**：無法辨識的值不會報錯，它落進
**受眾較廣、保留期較長**的租戶（168h，不是 72h）。

`station2-twin` 曾宣告 `platform.data_class: platform`（那是**租戶**名，不是**類別**名），
而它上方的註解正好寫著「明確設定而不用預設值，因為未標記的服務會靜默落到錯的租戶」。
已改為 `internal`。**驗證放在這支腳本而不是路由規則裡**——加進路由規則會破壞補集性質，
而補集性質是這個分割可證明的基礎。

守衛：`platform/tests/test_loki_coverage.sh`（15 項，含五個合成控制項：
不可辨識的類別、有效類別、閒置管線必須拒答、Loki 連不到必須拒答、閒置租戶只報告不失敗）。
排程：`logcov`，每小時。

---

## `scripts/setup_notifications.sh` — 一次性，把 Telegram 憑證注進 Alertmanager

從 `alertmanager/config.template.yml` 產生 Alertmanager 的實際設定，
**憑證從 repo 外面注入**（產生出來的檔案在 `.gitignore` 裡）。

**一次性**：改過 Telegram token 或收件對象之後要重跑。
在 2026-09-02 之前這支腳本沒有出現在任何從 README 連得到的文件裡——
只被 `compose.yaml` 與模板檔引用，**而那不是人找得到的地方**。


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`check_health.sh`](check_health.sh) | 排程，每 15 分鐘 | 對整個堆疊做確定性判定 | 判定順序本身就是設計；每次寫一份快照到 `evidence/observability/` |
| [`rollup_health.py`](rollup_health.py) | 排程 `rollup`，每小時 | 把累積的快照收斂成一個可查詢的答案 | **一份都不刪**（ADR-0009）。**拒絕對空目錄產出健康報告**——空集合上的「全部正常」是恆真句 |
| [`loki_coverage.py`](loki_coverage.py) | 排程 `logcov`，每小時 | 日誌管線到底有沒有在動、資料類別是否可辨識 | 閒置管線與連不到 Loki 一律**拒答**（rc 2）；不可辨識的 `data_class` 轉紅（它會靜默落進受眾較廣、保留期較長的租戶） |
| [`scripts/setup_notifications.sh`](scripts/setup_notifications.sh) | **一次性**／換 Telegram 憑證時 | 從模板產生 Alertmanager 實際設定 | 憑證從 repo **外面**注入，產生的檔案在 `.gitignore` 裡。Alertmanager 不展開環境變數，所以 chat id 必須是字面值——這就是它必須被產生而不是被提交的原因 |


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到（能力必須是**該列的主詞**）。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`scripts/setup_grafana_identity.sh`](scripts/setup_grafana_identity.sh) | 一次性／換憑證時 | 從 Vault 取出 Grafana 管理憑證並交給 Compose | 示範平台宣稱擁有的**完整鏈**：Vault（真相來源）→ bootstrap 腳本 → gitignore 的 env 檔 → 容器。**中間沒有任何一段是明文躺在 repo 裡** |

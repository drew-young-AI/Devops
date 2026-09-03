---
type: platform-adapter
title: 排程 Adapter
description: "launchd-based scheduling in two tiers, why tier 1 must not depend on an agent, and how a scheduler's own absence is detected."
tags:
  - scheduling
  - automation
  - launchd
timestamp: 2026-08-15T19:57:49+08:00
---

# Scheduler

```bash
platform/scheduler/install.sh            # load the launchd agents
platform/scheduler/status.sh             # is every job actually running?
platform/scheduler/run_job.sh health     # run one job by hand
platform/scheduler/install.sh --uninstall

```

## Two tiers, and why they must not be merged

| Tier | Runs | When | Job |
|---|---|---|---|
| 1 | launchd + shell scripts | always | the deterministic verdict |
| 2 | an agent | on demand | read the evidence, correlate, diagnose |

**Tier 1 must never depend on an agent being alive.** If the platform's own
monitoring only works while a Claude session is open, the platform is blind
whenever nobody is using it — which is most of the time, and exactly when
you need it watching. So tier 1 is plain shell and launchd, no LLM anywhere
in the path.

Tier 2 is where an LLM earns its place: a script can decide *that* something
broke; working out *why*, correlating it against a recent deploy and a
denied audit record, and proposing a fix is the part a script cannot do.
`status.sh --json` and `evidence/scheduler/` are its input.

## Why launchd, not cron

launchd restarts agents after a reboot, and it **runs jobs that were missed
while the machine was asleep**. On a laptop, cron would simply skip a
night's backup and never mention it.

User agents in `~/Library/LaunchAgents`, never system daemons — nothing is
written to `/Library` or `/usr/local`, and `--uninstall` removes everything.

## The jobs, and why each cadence

Cadence comes from how fast the watched thing can change, not from a uniform
"hourly because that felt right".

`jobs.conf` is the source of truth and carries the full reasoning per job as
comments; this table is the summary. It was out of date until 2026-09-01 (it
listed 8 of the 16 jobs), which is the ordinary way an index rots: nothing
breaks, it just quietly stops describing the system.

| Job | Every | Reason |
|---|---|---|
| `health` | 15m | the core up/down signal, and cheap (~2s) |
| `board` | 15m | derived from evidence; a stale board misleads |
| `dag` | 15m | the traffic-light view; a stale green light is worse than no light |
| `stagereport` | 15m | the reviewer's view of the same probes; a stage page older than the board it summarises would disagree with it |
| `gha` | 30m | remote CI status, fetched into evidence. Polling GitHub from inside `dag.py` took 30s and failed; a scheduled fetch keeps the board fast and makes "never fetched" a visible state |
| `rollup` | 1h | the **historical** health view (`rollup_health.py`). Hourly rather than daily because "how long has this been broken" is asked *during* an incident, and a day-old answer omits the incident |
| `dataops` | 1h | freshness / drift / execution health. Hourly because the freshness alert answers "did the upstream stop", and a daily metric makes that question up to a day stale itself |
| `mirror` | 24h | the analytical Parquet mirror; a stale mirror **refuses to answer** rather than answering wrongly, so cadence is convenience here, not safety |
| `audit` | 24h | fail-closed risk, but slow-moving |
| `backup` | 24h | platform state changes on the order of days |
| `offsite` | 24h | follows `backup`; reports not-configured until a destination exists — a visible state rather than the silent absence of any offsite copy |
| `dast` | 24h | the deployed surface changes only on promote |
| `sast` | 7d | code is gated in CI already — this catches **upstream rule updates** finding old code, which is the only reason re-scanning unchanged source is worth anything |
| `restore` | 7d | expensive (spins a container), and the claim it proves degrades slowly |
| `rotation` | 7d | 90-day secret policy; daily would be noise |
| `retrain` | 7d | the source is weekly and lags ~2 weeks; daily would rebuild an identical feature set six days in seven |

**Deliberately never scheduled**: anything that waits for a human.
`deploy.sh promote` blocks for someone to type `PROMOTE`; scheduling it
would delete the release gate by accident. `test_scheduler.sh` asserts no
job command mentions promote or rollback.

## What the wrapper does, and the failure each part prevents

`run_job.sh` is more than `cd && run`. Every piece is there for a specific
way scheduling goes wrong:

- **Locking** (atomic `mkdir`, not a test-then-create race) — a slow job
  overlapping itself doubles load and can corrupt shared state; two backups
  writing the same archive directory is not hypothetical.
- **Stale-lock breaking** — a lock left by a killed process would otherwise
  disable that job *permanently and silently*, looking exactly like a job
  that is always busy.
- **Timeout** — a hung job is worse than a failed one: it holds the lock, so
  every later run is skipped while the schedule still reports green.
- **Evidence per run** — "it never ran" and "it ran and was fine" are
  otherwise the same observation. Same principle as `check_health.sh`'s
  exit 3.
- **Notify on transition only** — a job that reports failure every 15
  minutes trains people to mute it, and a muted alert is a disabled one.
  Recoveries notify too: silence after a failure is indistinguishable from
  the failure continuing.
- **`PATH` set explicitly** — launchd hands an agent almost nothing.
  `docker`, `python3` from uv, and `semgrep` are all absent from the default
  path, so a job that works in a terminal fails under launchd with
  "command not found" and no other symptom. This is the single most common
  way a launchd job silently does nothing.
- **Graded status for `health`** — `check_health.sh` returns 0/1/2/3 on
  purpose. A generic "non-zero means broken" reading would flatten DEGRADED
  and CRITICAL into "failed" and throw away the distinction.

## `status.sh` — who watches the watcher

**A scheduler cannot monitor itself.** If launchd never loads the agent, or
the plist is malformed, or a job dies on a PATH error, the result is not an
alarm — it is silence. And silence is what a healthy system produces.

So freshness is checked by the **consumer**. Each run records its time;
`status.sh` reads those records and reports any job whose last run is older
than `2 × interval + 60s`. A job that stopped running becomes `STALE` — a
visible state, not an absence.

Exit codes mirror `check_health.sh` deliberately: `0` all fresh and ok, `1`
degraded, `2` critical, `3` **stale or never run**. Staleness *outranks* the
recorded status: a job reporting "ok" from four days ago is a stale claim,
and reading it as good news is precisely the failure this prevents.

The value stream board shows the same state, so the human view and the
machine view cannot drift.

## Notification: local by default, external by explicit opt-in

A notification carries operational detail about a system handling medical
data. Pushing that to Telegram or a webhook is a decision with real blast
radius, and it is the user's to make — not a default inherited because it
was convenient.

Built-in sinks do not leave the machine: an append-only
`evidence/scheduler/notifications.jsonl`, and macOS Notification Centre.
Setting `NOTIFY_WEBHOOK` adds an external destination; **nothing is sent
anywhere until that variable exists.**

## Verified

| Check | Result |
|---|---|
| launchd fires a job with a working PATH | pass — `health` via `launchctl kickstart` |
| launchd job can reach docker | pass — `audit` (rotation) ran and reported |
| all 8 jobs run under launchd | pass — `status.sh` → `ALL_FRESH` |
| timeout kills a hung job | pass — 6s timeout on `sleep 300` → `timeout`, rc 124 |
| lock prevents overlap | pass — second run skipped cleanly |
| stale lock is broken, not obeyed | pass |
| never-run job reports exit 3 | pass |
| stale "ok" still verdicts stale | pass |
| notify fires on transition, not per run | pass — including recovery |
| 26 assertions across the suite | pass |

### One real bug the tests caught

Adding `disown` to suppress bash's "Terminated: 15" chatter removed the job
from the shell's job table — so `wait "$JOB_PID"` could no longer retrieve
an exit status, and **every job recorded success, including `false`**. The
scheduler looked perfect while recording nothing but `ok`.

Fixed by having the subshell write its own exit code to a file instead of
relying on `wait`. Found by `test_scheduler.sh`, not by reading the code —
which is the entire argument for the suite existing.

## Known gaps

- **Tier 2 is not built.** `status.sh --json` and the evidence directory are
  ready for an agent to consume; nothing consumes them yet.
- **No escalation.** A critical transition notifies once, locally. Nobody is
  paged, and there is no acknowledgement or on-call rotation.
- **Missed runs are not backfilled.** launchd will run a job late after a
  wake, but a job that failed is not retried before its next interval.
- **The scheduler is not itself monitored by anything external.** If both
  launchd and whoever reads `status.sh` are absent, staleness goes unnoticed
  — the recursion has to stop somewhere, and it stops at a human or an agent
  running `status.sh`.
- **Archives and evidence still grow unbounded.** Audit archives are
  compressed and never deleted (retention undecided), and
  `evidence/scheduler/` accumulates one state file per job plus a capped log.

---

## 三種「不是 ok，也不是失敗」的狀態（2026-09-01 新增第三種）

`run_job.sh` 不把 `rc != 0` 一律當成壞掉。有三種狀態刻意被分開，
因為它們要人做的事完全不同：

| 狀態 | 來源 | 意思 | 為什麼不併進 ok 或 failed |
|---|---|---|---|
| `not-configured` | rc 78 (EX_CONFIG) | 工作跑了，但它要的東西從來沒設定過 | 不是失敗（沒有東西壞），也不是 ok（沒有工作發生） |
| `degraded` / `critical` / `unknown` | `check_health.sh` rc 1/2/3 | 分級的健康判定 | 一律當 failed 會把它存在的理由丟掉 |
| **`vacuous`** | 輪替稽核 rc 2 | 工作跑了、連得上 Vault、**檢查了零個項目** | **這一種最危險：它長得像通過** |

### `vacuous` 是怎麼被發現的

`check_rotation_sweep.sh` 一直回報：

```
3 secret(s): 0 within interval, 0 due, 0 without a record, 3 exempt
ROTATION PASS -- every non-exempt secret has a record and is within its own interval
```

三個秘密**全部豁免**，所以「每個非豁免的秘密都在期限內」是在空集合上量化，
恆真。那行字讀起來像輪替政策被滿足了，實際是輪替政策什麼都沒檢查。

而這支腳本的作者**早就想過空集合的問題**——它有一段守衛，註解寫著
「An empty tree is not a pass」，處理的是「`secret/` 底下一個秘密都沒有」。
然後平台漂移進了**另一種空**，直接繞過那道守衛。

> 一道空集合守衛，是針對你當時想像得到的那種空寫的。
> 集合可以用別的方式變空。

### 板面上會列出全部原因，不是第一個

`probe_scheduler` 原本命中第一個 warn 就回傳。2026-09-01 這正好藏起一個新問題：
`offsite` 是 not-configured（已知且接受的狀態），所以節點顯示
「not configured: offsite」，而同一時間 `rotation` 剛開始回報 `vacuous`。

**節點顏色是對的，理由是錯的——而理由才是唯一有人會據以行動的部分。**
現在會全部列出：

```
[ warn ] 排程器   檢查了零個項目: rotation；not configured: offsite
```

### 一個自己造成的教訓：解除追蹤 live state 會讓切分支變成破壞性操作

同一天把 `evidence/scheduler/*_last.json` 從 git 解除追蹤（規則本來就寫著要，
見該次 commit）之後，一次分支切換把其中五個檔案從工作目錄弄丟了，
板面立刻報 `audit / backup / dast / sast / restore 都 never-run`。

**這些檔案解除追蹤之後，工作目錄就是它們唯一的副本。**
從 git 歷史還原會拿到 2026-08-26 的版本——那會謊報「上次執行是一週前」，
比沒有紀錄更糟。正確的處置是**重跑那五個工作**，讓紀錄是真的：

```bash
for j in audit backup dast sast restore; do platform/scheduler/run_job.sh "$j"; done
```

五個全部 ok（2s / 26s / 33s / 10s / 36s）。規則沒有錯，代價要知道。


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`install.sh`](install.sh) | 一次性／改 `jobs.conf` 後 | 以 launchd user agent 安裝或移除排程 | **用 launchd 不用 cron**：它是 macOS 支援的機制、重開機後會重新啟動、而且會補跑機器睡著時錯過的工作——筆電上 cron 不會 |
| [`status.sh`](status.sh) | 隨時 | 排程器自己活著嗎、每個 job 真的在跑嗎 | **排程器無法監控自己**：agent 沒被載入、plist 壞掉、job 死在 PATH 錯誤，結果都不是警報，是**安靜**。`NEVER FIRED` 會被明白寫出來 |
| [`notify.sh`](notify.sh) | 由 `run_job.sh` 觸發 | 排程 job 狀態轉換的通知出口 | **預設只送本機**：通知本身帶著平台狀態（哪個服務掛了、哪個閘門失敗、哪個 secret 路徑被拒），推到外部等於把維運內情送出去 |


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到（能力必須是**該列的主詞**）。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`run_job.sh`](run_job.sh) | 每個排程 job 的外殼 | 跑一個 job，**並留下它跑過的證據** | **外殼比排程重要**：裸的 cron 給你一個成功或失敗、答案在沒人讀的 log 裡。這支寫狀態檔、記錄覆蓋缺口、把 rc 對應成板面看得到的狀態 |

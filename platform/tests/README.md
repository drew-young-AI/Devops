---
type: platform-adapter
title: 平台自身測試
description: "The platform's own test suite: why it exists, what it deliberately does not cover, and the bug classes it now blocks at build time."
tags:
  - testing
  - ci
  - quality
timestamp: 2026-08-15T19:58:12+08:00
---

# Platform Test Suite

The platform's own tests. `pilots/station1-hello/tests/` tests the *pilot*;
this tests the *platform* — which had no automated coverage at all until
now, despite `deploy.sh` alone being 630 lines of bash that decides what
reaches production-like.

```bash
platform/tests/run_all.sh          # ~7s, exit 0 only if every suite passes

```

Runs on push/PR touching `platform/**` via
`.github/workflows/platform-tests.yml`.

## Why this exists

The trigger was a plan to extend the platform frequently — new deployment
targets, new adapters. On an untested 630-line bash platform, "frequent
change" means every edit needs a full manual deploy before you can trust it,
which is not a platform, it is a liability.

The evidence that this was overdue is the bug rate. In the single session
that built the LLM review and alerting layers, **seven** real defects were
found, and every one of them was invisible to code review — each surfaced
only by executing a path:

| Defect | Found by |
|---|---|
| `except TimeoutError` never fires on Python 3.9 (`socket.timeout` is not an alias until 3.10) | running the timeout case |
| Second-resolution filenames silently overwrote same-second evidence | running three reviews in one second |
| `ls \| tail -1` under `set -euo pipefail` aborted `promote` whenever no LLM review existed — the common case | running the function under `bash -euo pipefail` |
| `up == 0` fires forever on the parked blue/green color | watching it enter `pending` on green |
| `usage()` never listed `promote` or `rollback` | this suite, first run |
| `deploy`'s rejection message claimed promotion was "not-yet-built" — it is built, in the same file | this suite, first run |
| `pipeline-contract.yml` required `image_tag`; every producer emits `image` | this suite, first run |

The last three were found by these tests within seconds of writing them.

## Design constraints

**No Docker daemon, no live Prometheus, no MLX endpoint, no network.** The
suite must run in CI and be fast enough to actually get run. Everything here
completes in about 7 seconds.

**No test-only seams in production code.** Isolation comes from copying
`platform/` into a temp directory and invoking the copy — the platform
scripts already derive their repo root from their own path. The code under
test is byte-identical to the code that ships.

**Stubs only where reality cannot produce the condition.** Two of the
integrity states `check_health.sh` must handle — "Prometheus up but zero
rules loaded", "Prometheus up but no Alertmanager wired" — cannot be
produced on demand against a real Prometheus. Likewise a real model cannot
be made to reliably return prose instead of JSON. Those are stubbed. The
happy paths that a real daemon *can* exercise are not faked here; they are
covered by the end-to-end runs recorded in each adapter's README.

## Suites

| Suite | Covers |
|---|---|
| `test_static.sh` | `bash -n`, `py_compile`, YAML parse, executable bits, and alert-rule well-formedness (a typo'd rule key parses fine and then never fires) across all of `platform/` |
| `test_deploy_contract.sh` | `deploy.sh` argument handling and every safety gate: develop-validation, fail-closed on missing/malformed evidence, rollback with no prior color, teardown refusing the live color |
| `test_check_health.sh` | all four verdicts (`HEALTHY`/`DEGRADED`/`CRITICAL`/`UNKNOWN`), including each monitoring-integrity failure that would otherwise read as healthy |
| `test_llm_review.sh` | every degraded mode, and the core invariant that a `FAIL` verdict still exits 0 |
| `test_evidence_contract.sh` | published contract vs. produced artifacts, evidence JSON validity, and no credential-shaped strings in evidence |

## The two assertions that matter most

Both encode a guarantee that is otherwise only a comment, and comments do
not fail a build:

- **`promote still blocked by the real gate, not by the LLM verdict.`** A
  `FAIL` review sitting next to unhealthy develop evidence must be rejected
  *for the develop reason*. Without this, someone could later make the LLM
  verdict blocking and nothing would object — quietly handing an LLM
  production release authority, which `NEW_SERVICE_GUIDE.md` §8 forbids.
- **`UNKNOWN: zero alert rules loaded -> exit 3, never HEALTHY.`** A dead
  monitor and a healthy one both report zero active alerts. This asserts
  the checker refuses to call the first one healthy.

## Known gaps

- **No happy-path deploy/promote coverage.** Needs a daemon, an image and
  NGINX. Covered manually, recorded in `platform/compose/README.md`.
- **`shellcheck` is not run.** Not installed on this machine and not worth a
  new dependency yet; `bash -n` catches syntax but not quoting or unused
  variables. Adding it to the CI job is a small, clearly good next step.
- **`run_local_ci.sh` and the security scanners are only syntax-checked.**
  Their real behaviour needs Docker and Trivy.
- **Vault scripts are only syntax-checked.** Testing them needs a live
  Vault; the boundary tests in `platform/vault/README.md` were run by hand.

## 新增的守衛（2026-08-31 / 09-01）

| 套件 | 層 | 守的是什麼 | 親手弄紅過 |
|---|---|---|---|
| `test_image_arch.sh` | 1 | 送到叢集的自建映像檔必須帶有該叢集架構的 manifest | ✅ 合成平台清單的三個控制項 |
| `test_migration_observed.sh` | 3 | 「部署了什麼」與「監控了什麼」必須對得起來 | ✅ 顏色錯置、無人監控的工作負載，還原都經驗證 |

### `PLATFORM_TIERS`：層級由呼叫端明示

```bash
platform/tests/run_all.sh                   # 預設 1,2,3，最嚴格
PLATFORM_TIERS=1 platform/tests/run_all.sh  # 只跑不需要環境的契約層
```

| 層 | 需要 | 缺席時 |
|---|---|---|
| 1 | 無 | — |
| 2 | Docker + 活的 Postgres | **硬失敗**，不是 skip |
| 3 | k3d 叢集 + Prometheus | 大聲 skip，計入標題 |

**永遠不自動偵測。** 自動把「沒有資料庫」降級成 skip，和 2026-08-19 那次 3h55m
憑證中斷長得一模一樣——那正是這條規則要抓的東西。被關掉的層會在結論**之前**印出來，
所以雲端的綠燈不可能被引用成「平台通過」。

### VACUOUS 不是 PASS

空集合會讓「每一個都符合」自動成立。`test_image_arch.sh` 與
`test_migration_observed.sh` 對「沒有東西可檢查」的情況印 `VACUOUS`，不印 PASS——
一行意思是「什麼都沒檢查」的綠燈，正是這些守衛存在的理由。

### macOS↔Linux 可攜性

四個缺陷在 2026-08-31 修掉，全部在真的 GNU coreutils 容器裡驗證，不是推論的：
`stat -f %m`、`mktemp -t name.XXXXXX.ext`、`scutil --get LocalHostName`、
以及 `ingress.sh` 把能力檢查排在參數檢查之前。細節見
[`platform/ci/README.md`](../ci/README.md)。

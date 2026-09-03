---
type: platform-adapter
title: CI 管線（雲端 tier 1 與本機全量）
description: What runs on GitHub Actions versus locally, why the cloud tier is limited, and the BSD-to-GNU portability defects found on 2026-08-31.
tags:
  - ci
  - portability
  - github-actions
timestamp: 2026-09-01T09:53:38+08:00
---

# platform/ci — the build pipeline, and the two places it runs

## What runs where

CI exists in two places that answer different questions. Reading a green result
from one as if it came from the other is the mistake this file exists to prevent.

| | GitHub Actions | `run_local_ci.sh` |
|---|---|---|
| Where | GitHub-hosted `ubuntu-latest` (amd64) | this machine |
| Runs | **tier 1 only** — contracts and static gates | the full build: image, scan, deploy, evidence |
| Needs | nothing but the repo | Docker, the pilot, the platform |
| Answers | "do the contracts still hold?" | "does this pilot still build and deploy?" |

A green GitHub run does **not** mean the platform works. It means the contracts
hold. `run_all.sh` prints which tiers it skipped above its verdict precisely so
that a green line cannot be quoted as more than it is.

## Start here

```bash
platform/ci/run_local_ci.sh                     # defaults to pilots/station2-twin
platform/ci/run_local_ci.sh <pilot-dir> <out>   # or point it somewhere else
```

The defaults derive from the pilot directory rather than naming a pilot three
times. An earlier version hardcoded `station1-hello` into the default path, the
evidence path *and* the image tag, so pointing CI at a different pilot quietly
wrote its artefacts into the wrong pilot's evidence directory.

## Why the cloud tier is only tier 1 (2026-08-31)

Before this date the cloud runner ran every tier, including suites that require
a live Postgres holding the pilot's 6.5M rows. That runner has never had a
database and never will, so those suites could not fail for a real reason — only
for a structural one.

The result: **13 of the last 20 runs red**, and at least six days in which real
failures went unread, because "CI is red" had stopped carrying information.

The fix is not to relax the rule. `run_all.sh` still treats a missing database
as a hard failure on any machine that is supposed to have one. What changed is
that the tier is now **declared by the caller** (`PLATFORM_TIERS`), never
auto-detected — because silently downgrading a missing database to a skip is
indistinguishable from the 3h55m credential outage of 2026-08-19 that the rule
was written to catch.

## Portability: the cloud runner is Linux, this machine is macOS

Four defects were found and fixed on 2026-08-31, all of the same shape — code
that works on BSD userland and fails on GNU:

| Defect | Symptom on Linux |
|---|---|
| `stat -f %m` (BSD mtime) | GNU reads `-f` as *filesystem status*; the output lands in `$(( ))` and dies as `File: unbound variable` |
| `mktemp -t name.XXXXXX.ext` | GNU requires the X's to end the template: `Invalid argument`. macOS does not even substitute them, leaving a literal `XXXXXX` in the name |
| `scutil --get LocalHostName` | macOS-only; elsewhere the expected hostname became the bare `.local` and every README URL was reported wrong |
| capability check before argument check in `ingress.sh` | an unknown target exited 1 ("tailscale is not on PATH") instead of 2 ("Unknown target") |

All four were verified against real GNU coreutils in a container, not reasoned
about. See `platform/tests/` for the guards.

## Files

| File | What it does |
|---|---|
| `run_local_ci.sh` | Full local pipeline for one pilot: build, scan, deploy, write evidence. |
| `pipeline-contract.yml` | The declared shape of a pipeline run; `platform/tests/` checks reality against it. |


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`fetch_gha_status.sh`](fetch_gha_status.sh) | 排程 `gha`，每 30 分鐘 | 把遠端 CI 狀態抓進 `evidence/`，讓板子不必上網才讀得到 | **這是排程抓取不是即時探測**：第一版直接在 `dag.py` 裡呼叫 `gh run list`，於是板子的產生時間變成取決於網路，而 CI 紅了六天沒有人知道——現在紅燈是**證據檔的內容**，不是一次僥倖成功的網路呼叫 |


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到（能力必須是**該列的主詞**）。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`run_local_ci.sh`](run_local_ci.sh) | 本機全量 CI | 跑完整的本機 CI 流程 | 預設值**由 pilot 目錄推導**，不寫死 pilot 名稱——舊版把 `station1-hello` 硬編在路徑、證據路徑與 image tag 三個地方，換 pilot 時會靜默指向錯的東西 |

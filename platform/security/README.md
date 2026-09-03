---
type: platform-adapter
title: 安全掃描 Adapter
description: "Four scanning layers: source (SAST), artifact (Trivy, SBOM, signing), infrastructure (policy), and the running system (DAST)."
tags:
  - security
  - sast
  - dast
  - supply-chain
timestamp: 2026-08-15T19:57:20+08:00
---

# Security Scanning — Container Vulnerabilities, SBOM, Signing, Secret History

Closes items from `Plan.md`'s "尚未完成的主要交付鏈": the container scan
gate and SBOM/Cosign half of "Security gates + registry + artifact
promotion", and the Gitleaks half of "Secret rotation 與 Gitleaks history
scan" (rotation itself remains a separate, not-yet-built item).

## Contract

```text
scan_image.sh    <image:tag> <evidence_dir>   -- Trivy vulnerability gate + SBOM
sign_artifact.sh <file> <evidence_dir>        -- Cosign sign + verify (opt-in, see below)
scan_secrets.sh  [repo_dir] [evidence_dir]    -- Gitleaks full-history scan

```

`scan_image.sh` is wired into `platform/compose/deploy.sh`'s `build`
subcommand: a failed scan means the `:dev` alias is never created, which
transitively blocks `deploy` and `promote` too (both already refuse to run
without that tag) — no separate gate logic needed in either of them.

`scan_secrets.sh` is a standalone script today, run manually/periodically
— not wired into GitHub Actions yet (see "Known Gaps").

## Gate Policy — Why "Fixable Critical/High Only"

Trivy's default full scan against `station1-hello`'s current base image
(`python:3.12-slim`, Debian 13) reports **4 CRITICAL** findings. All four
are in `perl-base` (a transitive OS dependency, not something the pilot's
own code touches) and **all four have no fix available upstream** —
verified by inspecting each finding's `FixedVersion` field, not assumed.

Hard-failing on *any* Critical/High, unfixed or not, would create a
permanent, unfixable block for no actionable reason. So the gate is:

```bash
trivy image <image> --ignore-unfixed --severity CRITICAL,HIGH --exit-code 1

```

This drops the CRITICAL count to 0 for the current image (verified: 5
remaining findings, all MEDIUM/LOW, none blocking) — a gate that's both
**meaningful** and **achievable today**, rather than either toothless or
permanently red.

**Proof the gate has real teeth, not just a policy that happens to always
pass**: scanned `python:3.9-slim` (an older base image, for comparison
only — not used anywhere in this repo) with the identical gate command →
**28 fixable CRITICAL/HIGH findings**, gate exits 1. The gate would catch
a real regression; it isn't just permanently green by construction.

## Evidence: Summary vs. Raw

Trivy's raw JSON output is large — 362KB (gate scan) and 817KB (full scan)
for a single small pilot image, full of CVE descriptions and references
that don't change per-scan. Committing that to git on every build would
bloat the repository for near-zero audit value beyond what a compact
summary already captures. So:

- `evidence/<pilot>/_raw.trivy_{gate,full}_<image>.json` — full Trivy
  output, **gitignored** (regenerable from the image at any time, same
  reasoning as gitignoring `*.tfstate` or the generated NGINX vhost in
  `platform/nginx/`).
- `evidence/<pilot>/trivy_summary_<image>.json` — small, **committed**:

```json
{
  "image": "station1-hello:04d1e68",
  "scanned_at": "2026-08-08T22:52:10Z",
  "gate_policy": "fail on any fixable CRITICAL/HIGH (--ignore-unfixed --severity CRITICAL,HIGH)",
  "gate_result": "PASS",
  "fixable_critical_high_count": 0,
  "fixable_critical_high_ids": [],
  "full_scan_by_severity": { "LOW": 67, "HIGH": 19, "MEDIUM": 60, "UNKNOWN": 28, "CRITICAL": 4 }
}

```

`scan_secrets.sh`'s Gitleaks report is small regardless of outcome (a
clean scan is a 2-byte `[]`), so it's committed as-is under
`evidence/security/gitleaks_<timestamp>.json` with no summary/raw split
needed.

## Verified End-to-End (2026-08-09)

| Check | Result |
|---|---|
| `scan_image.sh station1-hello:<sha>` | `SCAN PASS: 0 fixable CRITICAL/HIGH findings`; summary + raw evidence written |
| Gate actually blocks a vulnerable image | `scan_image.sh python:3.9-slim` (comparison only) → `SCAN FAILED`, exit 1, 28 findings identified by ID |
| Wired into `deploy.sh build` | Ran `platform/compose/deploy.sh build pilots/station1-hello` end-to-end — scan runs automatically between CI and the `:dev` alias step, `:dev` only gets (re)created after a passing scan |
| `scan_secrets.sh` (full history) | `10 commits scanned ... no leaks found`, exit 0, `evidence/security/gitleaks_*.json` contains `[]` |
| Evidence size discipline | Raw Trivy files (362KB/817KB) correctly excluded by `.gitignore` (`git check-ignore -v` confirmed); only the ~400-byte summary and small `build_*.json`/`deploy_*.json` files are tracked |

## SBOM (Software Bill of Materials)

`scan_image.sh`'s step `[3/3]` generates a CycloneDX SBOM via
`trivy image --format cyclonedx`. Same raw/summary split as the vuln
scans: the full SBOM (~190KB even for a minimal Python image) is
gitignored (`evidence/<pilot>/_raw.sbom_*.json`), and a compact summary —
component count, spec version, breakdown by component type, and a SHA-256
checksum of the full SBOM — is committed
(`evidence/<pilot>/sbom_summary_*.json`).

## Image/Artifact Signing (Cosign) — Read This Before Enabling

`platform/security/sign_artifact.sh` signs a file (used here for the SBOM)
with a local key pair (`platform/security/keys/cosign.key` — gitignored;
`cosign.pub` — committed, that's the point of a public key) and verifies
the signature. **This is opt-in, not automatic**: `scan_image.sh` only
signs the SBOM if `SIGN_ARTIFACTS=1` is set. `deploy.sh build` does not set
it by default.

### ⚠️ This publishes a permanent public record

Cosign v3, even for pure key-based signing with no Sigstore/Fulcio
identity flow, publishes an entry to the **public, immutable Sigstore
Rekor transparency log** (`rekor.sigstore.dev`) by default — there is no
CLI flag in this version to opt out (checked; none exists in
`cosign sign-blob --help`). This was discovered mid-session by actually
running it, not by reading documentation first: a test signature was
published to Rekor before its consequences were fully understood. The
user was informed transparently and explicitly chose to accept this
trade-off for this platform going forward — this is not something to
assume extends to other files or other decisions without checking again.

**What's actually exposed per signature**: a SHA-256 hash of the signed
file, the public key fingerprint, a timestamp, and the ECDSA signature —
not the file's content, and no secret material. For an SBOM (a dependency
inventory, not sensitive data), the practical exposure is low. It would be
a different calculation entirely for a file containing anything sensitive.

**This is why signing is opt-in via `SIGN_ARTIFACTS=1`**, not default
`build` behavior: publishing a permanent public record on every routine
local development build (which could happen many times per hour while
iterating) is excessive. Real Cosign usage typically signs at release
time, not on every commit.

### Idempotency — a real bug found and fixed

`sign_artifact.sh` was originally written to skip re-signing if a bundle
file already existed by *name*. That was wrong, and running it twice in a
row against the "same" SBOM proved it: Trivy's CycloneDX output embeds a
fresh `serialNumber`/timestamp on every regeneration, so two SBOM
generations for the *identical* image are not byte-identical. The
name-only check let a stale bundle sit next to genuinely different
content, and verification against the newly-regenerated SBOM correctly
failed ("invalid signature") — confusing, since nothing was actually
tampered with, just regenerated.

**Fixed**: the idempotency check now compares the SHA-256 digest recorded
*inside* the existing bundle against the current file's actual digest.
Digest match → skip re-signing (verified: produces zero new Rekor
entries, `cosign verify-blob` still passes). Digest mismatch → sign again
with the new content (correct — it did change).

**Practical consequence**: because Trivy's SBOM output isn't byte-stable,
`SIGN_ARTIFACTS=1` will create a new Rekor entry on most builds, not just
the first one, even for logically-unchanged dependencies. A canonicalized
SBOM (stripping `serialNumber`/`metadata.timestamp` before signing) would
fix this properly but wasn't built this session — noted below.

### A second bug found: the `.gitignore` blanket `*.pub` rule

The Phase 1 `.gitignore` excluded `*.pub` for defense-in-depth against
committing SSH-style public key files. That rule also caught
`platform/security/keys/cosign.pub` — which is supposed to be committed;
distributing the public key is the entire point of publishing one. Fixed
with an explicit negation exception
(`!platform/security/keys/cosign.pub`), verified via `git add -n` (not
`git check-ignore`'s exit code, which behaves confusingly — but not
incorrectly — when the last-matching pattern is itself a negation).

## Verified End-to-End (2026-08-09)

| Check | Result |
|---|---|
| SBOM generation | 89 components (1 OS, 88 libraries), CycloneDX 1.7, summary + raw evidence written |
| Sign (`SIGN_ARTIFACTS=1`) | `cosign sign-blob` → bundle written, immediately `cosign verify-blob` → `Verified OK` |
| **Tamper detection** | Copied the SBOM, modified one byte of content, verified the *original* bundle against the *modified* file → `Error: failed to verify signature: ... invalid signature`, exit 1. Confirms the mechanism actually detects tampering, not just "ran without erroring" |
| **Idempotency (fixed)** | Signed once, immediately re-ran against the *unchanged* file → correctly skipped re-signing, re-verified the existing bundle, exit 0, **zero new Rekor entries** |
| **Idempotency (bug reproduced before the fix)** | Re-ran `scan_image.sh` (which regenerates the SBOM fresh) with the old name-only check → stale bundle + regenerated content → verify failed. Confirmed root cause via direct digest comparison before fixing |
| `.pub` gitignore fix | `git add -n platform/security/keys/cosign.pub` → confirmed it would be staged (the authoritative check; `git check-ignore -v`'s exit code alone was misleading here) |

## SAST and DAST (2026-08-14)

```bash
platform/security/scan_sast.sh              # source  -> evidence/security/sast_summary_*.json
platform/security/scan_dast.sh              # runtime -> evidence/security/dast_summary_*.json

```

### The hole these fill

Every scanner here before today looked at an **artifact** (Trivy on the
image, SBOM, Cosign) or at **infrastructure** (Checkov/OPA on IaC) or at
**history** (Gitleaks on commits). Nothing looked at the application source,
and nothing looked at the running system.

That leaves two whole classes invisible:

- A SQL injection written today passes every existing gate — the image it
  lands in has no CVEs, the IaC is fine, no secret was committed.
- A missing security header, an exposed version banner, or a reachable debug
  endpoint exists in **no file at all**. It is a property of the deployed
  system, so no amount of source analysis will ever find it.

SAST covers the first. DAST covers the second. They are not redundant.

### Where each one runs

| Gate | Tool | Stage | Blocks on |
|---|---|---|---|
| SAST | Semgrep OSS | `run_local_ci.sh` step 2/6, before build | ERROR severity |
| DAST | OWASP ZAP baseline | after `deploy develop`, before `promote` | MEDIUM and above |

DAST is deliberately **not** in the build pipeline: at build time there is
nothing running to scan. `pipeline-contract.yml` lists it as
`dast_post_deploy` for the same reason.

### Both gates refuse to call an empty scan clean

This is the same principle as `check_health.sh`'s exit 3, and both scanners
needed it for a concrete reason discovered in practice:

- **Semgrep**: `p/shell` and `p/bash` do not exist in the registry (both
  404). A mistyped ruleset makes Semgrep scan **zero files** and still exit
  reporting zero findings — observed exactly that during development. The
  gate now fails when `files_scanned == 0` or any config error appears.
- **ZAP**: an unreachable target produces a report with no alerts, which
  looks identical to a clean one. The gate fails when `urls_examined == 0`.

`platform/tests/test_evidence_contract.sh` additionally asserts that any
recorded PASS actually examined something, so a zero-coverage PASS cannot sit
in `evidence/` looking like assurance.

### Rulesets are pinned, not `--config=auto`

`auto` resolves rules over the network at run time, so the same commit can
pass today and fail tomorrow with nothing in the repo having changed. That
breaks the deterministic feedback these gates exist to provide. Pinned:
`p/security-audit`, `p/secrets`, `p/dockerfile`, `p/owasp-top-ten`,
`p/python`, `p/ci`.

### The DAST threshold was measured, not guessed

Set at **MEDIUM**, not HIGH. A passive baseline scan essentially never emits
HIGH — those come from active attack traffic, which the baseline deliberately
does not send. A HIGH-only gate was tested against a deliberately
header-less page producing three MEDIUM findings and **still reported PASS**.
A gate that passes that target is not a gate. Override per-target with
`DAST_FAIL_ON`.

Active scanning (`zap-full-scan`) genuinely attacks the target and is
deliberately not wired in: that needs an explicit decision about what may be
attacked and when.

### Verified — both gates proven in both directions

| Check | Result |
|---|---|
| SAST on current codebase | PASS, 121 files, 0 ERROR |
| SAST on a deliberately vulnerable file | **FAIL**, exit 1 — 7 ERRORs across command injection, SQL injection, `eval` injection |
| SAST with a mistyped ruleset | **FAIL** on scan-integrity, not a false PASS |
| DAST on the develop vhost | PASS, 3 URLs, 0 MEDIUM+ |
| DAST on a header-less page | **FAIL**, exit 1 — 3 blocking MEDIUM findings |
| DAST against an unreachable target | **FAIL** with a reachability error, not a clean report |

### Three real findings on the first run

Adding these gates immediately produced fixes, which is the point:

1. **GitHub Actions shell injection** — `${{ }}` context values interpolated
   directly into a `run:` script body. GitHub substitutes those *before* the
   shell runs, so any value containing shell metacharacters becomes code.
   Fixed by passing through `env:`. The same step also built JSON by
   `sed`-escaping only double quotes, so an attacker-controlled commit
   message containing a backslash produced invalid JSON — now built with
   python's `json` module.
2. **`curl | bash` installing tfsec from a mutable `master` ref.** Three
   problems in one step: unverified remote code execution, a mutable source,
   and a *deprecated* tool duplicating a capability the platform already has.
   Replaced with `trivy config` from a version-pinned action.
3. **NGINX leaked its version** in the `Server` header, and lacked a
   Cross-Origin-Resource-Policy header. Neither exists in any source file —
   the version banner is simply nginx's default. Only a scanner looking at
   the running system finds these. ZAP also rejected `same-site` as
   insufficient for CORP, which pushed the value to `same-origin` — the
   stricter and, for a service never embedded cross-origin, the correct one.

### Installation

- **Semgrep**: `uv tool install semgrep` — not `pip install`, keeping it off
  the host python, per the isolation rule this platform follows everywhere.
- **ZAP**: `docker pull --platform linux/arm64 zaproxy/zap-stable`. Both
  tools are ARM-native; no x86 emulation.

### Known gaps in SAST/DAST specifically

- **16 Semgrep WARNINGs are unaddressed.** Non-blocking by policy and
  recorded in every summary, but nobody has triaged them. A growing warning
  count that nobody reads eventually makes the ERROR tier meaningless too.
- **No active DAST.** Baseline only — passive rules plus a spider. Real
  injection and authentication flaws in a running app need
  `zap-full-scan`, which sends attack traffic.
- **DAST covers one endpoint.** `station1-hello` exposes a handful of paths
  and no authenticated area, so the spider has almost nothing to crawl.
  Coverage numbers here say more about the pilot than about the scanner.
- **No DAST scan of the production-like vhost.** Only develop is scanned.
  Blue/green means the two can genuinely differ.
- **Staleness is reported, not enforced.** `promote` warns when the DAST
  result is over 24h old but still lets the release proceed.
- **Neither gate runs in GitHub Actions yet.** Both run locally and in
  `run_local_ci.sh`; the CI workflow only covers IaC and platform tests.

## Known Gaps / Next Steps

- **SBOM signing isn't content-stable.** See "Idempotency" above — a
  canonicalized/deterministic SBOM (or signing a stable derivative like
  just the sorted component list + versions, not Trivy's raw output)
  would let genuinely-unchanged builds skip signing entirely instead of
  re-publishing to Rekor on every build.
- ~~No image signing, only SBOM signing~~ **Done** — see
  `platform/compose/README.md`'s "Registry Promotion (GHCR)" and
  `deploy.sh push`'s `SIGN_ARTIFACTS=1` gate, which runs `cosign sign`
  against the pushed digest now that GHCR provides somewhere to push a
  signed image+signature to.
- **`scan_secrets.sh` isn't wired into CI.** It's a standalone script,
  run manually. Unlike `scan_image.sh` (naturally scoped to one pilot's
  build), a secret scan is repo-wide and doesn't obviously belong to any
  single existing GitHub Actions trigger path
  (`.github/workflows/iac-validate.yml` only fires on `platform/iac/**`
  changes) — needs its own workflow if it should run automatically.
- **No dependency/SCA scanning beyond Trivy's built-in Python package
  detection.** `docs/Plan-detail.md`'s security matrix lists SAST/SCA as
  separate categories from container scanning; only the container-image
  half is covered here.
- **Secret rotation is still not built.** Vault (`platform/vault/`) holds
  a static copy of `GITHUB_TOKEN`; nothing rotates the underlying PAT or
  updates Vault automatically when it's rotated.

---

## DAST 的盲區，變成一個看得見的數字（2026-09-01）

`scan_dast.sh` 回報 `gate_result: PASS`、HIGH=0 MEDIUM=0。那句話是真的，
也非常誤導——因為它沒說它看了多少。

ZAP baseline ＝ **被動規則 ＋ GET spider**，而 station2-twin 提供的是
**沒有任何連結的 JSON API**。spider 找得到的只有 health 與 metrics 那幾條，
而 `POST /twin/<asset>/observation`——這個系統唯一的寫入路徑——
**GET spider 在原理上就碰不到**。

實測：

```
python3 platform/security/dast_coverage.py
  4 of 10 routes reachable (40%)
```

所以「DAST PASS」目前的真正意思是**「spider 撞到的那 4 條是乾淨的」**，
不是「這個服務是乾淨的」，而在此之前沒有任何地方說明它是哪一個意思。
這是這個平台最老的缺陷形狀穿上資安的衣服：**一條綠燈，實際內容是
「幾乎什麼都沒檢查」**。VACUOUS 不是 PASS。

### 三個原因分開算，因為處置不同

| 原因 | 數量 | 該做什麼 |
|---|---:|---|
| `write` | 1 | ZAP baseline 是 GET，永遠碰不到。需要 API profile，**且必須對拋棄式副本掃** |
| `parameterised` | 3 | 路徑有 spider 猜不到的參數（asset id、縣市名），要餵範例值 |
| `unlinked` | 2 | 原則上掃得到，但 JSON API 沒有連結可循 |

合併成一個「6 條沒掃到」會把最重要的那一條埋掉。

### 路由是從原始碼解析出來的，不是手維護的清單

手維護的清單在第一次有人新增端點時就過期，而**建立在過期清單上的覆蓋率報告
會回報「完整覆蓋」一個已經長大的表面**。從 dispatcher 解析，新端點下一次執行
就會自己變成一條沒掃到的路由，不需要任何人記得更新。

解析器對這個 pilot 的 dispatcher 是特化的，這是明示接受的取捨：
**對存在的程式碼精確，勝過對不存在的程式碼近似**。
防止它悄悄腐爛的是 `MIN_EXPECTED_ROUTES` ——樣式一旦不再匹配，
它會**非零退出**，而不是回報一個從 0 條路由算出來的舒服的「0 個缺口」。

### 為什麼不設告警

覆蓋率只在有人新增端點時才變。對一個單調的值設告警，結果只會是
**永遠響或永遠不響**——與健康彙總涵蓋率同一個理由。它的位置在板面上
（三線階段燈號，面板 105–107），不在 Alertmanager。

### 還沒做：實際去掃那條寫入路徑

需要 API profile（餵 OpenAPI 或 context file）。**設計上已經定案的一點：
絕對不對現行實例掃。** 那個端點吃 JSON body 並寫進 650 萬列的資料表，
對它送攻擊流量會污染這個平台存在的全部意義——可信任的資料。
做法必須是拋棄式副本（一次性 postgres ＋ app ＋ migrations，掃完即銷毀），
並且腳本要**拒絕**對任何不是它自己啟動的目標執行。

這也是 `scan_dast.sh` 開頭早就寫下的規則：主動掃描「needs an explicit
decision about what may be attacked and when」。上面那段就是那個決定。

### 守衛

`platform/tests/test_dast_coverage.sh`（tier 1，17 項）。控制組全部合成：
偽造一個 dispatcher、給它長一條新路由、餵一個解析不了的 dispatcher。

最重要的一條控制是**「新增路由必須讓覆蓋率下降」**（0.4444 → 0.4）——
一個不會下降的覆蓋率數字是裝飾品。

突變測試（四個突變，全部被抓，還原後逐位元相同）：

| 突變 | 結果 |
|---|---|
| 寫入端點不再有自己的原因分類 | CAUGHT |
| 拿掉 `MIN_EXPECTED_ROUTES` 下限 | CAUGHT |
| 參數化路由被當成可達 | CAUGHT（第一輪 **MISSED**，見下） |
| 參數化路由根本不解析 | CAUGHT |

第三個突變第一輪**沒被抓到**：拿掉參數化分支之後，那些路由會落到
`unlinked`，仍然是不可達，所以覆蓋率數字一模一樣、只有診斷是錯的。
**一份數字在自己的推理被拿掉之後依然不變的報告，是沒有人能據以行動的報告**
——`unlinked` 是「加個連結」，`parameterised` 是「餵個範例 id」，
不是同一個指令。補上原因分佈的斷言之後才抓到。


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到。
**只寫一句「見某腳本」不算描述**——那句話說不出何時跑、做什麼、保證什麼。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`scan_sast.sh`](scan_sast.sh) | CI / 排程 | Semgrep OSS 讀原始碼 | 補上真正的洞：其他掃描看的是**產物**（Trivy／SBOM／Cosign）、**基礎設施**（Checkov／OPA）或**歷史**（Gitleaks），沒有一個讀原始碼 |
| [`scan_dast.sh`](scan_dast.sh) | CI / 排程 | OWASP ZAP baseline 對執行中的服務掃 | 抓 SAST 結構上看不到的：只在執行期才存在的東西（缺少的安全標頭、實際的錯誤回應） |
| [`dast_coverage.py`](dast_coverage.py) | 排程 `dastcov` | 回報 DAST **沒有看**哪些路由 | ZAP baseline 是 GET 爬蟲，碰不到寫入端點——實測十條路由只涵蓋四條。**PASS 的涵蓋範圍必須是可見的** |
| [`scan_secrets.sh`](scan_secrets.sh) | CI / 排程 | Gitleaks 掃**完整 commit 歷史**（`--all`） | 不只掃工作目錄：commit 過再刪掉的 secret 仍然外洩，且在 repo 存在期間都取得回來 |
| [`sign_artifact.sh`](sign_artifact.sh) | build 後 | Cosign 簽章與驗章 | 金鑰式簽章（不走 Sigstore keyless），不需要 OIDC；但 Cosign v3 預設仍會寫 Rekor 透明日誌條目 |
| [`redaction_check.py`](redaction_check.py) | 排程 | 量化 v1 遮蔽**實際抓到多少** | 遮蔽是緩解不是保證；這支把「抓到幾成」變成數字，而不是一句自我宣稱 |


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到（能力必須是**該列的主詞**）。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`scan_image.sh`](scan_image.sh) | build 後 | Trivy 容器映像漏洞閘門 | **只對「可修的 Critical/High」硬性失敗**（`--ignore-unfixed`）。這是查證過的推理不是猜測：對無修補可用的漏洞硬擋，只會訓練人繞過閘門 |

---
type: platform-adapter
title: 文件標準 Adapter（OKF）
description: "Why this repo's markdown conforms to Open Knowledge Format v0.1, what that does and does not buy, and the checker that stops it drifting."
tags:
  - documentation
  - okf
  - knowledge
  - interoperability
---

# Documentation Standard — OKF v0.1

```bash
platform/docs/okf_check.py            # conformance report
platform/docs/okf_check.py --strict   # also fail on house conventions

```

Enforced by `platform/tests/test_static.sh`, so it fails the build rather
than decaying quietly.

## The problem this addresses

Every person, every agent, and every knowledge base uses a different
document format. Google Cloud's framing of the same problem, from the
[OKF announcement](https://cloud.google.com/blog/products/data-analytics/how-the-open-knowledge-format-can-improve-data-sharing):

> "Every agent builder is solving the same context-assembly problem from
> scratch, every catalog vendor is reinventing the same data models, and the
> knowledge itself is locked behind whichever surface created it."

That is directly this environment's situation: several AI CLIs, a shared
capabilities layer at `~/Apps/AIS/capabilities/`, and documentation that all
of them need to read.

Worth noting that `AIS/capabilities/registry.yaml` — with its
`owner / kind / entry / verify` per capability — is already a hand-rolled
version of the same idea, built independently to solve cross-agent sharing.
The need was real before the spec existed.

## Why adopt a v0.1 spec, which is normally a bad idea

[OKF v0.1](https://okf.md/spec/) was published on 2026-06-12. Adopting a
point-one specification usually means betting on churn.

The reason it is worth it here is an asymmetry: **the conformance surface is
one field.** The spec requires only that every non-reserved `.md` has a
parseable YAML frontmatter block containing a non-empty `type`. Everything
else — `title`, `description`, `tags`, `timestamp`, linking, `index.md` — is
optional guidance, and consumers "must not reject bundles for missing
optional fields, unknown types, broken links, or absent index files".

So the cost of adopting and the cost of later abandoning are both close to
zero, while the cost of waiting is a year of documents that no agent can
traverse. When both directions are cheap, waiting is the expensive choice.

## The spec already encodes "logs do not need a format"

Reserved filenames `index.md` and `log.md` must carry **no** frontmatter.
A chronological log is not a concept document and the spec declines to dress
it as one — which is the same distinction anyone maintaining these files
arrives at independently. The checker enforces that direction too: putting
frontmatter *on* a reserved file is an error.

## What OKF does not do

**It is packaging, not content quality.** Frontmatter does not make a badly
shaped document good. Content shape is
[Diátaxis](https://diataxis.fr/)'s concern — tutorial, how-to, reference,
explanation — and the two are orthogonal and stack cleanly.

**It exposes a real problem in this repo rather than fixing it.** The
`platform/*/README.md` files each mix reference, design rationale and
verification evidence in one document. Convenient for a maintainer reading
top to bottom; poor for an agent, which retrieves *fragments*. OKF's model
is one concept per file, so full alignment would mean splitting these. That
has not been done, and adding frontmatter did not address it — noted here
rather than quietly left as an implied win.

## This repo's type taxonomy

Type values are explicitly not registered centrally by the spec; teams
choose their own. Ours is kept small on purpose — a taxonomy nobody can hold
in their head gets applied inconsistently:

| `type` | Used for |
|---|---|
| `overview` | entry point for the repo or a directory |
| `platform-adapter` | a `platform/` capability: what it does and why |
| `runbook` | a procedure a human executes |
| `how-to` | task-oriented instructions |
| `reference` | lookup material |
| `explanation` | design rationale and decisions |
| `plan` | intended work, not yet true |
| `checklist` | things to verify |
| `review` | a point-in-time assessment |

An unknown type is a **warning, never an error** — the spec requires
consumers to handle unknown types gracefully, so failing on one would be
stricter than the standard and would punish a legitimate new concept kind.

## Field conventions

- **`description` is hand-written.** It is what an agent reads to decide
  whether to open the file at all, so a generated one ("Documentation for
  platform/vault") actively costs retrieval quality: it looks filled in while
  carrying no signal.
- **`timestamp` is derived from git**, not typed by hand. A hand-written
  timestamp is a claim that rots the moment someone edits without updating
  it. A derived one cannot lie.

## Verified

| Check | Result |
|---|---|
| conformance before adoption | 0/29 |
| conformance after | **29/29 (100%)** |
| checker fails on a missing `type` | pass — verified by removing one on purpose |
| checker fails on frontmatter in a reserved file | enforced |
| build gate wired | `platform/tests/test_static.sh` |

## Known gaps

- **No `index.md` files.** Optional in the spec, and they would turn the
  bundle into a navigable graph, but a hand-maintained index goes stale. If
  added, it should be generated.
  **That instinct turned out to be the load-bearing one**, and it now has a
  guard: `doc_freshness.py` requires every tracked rendered page under `docs/`
  to be either generated (with its generator's own check passing) or recorded
  as deliberately hand-maintained with a one-line reason. Two pages that were
  neither had already gone wrong — one told management that data governance
  and process visualisation were "almost empty" nine days after both were
  built. **Reachability could not have caught either; both were linked.**
- ~~**Cross-links are not yet used as a graph.**~~ **Closed 2026-09-02.**
  `doc_graph.py` walks those edges from `README.md` and reports what is
  reachable, orphaned, or broken; `--tree` renders the graph with each
  document's age, so the tree is a maintenance instrument rather than only a
  gate. It found five orphans on the first run, one of which was a second and
  stale copy of the capability index. Guarded by
  `platform/tests/test_doc_graph.sh`.
- **The mixed-shape README problem above is unaddressed.**
- **`resource` is unused.** It would matter once concepts point at real
  assets (a table, an endpoint) rather than describing platform components.
- **Only this repo.** `~/Apps/AIS/capabilities/` and the memory directory are
  the other knowledge surfaces and are not covered.


---

## 能力表（何時跑／做什麼／保證什麼）

**這張表是給三種讀者的**：人要知道跑哪一支，agent 要能不讀原始碼就知道用途，
`platform/docs/capability_graph.py` 要能驗證每支能力都被描述到。

| 能力 | 什麼時候跑 | 做什麼 | 保證什麼 |
|---|---|---|---|
| [`doc_graph.py`](doc_graph.py) | 排程／CI | 從 `README.md` 走真正的連結圖 | 回答「孤兒／斷鏈／可達」。`--tree` 附每份文件幾天沒動過。**證不到內容還是不是真的** |
| [`doc_freshness.py`](doc_freshness.py) | 排程／CI | 每份追蹤中的渲染頁面：產生式，還是有人用手承諾 | 產生式的要通過它自己的 `--check`；手工維護的必須具名寫下理由。**第三份 System-State.html 沒辦法安靜地被加進來** |
| [`capability_graph.py`](capability_graph.py) | 排程／CI | 每支能力是否被某份**可達**文件描述 | **被程式呼叫不等於找得到**。內部元件可指向入口，**但那個入口本身必須被描述**——少了這半，豁免清單就是藏東西的地方 |
| [`duplicate_check.py`](duplicate_check.py) | 排程／CI | 有沒有兩份東西在講同一件事 | 正規化後**完全比對**，刻意不做相似度評分——誤報是檢查被靜音的方式。「同一產物兩個生產者」只報告不判失敗 |
| [`decisions.py`](decisions.py) | 排程／CI | 驗證決策紀錄並產生 `docs/decisions/index.md` | **每個帶量測的宣稱都附重跑指令，而那指令必須指向存在的東西**——指向六週前改名腳本的 `rerun:` 比沒有更糟 |
| [`context_cost.sh`](context_cost.sh) | 需要時 | agent 讀完這個平台的證據要花多少 token | 讓「給 AI 看的產物」的成本是數字而不是感覺 |
| [`okf_check.py`](okf_check.py) | 排程／CI | OKF v0.1 frontmatter 一致性 | 每份文件都帶得走：type／title／description／tags 齊全且合法 |

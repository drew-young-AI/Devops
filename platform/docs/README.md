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
- **Cross-links are not yet used as a graph.** OKF treats markdown links
  between concepts as edges; these documents link by path but nothing
  consumes that structure yet.
- **The mixed-shape README problem above is unaddressed.**
- **`resource` is unused.** It would matter once concepts point at real
  assets (a table, an endpoint) rather than describing platform components.
- **Only this repo.** `~/Apps/AIS/capabilities/` and the memory directory are
  the other knowledge surfaces and are not covered.

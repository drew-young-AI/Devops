---
type: platform-adapter
title: LLM 複審 Adapter
description: Local MLX review that produces LLM-generated evidence and never human acceptance, with the two mechanisms that enforce it.
tags:
  - llm
  - review
  - evidence
timestamp: 2026-08-15T19:57:48+08:00
---
# LLM Review Adapter — Station 5 (MLX automation integration)

Implements `docs/Plan-detail.md` Station 5. The local MLX endpoint
(`127.0.0.1:9000`) reads the deterministic evidence this platform already
produces for a commit and writes back a structured review as
`evidence/<pilot>/llm_review_<sha>_<ts>.json`.

```bash
platform/llm-review/review.sh pilots/station1-hello 6a54ff3
```

## The one rule this adapter exists to respect

Station 5's own wording: **「產出 `LLM-generated evidence`，不產出 Human
Acceptance」**. `NEW_SERVICE_GUIDE.md` §8: LLM 可以執行測試、diff review、
scan、報告與低風險診斷，但不能代替人類進行 production release approval.

These are not in tension — they operate at different layers:

```text
build -> CI -> develop deploy -> smoke test -> LLM review  -> human types PROMOTE
                                               (evidence)     (acceptance)
```

The LLM makes the human's decision better-informed. It does not make the
decision. Two concrete mechanisms enforce that, rather than leaving it as a
comment nobody reads:

1. **The verdict never affects `review.sh`'s exit code.** `FAIL` exits 0,
   exactly like `PASS`. If the verdict set the exit code, someone would
   eventually put this in a `set -e` pipeline and the LLM would silently
   acquire blocking authority over releases. The exit code answers only
   "did the review mechanism work" (0 = yes, 2 = degraded, 1 = caller error).
2. **`deploy.sh promote` displays the review, then still asks the human.**
   A `FAIL` verdict prints in full and the `Type PROMOTE to confirm` prompt
   appears anyway. See `show_llm_review()` in `platform/compose/deploy.sh`.

## What it reads

Fixed order, fixed formatting — that ordering *is* the contract, because it
determines `inputs_digest`:

| Source | File |
|---|---|
| Build metadata (image digest, timestamps) | `evidence/<pilot>/build_<sha>.json` |
| Container vulnerability scan + gate result | `evidence/<pilot>/trivy_summary_*_<sha>.json` |
| SBOM summary | `evidence/<pilot>/sbom_summary_*_<sha>.json` |
| Develop deployment health | `evidence/<pilot>/deploy_develop_<sha>.json` |
| Code change | `git diff <sha>^ <sha> -- <pilot_dir>`, capped at 20 000 chars |

Missing sources are passed through as `(not present)` rather than skipped —
the model is told what it wasn't given, and `reproducibility.sources_present`
records it. Diff truncation is recorded as `diff_truncated`, never silent.

**No secret ever enters the prompt.** Inputs are this repo's own
`evidence/*.json` (which by contract hold no secret values — see
`platform/vault/README.md`) plus a diff of the pilot directory. The endpoint
is `127.0.0.1` only, so nothing leaves the machine — the same local-only
boundary `docs/Plan-detail.md` draws around MLX.

## Determinism

`temperature=0`, `top_p=1`, thinking disabled by default, and the exact
prompt is hashed into `reproducibility.inputs_digest_sha256`. That hash is
what makes determinism *checkable after the fact* instead of assumed: two
review files with the same `inputs_digest` and different verdicts is a
determinism failure you can detect by comparing artifacts.

**Measured, not assumed** — six runs against `station1-hello` @ `6a54ff3`,
same `inputs_digest` `a73c671c…`, all six produced a byte-identical
verdict + summary + findings payload (`CONCERN`, sha256 of the normalized
core = `a60564d6553720cb…`). This satisfies the deterministic-feedback
requirement; a run whose `inputs_digest` differs is a different question and
its answer is not comparable.

Thinking mode (`LLM_REVIEW_THINKING=1`) is off by default. Qwen3.6-35B-A3B
is a reasoning model: with thinking on it spends most of the token budget in
the `reasoning` field, and if the budget runs out it returns an **empty
`content`** — a review that produced nothing while looking like a successful
HTTP 200. That failure has its own status (`DEGRADED_NO_CONTENT`) precisely
because it was observed, not theorized. Leave thinking off unless you are
prepared to raise `max_tokens` and re-verify determinism.

## Degraded modes — all five tested for real

Station 5 requires validating "LLM unavailable、timeout、錯誤輸出與人工
review 路徑". Every one of these was triggered deliberately (three via a
stub HTTP endpoint that returns deliberately bad output), not reasoned about:

| Injected condition | `status` | Exit |
|---|---|---|
| Endpoint down (`MLX_ENDPOINT` → dead port) | `DEGRADED_UNAVAILABLE` | 2 |
| `MLX_TIMEOUT=1` against a ~11 s real call | `DEGRADED_TIMEOUT` | 2 |
| Model replies with prose, not JSON | `DEGRADED_UNPARSEABLE_VERDICT` | 2 |
| Model replies with JSON but `verdict:"LGTM"` | `DEGRADED_UNPARSEABLE_VERDICT` | 2 |
| Model replies with empty `content` | `DEGRADED_NO_CONTENT` | 2 |

**A degraded run still writes an evidence file.** A review that did not
happen must leave a trace — silence is indistinguishable from "reviewed and
fine", and that ambiguity is what would rot this into security theatre. The
fallback path is unchanged and was always required: human review.

### Two real bugs this testing found

Both would have been invisible to code review, and both are the reason the
degraded modes were injected rather than assumed:

- **Timeouts were misfiled as `TRANSPORT_ERROR`.** The handler used
  `except TimeoutError`, but this repo's scripts run on the system
  `python3` = **3.9.6**, where `socket.timeout` is a plain `OSError`
  subclass and *not* an alias of `TimeoutError` (that only became true in
  3.10). Fixed by catching `socket.timeout` explicitly.
- **Same-second runs silently overwrote each other.** The filename used
  second-resolution timestamps; three runs inside one second all resolved to
  one path. Evidence that can be clobbered is not evidence — now suffixed
  (`…Z-2.json`) and never overwritten.

- **`deploy.sh promote` aborted when no review existed.** `show_llm_review`'s
  `ls | tail -1` fails under `set -euo pipefail` when the glob matches
  nothing — the *common* case, since the review is optional. An advisory
  display would have killed the release path it was meant to inform. Fixed
  with `|| true`; verified by running the function under
  `bash -euo pipefail` in both the present and absent cases.

## Known gaps / next steps

- **Advisory only, by design — but nothing yet requires a review to exist.**
  `promote` prints "No LLM review evidence for sha=…" and proceeds. Making
  the *presence* of a review mandatory (while keeping its verdict advisory)
  would be a defensible tightening; it is deliberately not done yet, because
  it changes the release path and that needs a human decision, not a
  unilateral one.
- **Only tested against `station1-hello`.** The adapter is pilot-agnostic
  (it takes a pilot dir), but "works for a second service" is unproven until
  a second service exists.
- **The review quality itself is not benchmarked.** Determinism is measured;
  usefulness is not. There is no regression set of known-bad commits that the
  model is checked against, so "the model would catch a real defect" is
  currently `UNVERIFIED`. Building that evaluation set is the natural Station 5
  follow-up and aligns with the evaluation/regression-gate step already listed
  in `docs/Plan-detail.md`'s LLMOps sequence.
- **No cost/latency dashboard.** Each review is a ~11 s local call; nothing
  records latency trends into Prometheus yet.

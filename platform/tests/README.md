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

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

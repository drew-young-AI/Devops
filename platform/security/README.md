# Security Scanning — Container Vulnerabilities + Git Secret History

Closes two items from `Plan.md`'s "尚未完成的主要交付鏈": the container
scan half of "Security gates + registry + artifact promotion", and the
Gitleaks half of "Secret rotation 與 Gitleaks history scan" (rotation
itself remains a separate, not-yet-built item).

## Contract

```text
scan_image.sh   <image:tag> <evidence_dir>   -- Trivy vulnerability gate
scan_secrets.sh [repo_dir] [evidence_dir]    -- Gitleaks full-history scan
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

## Known Gaps / Next Steps

- **No SBOM generation.** `platform/README.md`'s original plan for this
  directory mentioned SBOM (Software Bill of Materials) — not built yet.
  Trivy can generate one (`trivy image --format cyclonedx`) as a follow-up.
- **No image signing (Cosign).** Also mentioned in the original plan, not
  built. Would matter more once there's an actual registry to push signed
  images to (`Plan.md`'s still-open "Registry promotion 與 immutable
  artifact flow").
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

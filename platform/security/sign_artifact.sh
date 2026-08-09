#!/usr/bin/env bash
# Cosign sign + verify for a build artifact (used for the SBOM today; any
# file works). Key-based signing (platform/security/keys/), not Sigstore
# keyless -- no OIDC identity flow needed, but Cosign v3 still publishes a
# transparency-log (Rekor) entry by default even for key-based signing.
#
# THIS IS A PUBLIC, PERMANENT ACTION: every signature this script produces
# is recorded in the public, immutable Sigstore Rekor log
# (rekor.sigstore.dev) -- a SHA-256 hash of the signed file, the public key
# fingerprint, the signature bytes, and a timestamp. Not the file content
# itself, and no secret material, but it cannot be deleted afterward. The
# user explicitly accepted this trade-off for this platform (see
# platform/security/README.md "Cosign / Rekor" section) -- don't assume
# that consent extends to signing arbitrary other files without checking.
#
# Usage:
#   sign_artifact.sh <file> <evidence_dir>
#
# Exit code: 0 if signed and verified successfully, 1 otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILE="${1:?Usage: sign_artifact.sh <file> <evidence_dir>}"
EVIDENCE_DIR="${2:?Usage: sign_artifact.sh <file> <evidence_dir>}"
KEY="$SCRIPT_DIR/keys/cosign.key"
PUBKEY="$SCRIPT_DIR/keys/cosign.pub"

if ! command -v cosign >/dev/null 2>&1; then
  echo "cosign not found. Install with: brew install cosign" >&2
  exit 1
fi
if [ ! -f "$KEY" ] || [ ! -f "$PUBKEY" ]; then
  echo "No signing key at $KEY -- generate one first with:" >&2
  echo "  cd $SCRIPT_DIR/keys && COSIGN_PASSWORD='' cosign generate-key-pair" >&2
  exit 1
fi

mkdir -p "$EVIDENCE_DIR"
# Strip a leading "_raw." if present: the bundle is a small, meaningful
# derived record meant to be committed (unlike the "_raw.*" source files
# this repo gitignores -- see platform/security/README.md), so it must
# not accidentally match the `evidence/*/_raw.*` gitignore globs.
BASENAME="$(basename "$FILE")"
BASENAME="${BASENAME#_raw.}"
BUNDLE_FILE="$EVIDENCE_DIR/${BASENAME}.cosign-bundle.json"

if [ -f "$BUNDLE_FILE" ]; then
  # Compare the digest recorded in the existing bundle against the file's
  # CURRENT content, not just "does a bundle file exist by this name" --
  # verified this distinction matters: Trivy's CycloneDX output embeds a
  # fresh serialNumber/timestamp on every regeneration, so re-running SBOM
  # generation for the identical image produces byte-different output.
  # A name-only check would either skip-with-stale-bundle (silently wrong)
  # or hard-fail verify (confusing, looks like tampering when it's just a
  # routine regeneration).
  recorded_digest="$(python3 -c "import json; print(json.load(open('$BUNDLE_FILE'))['messageSignature']['messageDigest']['digest'])" 2>/dev/null || echo "")"
  current_digest="$(python3 -c "import base64,hashlib; print(base64.b64encode(hashlib.sha256(open('$FILE','rb').read()).digest()).decode())")"

  if [ -n "$recorded_digest" ] && [ "$recorded_digest" = "$current_digest" ]; then
    echo "=== [sign] $FILE ==="
    echo "Content unchanged since last signing (digest match) -- skipping re-sign"
    echo "to avoid a redundant public Rekor entry. Verifying existing bundle..."
    echo ""
    echo "=== [verify] ==="
    cosign verify-blob --key "$PUBKEY" --bundle "$BUNDLE_FILE" "$FILE"
    echo "VERIFY PASS"
    echo "artifact=$BUNDLE_FILE"
    exit 0
  else
    echo "=== [sign] $FILE ==="
    echo "Existing bundle's recorded digest doesn't match the current file"
    echo "content (expected if this SBOM was regenerated -- CycloneDX output"
    echo "isn't byte-stable between runs). Re-signing with fresh content."
    echo ""
  fi
fi

echo "=== [sign] $FILE ==="
echo "NOTE: this publishes a hash+signature+timestamp record to the public," >&2
echo "permanent Sigstore Rekor transparency log. See this script's header." >&2

COSIGN_PASSWORD="" cosign sign-blob \
  --key "$KEY" \
  --bundle "$BUNDLE_FILE" \
  --use-signing-config=false \
  --yes \
  "$FILE"

echo ""
echo "=== [verify] ==="
if cosign verify-blob \
  --key "$PUBKEY" \
  --bundle "$BUNDLE_FILE" \
  "$FILE"; then
  echo "VERIFY PASS"
  echo "artifact=$BUNDLE_FILE"
  exit 0
else
  echo "VERIFY FAILED -- signature/bundle does not match the file" >&2
  exit 1
fi

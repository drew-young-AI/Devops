#!/usr/bin/env bash
# Generate a locally-trusted TLS certificate for the DevOps platform's NGINX adapter.
# Uses mkcert (https://github.com/FiloSottile/mkcert) so the certificate is trusted by
# the local browser/OS trust store without a manual "unsafe site" click-through.
#
# Usage:
#   platform/nginx/scripts/generate_local_certs.sh
#
# Idempotent: safe to re-run. Existing cert/key are overwritten with a fresh pair.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="${SCRIPT_DIR}/../certs"
DOMAIN="devops.local"
CERT_FILE="${CERT_DIR}/devops.local.crt"
KEY_FILE="${CERT_DIR}/devops.local.key"

if ! command -v mkcert >/dev/null 2>&1; then
  echo "[1/4] mkcert not found. Install with: brew install mkcert nss" >&2
  exit 1
fi

echo "[1/4] Ensuring mkcert local CA is installed in the system trust store..."
if ! mkcert -install; then
  echo "    -> Skipped: system trust store install needs an interactive sudo" >&2
  echo "       password (macOS Keychain), which this script cannot supply" >&2
  echo "       non-interactively. The certificate below is still fully" >&2
  echo "       functional for TLS; browsers/curl will just flag it as" >&2
  echo "       untrusted until you run 'mkcert -install' yourself once." >&2
fi

mkdir -p "${CERT_DIR}"

echo "[2/4] Generating certificate for ${DOMAIN}, localhost, 127.0.0.1, ::1 ..."
mkcert \
  -cert-file "${CERT_FILE}" \
  -key-file "${KEY_FILE}" \
  "${DOMAIN}" localhost 127.0.0.1 ::1

echo "[3/4] Restricting private key permissions..."
chmod 600 "${KEY_FILE}"
chmod 644 "${CERT_FILE}"

echo "[4/4] Done."
echo "  Certificate: ${CERT_FILE}"
echo "  Private key: ${KEY_FILE} (not committed to Git — see .gitignore)"
echo ""
echo "Add to /etc/hosts if not already present:"
echo "  127.0.0.1 ${DOMAIN}"

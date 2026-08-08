#!/usr/bin/env bash
# One-time Vault initialization + unseal for local development.
#
# Produces unseal keys and a root token -- both are the master keys to
# every secret this Vault will ever hold. This script writes them to
# platform/vault/.init-output.json, which is gitignored (see .gitignore:
# "Vault init output"). That file is NOT a substitute for a real secret
# manager -- move its contents to a password manager and delete the file
# once you've done so. This script only exists to make local dev/testing
# reproducible; a real deployment would use auto-unseal (cloud KMS) and
# never write the root token to disk at all.
#
# Safe to re-run: if already initialized, skips straight to unseal (using
# the keys already on disk) instead of re-initializing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INIT_FILE="$VAULT_DIR/.init-output.json"
CONTAINER="vault-vault-1"

vault_exec() {
  # VAULT_ADDR is baked into the container's own environment (compose.yaml)
  # so no -e override is needed here.
  docker exec "$CONTAINER" vault "$@"
}

status_json="$(vault_exec status -format=json 2>/dev/null || true)"
initialized="$(echo "$status_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("initialized", False))' 2>/dev/null || echo False)"

if [ "$initialized" != "True" ]; then
  echo "=== Initializing Vault (5 key shares, threshold 3) ==="
  vault_exec operator init -key-shares=5 -key-threshold=3 -format=json > "$INIT_FILE"
  chmod 600 "$INIT_FILE"
  echo "Wrote unseal keys + root token to $INIT_FILE (chmod 600, gitignored)."
  echo "MOVE THIS TO A PASSWORD MANAGER. This file is the master key to everything."
else
  echo "Already initialized -- reusing keys from $INIT_FILE"
  if [ ! -f "$INIT_FILE" ]; then
    echo "ERROR: Vault reports initialized=true but $INIT_FILE is missing." >&2
    echo "Cannot unseal without the original unseal keys." >&2
    exit 1
  fi
fi

echo ""
echo "=== Unsealing (submitting 3 of 5 key shares) ==="
for i in 0 1 2; do
  key="$(python3 -c "import json; print(json.load(open('$INIT_FILE'))['unseal_keys_b64'][$i])")"
  vault_exec operator unseal "$key" >/dev/null
done

vault_exec status
echo ""
echo "Vault unsealed."

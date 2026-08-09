#!/usr/bin/env bash
# Rotate a Vault KV v2 secret and record rotation metadata.
#
# Relies entirely on KV v2's native versioning for rollback -- this script
# does not delete or destroy old versions. Rotating is just "write a new
# version"; removing old versions is a separate, deliberate act (see
# `vault kv metadata` docs) this script does not perform automatically.
#
# The new secret value is NEVER accepted as a CLI argument (would leak into
# shell history / `ps`) -- read from stdin, or from a file if you must
# (delete the file immediately after).
#
# Usage:
#   echo -n "$NEW_VALUE" | rotate_secret.sh <path> <field>
#
# Example:
#   echo -n "$NEW_GITHUB_PAT" | rotate_secret.sh devops/github token

set -euo pipefail

SECRET_PATH="${1:?Usage: rotate_secret.sh <path> <field>  (new value on stdin)}"
FIELD="${2:?Usage: rotate_secret.sh <path> <field>  (new value on stdin)}"
CONTAINER="vault-vault-1"

if [ -t 0 ]; then
  echo "Refusing to read a secret value from an interactive terminal directly --" >&2
  echo "pipe it in instead: echo -n \"\$VALUE\" | $0 $SECRET_PATH $FIELD" >&2
  exit 1
fi

NEW_VALUE="$(cat)"
NEW_LEN="${#NEW_VALUE}"
if [ "$NEW_LEN" -eq 0 ]; then
  echo "Refusing to rotate to an empty value." >&2
  exit 1
fi

if [ -z "${VAULT_TOKEN:-}" ]; then
  echo "VAULT_TOKEN not set. Export a token with write access to secret/data/$SECRET_PATH first." >&2
  exit 1
fi

echo "=== [rotate] secret/$SECRET_PATH field=$FIELD (new value length: $NEW_LEN, never printed) ==="

get_current_version() {
  docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$CONTAINER" \
    vault kv metadata get -format=json "secret/$SECRET_PATH" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['current_version'])" 2>/dev/null || echo "0"
}

OLD_VERSION="$(get_current_version)"

docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" -e SECRET_VAL="$NEW_VALUE" "$CONTAINER" \
  sh -c "vault kv put secret/$SECRET_PATH $FIELD=\"\$SECRET_VAL\"" >&2

NEW_VERSION="$(get_current_version)"

ROTATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$CONTAINER" \
  vault kv metadata put \
  -custom-metadata="rotated_at=$ROTATED_AT" \
  -custom-metadata="previous_version=$OLD_VERSION" \
  "secret/$SECRET_PATH" >&2

echo "Rotated: version $OLD_VERSION -> $NEW_VERSION"
echo "Old version ($OLD_VERSION) is still readable via:"
echo "  vault kv get -version=$OLD_VERSION secret/$SECRET_PATH"
echo "(not deleted -- rollback stays possible until you explicitly destroy it)"

# Round-trip verification WITHOUT printing the secret: compare lengths only.
READ_BACK_LEN="$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" "$CONTAINER" \
  vault kv get -field="$FIELD" "secret/$SECRET_PATH" | tr -d '\n' | wc -c | tr -d ' ')"
if [ "$READ_BACK_LEN" = "$NEW_LEN" ]; then
  echo "Round-trip verified: length matches ($NEW_LEN)."
else
  echo "WARNING: round-trip length mismatch (wrote $NEW_LEN, read back $READ_BACK_LEN)." >&2
  exit 1
fi

#!/usr/bin/env bash
# Issue the metadata-only AppRole that lets the scheduled rotation check run.
#
# Run once. After this, the `rotation` scheduler job stops reporting
# not-configured and starts actually checking every secret's age.
#
# WHAT THIS GRANTS, IN ONE SENTENCE: the ability to list secret paths and read
# when each was last rotated -- and nothing that can read a secret's value.
# The policy is platform/vault/policies/rotation-check.hcl; read it before
# running this, because a credential written to disk deserves that much.
#
# WHY A SEPARATE ROLE RATHER THAN REUSING station2-twin's.
# That AppRole can read database credentials. Handing it to a scheduled report
# would mean a report holds a database credential for the duration of every
# run, for no reason. Separate paths are what make separate grants possible --
# the same argument platform/vault/README.md makes for keeping the two GitHub
# credentials apart.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VAULT_CONTAINER="vault-vault-1"
INIT_FILE="$REPO_ROOT/platform/vault/.init-output.json"
POLICY_FILE="$REPO_ROOT/platform/vault/policies/rotation-check.hcl"
ROLE="rotation-check"
OUT="$REPO_ROOT/platform/vault/.${ROLE}-approle.json"

die() { echo "$@" >&2; exit 1; }

[ -f "$INIT_FILE" ] || die "No $INIT_FILE. Vault has not been initialised on this host."
[ -f "$POLICY_FILE" ] || die "Missing $POLICY_FILE."
docker inspect -f '{{.State.Running}}' "$VAULT_CONTAINER" 2>/dev/null | grep -q true \
  || die "Vault container '$VAULT_CONTAINER' is not running."

ROOT_TOKEN="$(python3 -c "import json;print(json.load(open('$INIT_FILE'))['root_token'])")"
v() { docker exec -e VAULT_TOKEN="$ROOT_TOKEN" "$VAULT_CONTAINER" vault "$@" </dev/null; }
# `vault policy write <name> -` reads from stdin, so it must NOT get
# </dev/null. Two functions, each obviously correct, beats one that is
# conditionally safe -- same reasoning as setup_database_secrets.sh.
v_stdin() { docker exec -i -e VAULT_TOKEN="$ROOT_TOKEN" "$VAULT_CONTAINER" vault "$@"; }

echo "=== [1/3] policy ==="
v_stdin policy write "$ROLE" - < "$POLICY_FILE" >/dev/null \
  || die "Could not write the policy."
echo "  policy '$ROLE' written from $(basename "$POLICY_FILE")"

echo "=== [2/3] approle ==="
v auth list -format=json 2>/dev/null | grep -q '"approle/"' || v auth enable approle >/dev/null 2>&1
# token_ttl 10m: a sweep takes seconds. A report's credential has no business
# outliving the report. secret_id_ttl=0 because the secret_id lives in a
# chmod-600 file that only this host's scheduler reads; rotating it on a timer
# would break the job rather than protect anything.
v write auth/approle/role/"$ROLE" \
  token_policies="$ROLE" \
  token_ttl=10m token_max_ttl=30m secret_id_ttl=0 >/dev/null 2>&1 \
  || die "Could not create the AppRole."

ROLE_ID="$(v read -field=role_id auth/approle/role/"$ROLE"/role-id 2>/dev/null)"
SECRET_ID="$(v write -f -field=secret_id auth/approle/role/"$ROLE"/secret-id 2>/dev/null)"
[ -n "$ROLE_ID" ] && [ -n "$SECRET_ID" ] || die "Could not obtain AppRole credentials."

python3 - "$OUT" "$ROLE_ID" "$SECRET_ID" <<'PY'
import json, os, pathlib, sys
out, role_id, secret_id = sys.argv[1:]
p = pathlib.Path(out)
p.write_text(json.dumps({"role_id": role_id, "secret_id": secret_id}, indent=2) + "\n")
os.chmod(p, 0o600)
PY
echo "  approle '$ROLE' created (role_id ${ROLE_ID:0:8}...)"
echo "  credentials -> $(basename "$OUT") (chmod 600, gitignored)"

echo "=== [3/3] proving the grant is what the policy claims ==="
TOKEN="$(docker exec "$VAULT_CONTAINER" vault write -field=token auth/approle/login \
           role_id="$ROLE_ID" secret_id="$SECRET_ID" </dev/null 2>/dev/null)"
[ -n "$TOKEN" ] || die "The new credentials do not authenticate."
vt() { docker exec -e VAULT_TOKEN="$TOKEN" "$VAULT_CONTAINER" vault "$@" </dev/null; }

# POSITIVE: it can list. Without this the sweep silently finds nothing and,
# because an empty sweep is treated as a failure, at least it would be loud.
vt kv list secret/ >/dev/null 2>&1 \
  || die "FAIL: the role cannot list secret/. The policy grant is wrong."
echo "  PASS  can list secret/"

# NEGATIVE: it must NOT be able to read a value. This is the assertion that
# makes the whole design worth the extra file -- 'metadata only' is a claim
# until something tries to read data and is refused.
find_a_secret() {
  local prefix="$1" depth="$2" entry
  [ "$depth" -gt 3 ] && return 1
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    case "$entry" in
      */) find_a_secret "$prefix$entry" $(( depth + 1 )) && return 0 ;;
      *)  printf '%s' "$prefix$entry"; return 0 ;;
    esac
  done < <(vt kv list -format=json "secret/$prefix" 2>/dev/null | python3 -c "
import json,sys
try: print('\n'.join(json.load(sys.stdin)))
except Exception: pass
")
  return 1
}
# 必須遞迴：本平台的秘密全在 secret/devops/ 之下，只看最上層會找不到任何目標，
# 於是這條否定斷言不會失敗——它會「沒有執行」，然後印一行 UNVERIFIED 就過去了。
FIRST="$(find_a_secret "" 0 || true)"
if [ -n "$FIRST" ]; then
  if vt kv get "secret/$FIRST" >/dev/null 2>&1; then
    die "FAIL: the role READ secret/$FIRST. It is not metadata-only. Aborting."
  fi
  echo "  PASS  denied reading secret/$FIRST (metadata-only holds)"
else
  # Say so rather than printing a pass for an assertion that never ran.
  echo "  UNVERIFIED  no top-level secret to attempt a denied read against;" >&2
  echo "              the metadata-only property was NOT exercised here." >&2
fi

echo ""
echo "Done. The rotation job will now check instead of reporting not-configured:"
echo "  platform/vault/scripts/check_rotation_sweep.sh"

#!/usr/bin/env bash
# Restore drill: proves a backup is actually restorable.
#
# "We have backups" is a claim about files existing. This is the evidence
# that the files can be turned back into a working system -- which is a
# different and much stronger claim, and the one that matters at 3am.
#
# The drill is deliberately built around three rules:
#
#   1. NEVER restore over the live system. Everything happens in a scratch
#      container on a different port with a throwaway volume. A restore
#      procedure whose only rehearsal destroys production is not a
#      procedure, it is a threat.
#   2. Verify integrity BEFORE restoring. The manifest's sha256 is checked
#      against the archive on disk, so corruption between backup and restore
#      is caught instead of faithfully restored.
#   3. Prove the data is USABLE, not just present. Extracting a tar proves
#      nothing about Vault. The drill unseals the restored Vault with the
#      real unseal keys and reads back a real secret -- if that fails, the
#      backup was worthless no matter how clean the tar was.
#
# Usage:
#   restore_drill.sh [backup_dir]     # default: newest under archives/
#
# Exit 0 only if the restored Vault unseals AND returns the expected secret.
# Prints no secret value: verification compares lengths and digests.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VAULT_DIR="$REPO_ROOT/platform/vault"

SCRATCH_CONTAINER="vault-restore-drill"
SCRATCH_VOLUME="vault-restore-drill-vol"
SCRATCH_PORT=18299
# The cluster the PVC restore check talks to. Overridable so the drill can be
# pointed at a different cluster without editing it.
K8S_CTX="${K8S_CTX:-k3d-devops-lab}"

BACKUP_DIR="${1:-}"
if [ -z "$BACKUP_DIR" ]; then
  BACKUP_DIR="$(find "$SCRIPT_DIR/archives" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -1)"
fi

if [ -z "$BACKUP_DIR" ] || [ ! -f "$BACKUP_DIR/manifest.json" ]; then
  echo "No backup with a manifest found. Run platform/backup/backup.sh first." >&2
  exit 1
fi

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

cleanup() {
  docker rm -f "$SCRATCH_CONTAINER" >/dev/null 2>&1 || true
  docker volume rm "$SCRATCH_VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== [restore drill] $BACKUP_DIR ==="
echo ""
echo "--- 1. integrity: does the archive still match what was backed up? ---"

INTEGRITY_OK=1
while IFS='|' read -r archive expected_digest; do
  [ -z "$archive" ] && continue
  path="$BACKUP_DIR/$archive"
  if [ ! -f "$path" ]; then
    fail "archive present: $archive" "missing"
    INTEGRITY_OK=0
    continue
  fi
  actual="$(shasum -a 256 "$path" | cut -d' ' -f1)"
  if [ "$actual" = "$expected_digest" ]; then
    pass "digest matches manifest: $archive"
  else
    fail "digest matches manifest: $archive" "expected ${expected_digest:0:16}… got ${actual:0:16}…"
    INTEGRITY_OK=0
  fi
done < <(python3 -c "
import json
m = json.load(open('$BACKUP_DIR/manifest.json'))
for v in m['volumes']:
    print(f\"{v['archive']}|{v['sha256']}\")
")

if [ "$INTEGRITY_OK" -ne 1 ]; then
  echo ""
  echo "Refusing to restore a backup that failed integrity checks." >&2
  echo "  $PASSED passed, $FAILED failed"
  exit 1
fi

echo ""
echo "--- 2. restore Vault into a SCRATCH instance (live Vault untouched) ---"

cleanup
docker volume create "$SCRATCH_VOLUME" >/dev/null

docker run --rm \
  -v "$SCRATCH_VOLUME:/dest" \
  -v "$BACKUP_DIR:/backup:ro" \
  alpine:3.20 \
  sh -c "tar xzf /backup/vault_vault-file.tar.gz -C /dest" 2>/dev/null

if docker run --rm -v "$SCRATCH_VOLUME:/d:ro" alpine:3.20 sh -c "ls /d | head -1" | grep -q .; then
  pass "archive extracted into scratch volume"
else
  fail "archive extracted into scratch volume" "volume is empty after extraction"
  echo "  $PASSED passed, $FAILED failed"; exit 1
fi

docker run -d --name "$SCRATCH_CONTAINER" \
  -v "$VAULT_DIR/config/vault.hcl:/vault/config/vault.hcl:ro" \
  -v "$SCRATCH_VOLUME:/vault/file" \
  --tmpfs /vault/logs:size=4m \
  --tmpfs /tmp:size=8m \
  -e SKIP_SETCAP=1 \
  -e VAULT_ADDR=http://127.0.0.1:8200 \
  -p "127.0.0.1:${SCRATCH_PORT}:8200" \
  --memory 256m \
  hashicorp/vault:1.18 server >/dev/null

scratch_vault() {
  # stdin is redirected from /dev/null deliberately. `docker exec -i`
  # attaches the caller's stdin, so calling this inside a `while read` loop
  # let docker drain the loop's own input -- the unseal loop applied key 1
  # and then silently exited with the remaining keys eaten, leaving Vault
  # sealed at 1/3 with no error anywhere. Found by running the drill, not by
  # reading it.
  docker exec -i -e VAULT_ADDR=http://127.0.0.1:8200 \
    ${SCRATCH_TOKEN:+-e VAULT_TOKEN="$SCRATCH_TOKEN"} \
    "$SCRATCH_CONTAINER" vault "$@" 2>&1 </dev/null
}

for _ in $(seq 1 30); do
  scratch_vault status >/dev/null 2>&1 && break
  sleep 1
done

STATUS_JSON="$(scratch_vault status -format=json 2>/dev/null)"
INITIALIZED="$(echo "$STATUS_JSON" | python3 -c "
import json,sys
try: print(json.load(sys.stdin)['initialized'])
except Exception: print('unknown')")"

# An empty (freshly created) Vault reports initialized:false. If the restored
# one reports true, the restore genuinely carried Vault's own state -- not
# just some bytes into a directory.
if [ "$INITIALIZED" = "True" ]; then
  pass "restored Vault reports initialized=true (real state, not an empty volume)"
else
  fail "restored Vault reports initialized=true" "got: $INITIALIZED"
fi

echo ""
echo "--- 3. usability: unseal the restored Vault and read a real secret ---"

if [ ! -f "$VAULT_DIR/.init-output.json" ]; then
  fail "unseal keys available" "no .init-output.json -- backup is unrecoverable without it"
  echo "  $PASSED passed, $FAILED failed"; exit 1
fi

# 3 of 5 shares, matching the threshold set at init. Read into an array
# first rather than piping into a loop -- belt and braces alongside the
# </dev/null in scratch_vault, since this is exactly the stdin-eating shape
# that failed here once already.
UNSEAL_KEYS=()
while IFS= read -r key; do
  UNSEAL_KEYS+=("$key")
done < <(python3 -c "
import json
d = json.load(open('$VAULT_DIR/.init-output.json'))
for k in d['unseal_keys_b64'][:3]:
    print(k)
")
for key in "${UNSEAL_KEYS[@]}"; do
  scratch_vault operator unseal "$key" >/dev/null 2>&1
done

SEALED="$(scratch_vault status -format=json 2>/dev/null | python3 -c "
import json,sys
try: print(json.load(sys.stdin)['sealed'])
except Exception: print('unknown')")"

if [ "$SEALED" = "False" ]; then
  pass "restored Vault unseals with the real unseal keys"
else
  fail "restored Vault unseals" "sealed=$SEALED"
  echo "  $PASSED passed, $FAILED failed"; exit 1
fi

SCRATCH_TOKEN="$(python3 -c "
import json
print(json.load(open('$VAULT_DIR/.init-output.json'))['root_token'])")"
export SCRATCH_TOKEN

# The payoff. Compared by length, never printed -- same discipline as the
# original migration verification in platform/vault/README.md.
RESTORED_LEN="$(scratch_vault kv get -field=token secret/devops/github 2>/dev/null | tr -d '\n' | wc -c | tr -d ' ')"
LIVE_LEN="$(docker exec -i \
  -e VAULT_TOKEN="$SCRATCH_TOKEN" -e VAULT_ADDR=http://127.0.0.1:8200 \
  vault-vault-1 vault kv get -field=token secret/devops/github 2>/dev/null | tr -d '\n' | wc -c | tr -d ' ')"

# THREE OUTCOMES, NOT TWO.
#
# The first version had two, and on 2026-08-22 it reported
#   FAIL secret read back from restored Vault -- restored=93 live=0
# The restore was fine: it read the secret, 93 chars. The LIVE Vault was the
# side that returned nothing (down or sealed at that moment; it passed 12/12
# on 2026-08-25 against the same code path). So a drill whose entire job is to
# tell you whether your backup is restorable spent three days telling you it
# was not, because of a problem on the other side of the comparison.
#
# Failing closed is right. Attributing the failure to the wrong component is
# not: it sends the reader to the archive when the archive was never the
# problem. So the unreachable-live case is now its own message.
if [ "$RESTORED_LEN" -gt 0 ] && [ "$RESTORED_LEN" = "$LIVE_LEN" ]; then
  pass "secret read back from restored Vault matches live (${RESTORED_LEN} chars, value never printed)"
elif [ "$RESTORED_LEN" -gt 0 ] && [ "$LIVE_LEN" -eq 0 ]; then
  # Still a failure -- nothing was compared, so nothing was proved -- but named
  # for the side that actually broke.
  fail "cannot compare against live Vault (restore itself read ${RESTORED_LEN} chars)" \
       "live Vault returned nothing: is vault-vault-1 running and unsealed? \`docker exec vault-vault-1 vault status\`"
else
  fail "secret read back from restored Vault" "restored=${RESTORED_LEN} live=${LIVE_LEN}"
fi

# Identity is state too: a restore that loses every policy and auth method
# would still pass a naive "can I read a secret with the root token" check.
POLICY_COUNT="$(scratch_vault policy list 2>/dev/null | grep -c . || echo 0)"
if [ "$POLICY_COUNT" -ge 6 ]; then
  pass "identity model survived the restore ($POLICY_COUNT policies)"
else
  fail "identity model survived the restore" "only $POLICY_COUNT policies found"
fi

APPROLE_OK="$(scratch_vault auth list 2>/dev/null | grep -c approle || echo 0)"
if [ "$APPROLE_OK" -ge 1 ]; then
  pass "auth methods survived the restore (approle present)"
else
  fail "auth methods survived the restore" "approle missing"
fi

# --- 4. PVC archives ------------------------------------------------------
#
# "A backup that has never been restored is not a backup" applies to PVC
# archives exactly as it applies to Vault's. And a PVC archive has a failure
# mode of its own that integrity checks cannot see: a backup pod scheduled onto
# the wrong node tars an EMPTY directory, and the resulting archive has a valid
# digest, a valid manifest entry, and nothing in it. The only way to find that
# is to put it back and look.
echo ""
echo "--- 4. PVC archives: restore one and read it back ---"

PVC_ENTRIES="$(python3 -c "
import json,sys
m = json.load(open('$BACKUP_DIR/manifest.json'))
for v in m.get('volumes', []):
    if str(v.get('volume','')).startswith('pvc:'):
        print(v['volume'], v['archive'])
" 2>/dev/null)"

if [ -z "$PVC_ENTRIES" ]; then
  # Said out loud rather than skipped. "There were no PVC archives" and "the
  # PVC restore was not exercised" are the same sentence, and a silent skip
  # only reads as the first one.
  echo "  no PVC archive in this backup -- the PVC restore path was NOT exercised."
  echo "  (backup.sh's coverage gate is what guarantees a PVC cannot be missing;"
  echo "   this line only reports that none was present to restore here.)"
else
  PVC_NS="restore-drill-$$"
  PVC_LINE="$(printf '%s\n' "$PVC_ENTRIES" | head -1)"
  SRC_NAME="${PVC_LINE%% *}"
  SRC_ARCHIVE="${PVC_LINE##* }"
  kubectl --context "$K8S_CTX" create ns "$PVC_NS" >/dev/null 2>&1
  cat <<YAML | kubectl --context "$K8S_CTX" apply -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: restored, namespace: $PVC_NS}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 128Mi}}
---
apiVersion: v1
kind: Pod
metadata: {name: restorer, namespace: $PVC_NS}
spec:
  restartPolicy: Never
  containers:
    - name: r
      image: alpine:3.20
      command: ["sh","-c","sleep 600"]
      volumeMounts: [{name: d, mountPath: /data}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: restored}}]
YAML
  if kubectl --context "$K8S_CTX" -n "$PVC_NS" wait --for=condition=Ready pod/restorer \
       --timeout=120s >/dev/null 2>&1; then
    if kubectl --context "$K8S_CTX" -n "$PVC_NS" exec -i restorer -- \
         tar xzf - -C /data < "$BACKUP_DIR/$SRC_ARCHIVE" >/dev/null 2>&1; then
      RESTORED_FILES="$(kubectl --context "$K8S_CTX" -n "$PVC_NS" exec restorer -- \
        sh -c 'find /data -type f | wc -l' 2>/dev/null | tr -d ' \r\n')"
      RESTORED_BYTES="$(kubectl --context "$K8S_CTX" -n "$PVC_NS" exec restorer -- \
        sh -c 'find /data -type f -exec cat {} + | wc -c' 2>/dev/null | tr -d ' \r\n')"
      # Non-empty is the assertion that matters. An empty restore is exactly
      # what a mis-scheduled backup pod produces, and every check before this
      # one passes on it.
      if [ "${RESTORED_FILES:-0}" -gt 0 ] && [ "${RESTORED_BYTES:-0}" -gt 0 ]; then
        pass "$SRC_NAME restored into a scratch PVC ($RESTORED_FILES file(s), $RESTORED_BYTES bytes)"
      else
        fail "$SRC_NAME restored EMPTY" \
             "files=$RESTORED_FILES bytes=$RESTORED_BYTES -- the archive has a valid digest and no content"
      fi
    else
      fail "could not extract $SRC_ARCHIVE into the scratch PVC"
    fi
  else
    fail "scratch restore pod never became Ready"
  fi
  kubectl --context "$K8S_CTX" delete ns "$PVC_NS" --wait=false >/dev/null 2>&1
  echo "  scratch namespace removed; no live PVC was touched"
fi

echo ""
echo "--- 5. teardown ---"
cleanup
echo "  scratch container and volume removed; live Vault never touched"

echo ""
echo "  $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]

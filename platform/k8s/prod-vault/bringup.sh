#!/usr/bin/env bash
# Bring the production cluster's Vault up to the point only a person can pass.
#
# WHAT THIS DOES AND WHERE IT STOPS (2026-09-20).
#
# It applies the manifests, waits for the pod, and then reports which of three
# states Vault is in:
#
#   uninitialised  -> BLOCKED. `vault operator init` mints unseal keys and a
#                     root token. Those are the only secrets in this platform
#                     that cannot be re-derived from anything else, so an agent
#                     must not hold them, write them, or print them. The script
#                     prints the command for you and stops.
#   sealed         -> BLOCKED. Unsealing needs the keys, which are yours.
#   unsealed       -> continues: configures the database secrets engine and the
#                     AppRole the pilot uses, then reports what is left.
#
# `blocked` is reported as an EVENT, not silently: a bring-up that stopped and
# said nothing is indistinguishable from one nobody started. That distinction
# is the same one platform/notify/emit_event.sh exists for.
#
# Usage:
#   platform/k8s/prod-vault/bringup.sh            # apply + report state
#   platform/k8s/prod-vault/bringup.sh --status   # report state only
#
# Exit codes: 0 ready (or applied and reported) · 20 blocked on the operator ·
#             21 cluster unreachable · 2 usage
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
CTX="${PROD_CONTEXT:-ubu}"
NS="${PROD_VAULT_NS:-vault}"
NOTIFY="$REPO_ROOT/platform/notify/emit_event.sh"

STATUS_ONLY=0
[ "${1:-}" = "--status" ] && STATUS_ONLY=1
[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && { sed -n '1,30p' "$0"; exit 0; }

say() { printf '%s\n' "$*"; }

kubectl --context "$CTX" get nodes >/dev/null 2>&1 || {
  say "叢集 $CTX 連不上" >&2; exit 21; }

if [ "$STATUS_ONLY" -eq 0 ]; then
  kubectl --context "$CTX" apply -f "$HERE/vault.yaml" >/dev/null || exit 21
  kubectl --context "$CTX" -n "$NS" rollout status statefulset/vault --timeout=150s >/dev/null 2>&1
fi

# Vault's own health endpoint distinguishes the three states in ONE call, by
# status code. Parsing the JSON would work too; the codes are what the
# readiness probe already uses, so they are the thing that stays true.
HEALTH="$(kubectl --context "$CTX" -n "$NS" exec vault-0 -- \
  wget -qO- "http://127.0.0.1:8200/v1/sys/health?standbyok=true&sealedcode=200&uninitcode=200" \
  2>/dev/null)"
INIT="$(printf '%s' "$HEALTH" | sed -n 's/.*"initialized":\([a-z]*\).*/\1/p')"
SEALED="$(printf '%s' "$HEALTH" | sed -n 's/.*"sealed":\([a-z]*\).*/\1/p')"

say "=== prod Vault（$CTX/${NS}）==="
say "  initialized  ${INIT:-?}"
say "  sealed       ${SEALED:-?}"

if [ "$INIT" != "true" ]; then
  say ""
  say "BLOCKED：Vault 還沒初始化，而初始化只能由你做。"
  say ""
  say "  kubectl --context $CTX -n $NS exec -it vault-0 -- \\"
  say "    vault operator init -key-shares=3 -key-threshold=2"
  say ""
  say "它會印出 3 把 unseal key 與 1 個 root token。**那是這個平台唯一無法重新推導的東西**："
  say "請把它們存進密碼管理器（和 rclone 的 crypt 密碼放在一起，見 platform/backup/README.md）。"
  say "不要貼進這個對話、不要寫進 repo 裡的檔案。"
  say ""
  say "之後解封（任兩把）："
  say "  kubectl --context $CTX -n $NS exec -it vault-0 -- vault operator unseal"
  say ""
  say "解封完再跑一次：platform/k8s/prod-vault/bringup.sh"
  [ -x "$NOTIFY" ] && "$NOTIFY" offsite-restore blocked \
    "prod Vault 已就緒但未初始化——init 與 unseal 只能由你執行（platform/k8s/prod-vault/bringup.sh 有指令）" \
    >/dev/null 2>&1
  exit 20
fi

if [ "$SEALED" = "true" ]; then
  say ""
  say "BLOCKED：Vault 已初始化但仍封印中。用任兩把 unseal key 解封："
  say "  kubectl --context $CTX -n $NS exec -it vault-0 -- vault operator unseal"
  [ -x "$NOTIFY" ] && "$NOTIFY" offsite-restore blocked \
    "prod Vault 封印中，需要 unseal key（只有你有）" >/dev/null 2>&1
  exit 20
fi

say ""
say "Vault 已解封。剩下的設定（資料庫引擎、AppRole）需要 root token，"
say "同樣只能由你提供——把它匯出成 VAULT_TOKEN 之後跑："
say "  platform/vault/scripts/setup_database_secrets.sh station2-publichealth"
say ""
say "設定完成後，pilot 才會以動態憑證上線；在那之前 prod 叢集只有資料庫在跑。"
exit 0

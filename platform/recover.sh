#!/usr/bin/env bash
# Bring the whole platform back after a host reboot or a full stop.
#
# WHY THIS EXISTS.
#
# Every container used to be `restart: no`, so a reboot took the platform
# down and left it down. That is now fixed with `restart: unless-stopped` --
# but restarting Vault is not the same as restoring it. Vault comes back
# SEALED, and while it is sealed nothing that needs a secret works: no
# identity, no CI credential, no Grafana admin, no audit writes.
#
# Meanwhile the launchd agents survive a reboot perfectly well and keep
# firing on schedule. So without this, the post-reboot state is: every
# scheduled job running on time and failing against a sealed Vault and
# absent containers, reporting into a local notification file nobody is
# watching. Busy, and completely down.
#
# Auto-unseal at boot is deliberately NOT wired. The unseal keys already sit
# on this disk in .init-output.json, so a boot-time unseal would not lower
# the security posture much -- but "not much worse than an existing weakness"
# is a poor reason to remove the last deliberate human step, and
# platform/vault/README.md records auto-unseal as a decision waiting on a
# cloud KMS. One command is the compromise: explicit, fast, and hard to
# forget because check_health.sh and the status DAG both go red until it is
# run.
#
# Usage:
#   platform/recover.sh            bring everything up and unseal
#   platform/recover.sh --check    report what is down, change nothing

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# Order matters. Vault first because other services read credentials from it,
# observability next so the recovery of everything after it is actually
# recorded, then ingress, then the pilot.
STACKS=(
  "platform/vault:vault"
  "platform/observability:observability"
  "platform/nginx:nginx"
)

echo "=== [recover] platform state ==="

down=0
for entry in "${STACKS[@]}"; do
  dir="${entry%%:*}"
  name="${entry##*:}"
  # `wc -l`, not `grep -c . || echo 0`. grep -c prints "0" AND exits 1 when
  # nothing matches, so the fallback appended a second zero and the count
  # became "0\n0" -- which then failed the integer comparison. The failure
  # mode was the recovery script itself erroring in exactly the situation it
  # exists for: everything down.
  running="$(docker compose -f "$REPO_ROOT/$dir/compose.yaml" ps --status running -q 2>/dev/null | wc -l | tr -d ' ')"
  total="$(docker compose -f "$REPO_ROOT/$dir/compose.yaml" config --services 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$running" -lt "$total" ]; then
    echo "  DOWN  $name ($running/$total running)"
    down=$((down + 1))
  else
    echo "  up    $name ($running/$total)"
  fi
done

SEALED="$(docker exec -i -e VAULT_ADDR=http://127.0.0.1:8200 vault-vault-1 \
  vault status -format=json </dev/null 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['sealed'])" 2>/dev/null || echo "unreachable")"
echo "  vault sealed: $SEALED"

if [ "$CHECK_ONLY" -eq 1 ]; then
  if [ "$down" -eq 0 ] && [ "$SEALED" = "False" ]; then
    echo "Platform is up."
    exit 0
  fi
  echo "Platform needs recovery. Run: platform/recover.sh"
  exit 1
fi

if [ "$down" -gt 0 ]; then
  echo ""
  echo "=== [recover] starting stacks ==="
  for entry in "${STACKS[@]}"; do
    dir="${entry%%:*}"
    name="${entry##*:}"
    echo "  $name"
    (cd "$REPO_ROOT/$dir" && docker compose up -d >/dev/null 2>&1) \
      || echo "    WARNING: $name failed to start" >&2
  done
fi

# The pilot is deliberately handled separately: develop is safe to bring up
# unconditionally, but production-like is blue/green and only the ACTIVE
# colour should return. Starting both would put two colours in service.
echo ""
echo "=== [recover] pilot ==="
PILOT_STATE="$REPO_ROOT/evidence/station1-hello/production_like_state.json"
(cd "$REPO_ROOT" && docker compose -p station1-hello-develop \
  --env-file platform/compose/environments/station1-hello/develop.env \
  -f pilots/station1-hello/compose.yaml up -d --no-build >/dev/null 2>&1) \
  && echo "  develop up" || echo "  WARNING: develop did not start" >&2

if [ -f "$PILOT_STATE" ]; then
  ACTIVE="$(python3 -c "
import json
print(json.load(open('$PILOT_STATE')).get('active_color', ''))" 2>/dev/null)"
  PORT="$(python3 -c "
import json
print(json.load(open('$PILOT_STATE')).get('active_port', ''))" 2>/dev/null)"
  if [ -n "$ACTIVE" ] && [ -n "$PORT" ]; then
    (cd "$REPO_ROOT" && HOST_PORT="$PORT" docker compose \
      -p "station1-hello-productionlike-${ACTIVE}" \
      --env-file platform/compose/environments/station1-hello/production-like.env \
      -f pilots/station1-hello/compose.yaml up -d --no-build >/dev/null 2>&1) \
      && echo "  production-like $ACTIVE up (the parked colour is left down on purpose)" \
      || echo "  WARNING: production-like $ACTIVE did not start" >&2
  fi
fi

echo ""
echo "=== [recover] unseal ==="
for _ in $(seq 1 20); do
  docker exec -i -e VAULT_ADDR=http://127.0.0.1:8200 vault-vault-1 \
    vault status </dev/null >/dev/null 2>&1 && break
  sleep 2
done
"$REPO_ROOT/platform/vault/scripts/init_and_unseal.sh" 2>&1 | tail -2

echo ""
echo "=== [recover] verdict ==="
"$REPO_ROOT/platform/observability/check_health.sh" --no-evidence 2>&1 | head -1
python3 "$REPO_ROOT/platform/statusdag/dag.py" 2>&1 | head -1
echo ""
echo "Recovery does not backfill missed scheduled runs. Check what was"
echo "skipped while the platform was down:"
echo "  platform/scheduler/status.sh"

#!/usr/bin/env bash
# Develop / production-like deployment adapter.
#
# Implements Plan.md §4 "兩環境最小隔離":
#   - separate Compose project (and therefore separate default network) per environment
#   - separate environment config file (platform/compose/environments/<pilot>/<env>.env)
#   - production-like only ever runs the exact image built (and validated) in develop —
#     this script never rebuilds an image for a "deploy" step, only for "build"
#
# Usage:
#   deploy.sh build    <pilot_dir>
#   deploy.sh deploy   develop <pilot_dir>
#   deploy.sh promote  <pilot_dir>
#   deploy.sh rollback <pilot_dir>
#   deploy.sh status   develop <pilot_dir>
#   deploy.sh status   production-like <pilot_dir> <blue|green>
#   deploy.sh teardown develop <pilot_dir>
#   deploy.sh teardown production-like <pilot_dir> <blue|green>
#
# 'deploy' only ever targets develop. Production-like is a blue/green pair
# (host ports 18081=blue, 18082=green — see platform/compose/README.md),
# reached only via 'promote', which:
#   1. requires a matching, healthy deploy_develop_<sha>.json evidence file
#      for the pilot's *current* git SHA (the develop-validation gate —
#      production-like never runs an image that wasn't validated in develop
#      first)
#   2. starts the *other* color using that exact image (no rebuild)
#   3. smoke-tests the new color directly, before touching any live traffic
#   4. pauses for an interactive "type PROMOTE to confirm" — this is a real
#      human-in-the-loop gate, not a --yes flag, per NEW_SERVICE_GUIDE.md §8
#      ("LLM 可以執行測試...但不能代替人類進行...production release approval")
#   5. only then flips the NGINX production-like vhost to the new color and
#      reloads
# The color being replaced is left running (not torn down) specifically so
# 'rollback' can flip traffic straight back without redeploying anything.
#
# Example:
#   platform/compose/deploy.sh build pilots/station1-hello
#   platform/compose/deploy.sh deploy develop pilots/station1-hello
#   platform/compose/deploy.sh promote pilots/station1-hello

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PLATFORM_ROOT/.." && pwd)"

usage() {
  echo "Usage:" >&2
  echo "  $0 build    <pilot_dir>" >&2
  echo "  $0 deploy   develop <pilot_dir>" >&2
  echo "  $0 status   <develop|production-like> <pilot_dir>" >&2
  echo "  $0 teardown <develop|production-like> <pilot_dir>" >&2
  exit 1
}

git_sha() {
  local dir="$1"
  git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo "local-uncommitted"
}

cmd_build() {
  local pilot_dir
  pilot_dir="$(cd "$1" && pwd)"
  local pilot_name
  pilot_name="$(basename "$pilot_dir")"
  local sha
  sha="$(git_sha "$pilot_dir")"

  local evidence_dir="$REPO_ROOT/evidence/$pilot_name"
  mkdir -p "$evidence_dir"

  echo "=== [build] $pilot_name @ $sha ==="
  IMAGE_NAME="${pilot_name}:${sha}" "$PLATFORM_ROOT/ci/run_local_ci.sh" "$pilot_dir" "$evidence_dir" >&2

  # Security gate: fixable CRITICAL/HIGH vulnerabilities block the :dev
  # alias below from ever being created. deploy/promote both refuse to run
  # without a :dev tag, so a failed scan here transitively blocks deploy
  # and promote too, with no separate gate logic needed there.
  if ! "$PLATFORM_ROOT/security/scan_image.sh" "${pilot_name}:${sha}" "$evidence_dir"; then
    echo "BUILD FAILED: image did not pass the security scan gate (see above)." >&2
    echo "The :dev alias was NOT created -- deploy/promote will refuse to run this image." >&2
    exit 1
  fi

  # Alias to the tag the pilot's own compose.yaml expects, so `docker compose
  # up` (without --build) in cmd_deploy reuses this exact image instead of
  # rebuilding it — this is what makes "same image digest across
  # environments" true rather than aspirational.
  docker tag "${pilot_name}:${sha}" "${pilot_name}:dev"

  mv "$evidence_dir/metadata.json" "$evidence_dir/build_${sha}.json"
  echo "artifact=$evidence_dir/build_${sha}.json"
}

require_env_arg() {
  case "$1" in
    develop|production-like) ;;
    *) echo "Environment must be 'develop' or 'production-like', got: $1" >&2; usage ;;
  esac
}

# Blue/green port allocation for production-like (see platform/compose/README.md).
pl_port() {
  case "$1" in
    blue)  echo 18081 ;;
    green) echo 18082 ;;
    *) echo "Color must be 'blue' or 'green', got: $1" >&2; exit 1 ;;
  esac
}

pl_other_color() {
  case "$1" in
    blue)  echo green ;;
    green) echo blue ;;
    none)  echo blue ;; # first-ever promotion
    *) echo "Unknown color in state file: $1" >&2; exit 1 ;;
  esac
}

state_file() {
  echo "$REPO_ROOT/evidence/$1/production_like_state.json"
}

read_state_field() {
  local file="$1" key="$2" default="$3"
  if [ ! -f "$file" ]; then echo "$default"; return; fi
  python3 -c "
import json, sys
try:
    print(json.load(open('$file')).get('$key', '$default'))
except Exception:
    print('$default')
"
}

reload_nginx() {
  # Best-effort by design: the NGINX adapter (platform/nginx/) is optional —
  # promote/rollback must not fail just because it isn't running (e.g. in a
  # test environment that only exercises platform/compose/).
  if docker ps --format '{{.Names}}' | grep -qx nginx-nginx-1; then
    docker exec nginx-nginx-1 nginx -t
    docker exec nginx-nginx-1 nginx -s reload
  else
    echo "NOTE: nginx-nginx-1 not running -- skipped NGINX reload (platform/nginx/ not deployed?)" >&2
  fi
}

write_production_like_vhost() {
  local port="$1"
  local template="$PLATFORM_ROOT/nginx/conf.d/station1-hello.production-like.conf.template"
  local generated="$PLATFORM_ROOT/nginx/conf.d/_generated.station1-hello.production-like.conf"
  sed "s/__UPSTREAM_PORT__/${port}/" "$template" > "$generated"
}

cmd_deploy() {
  local env="$1"
  if [ "$env" != "develop" ]; then
    echo "'deploy' currently only supports 'develop'." >&2
    echo "production-like promotion (develop-validation gate, blue/green," >&2
    echo "human approval, rollback) is a separate, not-yet-built work item" >&2
    echo "-- see Plan.md 'production-like blue/green 與 rollback'." >&2
    exit 1
  fi
  local pilot_dir
  pilot_dir="$(cd "$2" && pwd)"
  local pilot_name
  pilot_name="$(basename "$pilot_dir")"
  local sha
  sha="$(git_sha "$pilot_dir")"
  local project="${pilot_name}-${env}"
  local env_file="$PLATFORM_ROOT/compose/environments/$pilot_name/${env}.env"

  if ! docker image inspect "${pilot_name}:dev" >/dev/null 2>&1; then
    echo "No built image found for ${pilot_name}. Run: $0 build $2" >&2
    exit 1
  fi
  if [ ! -f "$env_file" ]; then
    echo "Missing environment config: $env_file" >&2
    exit 1
  fi

  echo "=== [deploy:$env] project=$project image=${pilot_name}:dev (sha=$sha) ==="
  docker compose -p "$project" --env-file "$env_file" -f "$pilot_dir/compose.yaml" up -d --no-build

  echo "Waiting for health..."
  local container
  container="$(docker compose -p "$project" -f "$pilot_dir/compose.yaml" ps -q | head -1)"
  local status="starting"
  for _ in $(seq 1 20); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "unknown")"
    [ "$status" = "healthy" ] && break
    [ "$status" = "unhealthy" ] && break
    sleep 1
  done
  echo "Health status: $status"

  local image_id
  image_id="$(docker image inspect "${pilot_name}:dev" --format '{{.Id}}')"
  local image_digest
  image_digest="$(docker image inspect "${pilot_name}:dev" --format '{{index .RepoDigests 0}}' 2>/dev/null || true)"
  local deployed_at
  deployed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  local evidence_dir="$REPO_ROOT/evidence/$pilot_name"
  mkdir -p "$evidence_dir"
  local evidence_file="$evidence_dir/deploy_${env}_${sha}.json"

  python3 - "$evidence_file" "$env" "$project" "$sha" "$image_id" "$image_digest" "$deployed_at" "$status" "$env_file" <<'PY'
import json, pathlib, sys
output, environment, project, commit, image_id, digest, deployed_at, health, env_file = sys.argv[1:]
pathlib.Path(output).write_text(json.dumps({
    "environment": environment,
    "compose_project": project,
    "commit_sha": commit,
    "image_id": image_id,
    "image_digest": digest or None,
    "deployed_at": deployed_at,
    "health_status": health,
    "env_file": env_file,
}, indent=2) + "\n")
PY

  if [ "$status" != "healthy" ]; then
    echo "DEPLOY FAILED: container not healthy (status=$status)" >&2
    exit 1
  fi
  echo "DEPLOY PASS"
  echo "artifact=$evidence_file"
}

cmd_promote() {
  local pilot_dir
  pilot_dir="$(cd "$1" && pwd)"
  local pilot_name
  pilot_name="$(basename "$pilot_dir")"
  local sha
  sha="$(git_sha "$pilot_dir")"

  # Gate 1: develop-validation. production-like never runs an image that
  # wasn't just proven healthy in develop, for this exact commit.
  local dev_evidence="$REPO_ROOT/evidence/$pilot_name/deploy_develop_${sha}.json"
  if [ ! -f "$dev_evidence" ]; then
    echo "No develop deployment evidence for sha=$sha." >&2
    echo "Run first: $0 deploy develop $1" >&2
    exit 1
  fi
  local dev_health
  dev_health="$(read_state_field "$dev_evidence" health_status unknown)"
  if [ "$dev_health" != "healthy" ]; then
    echo "Develop deployment for sha=$sha is not healthy (status=$dev_health)." >&2
    echo "Refusing to promote. Fix develop first." >&2
    exit 1
  fi

  local sfile
  sfile="$(state_file "$pilot_name")"
  local current_color
  current_color="$(read_state_field "$sfile" active_color none)"
  local new_color
  new_color="$(pl_other_color "$current_color")"
  local new_port
  new_port="$(pl_port "$new_color")"
  local new_project="${pilot_name}-productionlike-${new_color}"
  local env_file="$PLATFORM_ROOT/compose/environments/$pilot_name/production-like.env"

  echo "=== [promote] $pilot_name sha=$sha ==="
  echo "  current active color: $current_color"
  echo "  new color to deploy:  $new_color (port $new_port, project $new_project)"
  echo ""

  echo "Starting $new_color with the develop-validated image (no rebuild)..."
  HOST_PORT="$new_port" docker compose -p "$new_project" --env-file "$env_file" \
    -f "$pilot_dir/compose.yaml" up -d --no-build

  echo "Waiting for health..."
  local container
  container="$(HOST_PORT="$new_port" docker compose -p "$new_project" -f "$pilot_dir/compose.yaml" ps -q | head -1)"
  local status="starting"
  for _ in $(seq 1 20); do
    status="$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "unknown")"
    [ "$status" = "healthy" ] && break
    [ "$status" = "unhealthy" ] && break
    sleep 1
  done
  if [ "$status" != "healthy" ]; then
    echo "PROMOTE FAILED: $new_color not healthy (status=$status). Traffic untouched." >&2
    exit 1
  fi

  echo "Smoke test: GET http://127.0.0.1:${new_port}/health/ready"
  if ! curl -sf "http://127.0.0.1:${new_port}/health/ready" >/dev/null; then
    echo "PROMOTE FAILED: smoke test did not return 2xx. Traffic untouched." >&2
    exit 1
  fi
  echo "Smoke test passed."
  echo ""
  echo "$new_color is healthy and smoke-tested but NOT YET receiving traffic."
  echo "Flipping production-like traffic from '$current_color' to '$new_color' is"
  echo "a release decision, not something this script decides on its own"
  echo "(see NEW_SERVICE_GUIDE.md section 8)."
  echo ""
  read -r -p "Type PROMOTE to flip traffic to $new_color, anything else to abort: " confirmation
  if [ "$confirmation" != "PROMOTE" ]; then
    echo "Aborted. $new_color is running (for inspection) but NOT receiving traffic." >&2
    echo "Old color '$current_color' is still live, unaffected." >&2
    exit 1
  fi

  write_production_like_vhost "$new_port"
  reload_nginx

  local promoted_at
  promoted_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local image_id
  image_id="$(docker image inspect "${pilot_name}:dev" --format '{{.Id}}')"

  python3 - "$sfile" "$new_color" "$current_color" "$new_project" "$new_port" "$sha" "$image_id" "$promoted_at" <<'PY'
import json, pathlib, sys
output, active, previous, project, port, commit, image_id, promoted_at = sys.argv[1:]
pathlib.Path(output).write_text(json.dumps({
    "active_color": active,
    "previous_color": previous,
    "active_project": project,
    "active_port": int(port),
    "promoted_sha": commit,
    "image_id": image_id,
    "promoted_at": promoted_at,
}, indent=2) + "\n")
PY

  local promote_record="$REPO_ROOT/evidence/$pilot_name/promote_${sha}_$(date -u '+%Y%m%dT%H%M%SZ').json"
  cp "$sfile" "$promote_record"

  echo "PROMOTE PASS"
  echo "  active color: $new_color (was: $current_color, still running for rollback)"
  echo "  artifact=$sfile"
  echo "  artifact=$promote_record"
  if [ "$current_color" != "none" ]; then
    echo "  To roll back: $0 rollback $1"
  fi
}

cmd_rollback() {
  local pilot_dir
  pilot_dir="$(cd "$1" && pwd)"
  local pilot_name
  pilot_name="$(basename "$pilot_dir")"
  local sfile
  sfile="$(state_file "$pilot_name")"

  local active_color previous_color
  active_color="$(read_state_field "$sfile" active_color none)"
  previous_color="$(read_state_field "$sfile" previous_color none)"

  if [ "$active_color" = "none" ] || [ "$previous_color" = "none" ]; then
    echo "No prior production-like color to roll back to (active=$active_color, previous=$previous_color)." >&2
    echo "This is either the first-ever promotion, or state is missing. Use teardown instead if needed." >&2
    exit 1
  fi

  local prev_project="${pilot_name}-productionlike-${previous_color}"
  if ! docker ps --format '{{.Names}}' | grep -q "^${prev_project}-"; then
    echo "Previous color '$previous_color' (project $prev_project) is not running -- cannot roll back to it." >&2
    exit 1
  fi

  local prev_port
  prev_port="$(pl_port "$previous_color")"

  echo "=== [rollback] $pilot_name: $active_color -> $previous_color ==="
  read -r -p "Type ROLLBACK to flip traffic back to $previous_color, anything else to abort: " confirmation
  if [ "$confirmation" != "ROLLBACK" ]; then
    echo "Aborted. No change made." >&2
    exit 1
  fi

  write_production_like_vhost "$prev_port"
  reload_nginx

  local rolled_back_at
  rolled_back_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  python3 - "$sfile" "$previous_color" "$active_color" "${pilot_name}-productionlike-${previous_color}" "$prev_port" <<'PY'
import json, pathlib, sys
output, active, previous, project, port = sys.argv[1:]
data = {}
try:
    data = json.load(open(output))
except Exception:
    pass
data.update({
    "active_color": active,
    "previous_color": previous,
    "active_project": project,
    "active_port": int(port),
})
pathlib.Path(output).write_text(json.dumps(data, indent=2) + "\n")
PY

  echo "ROLLBACK PASS"
  echo "  active color: $previous_color (was: $active_color)"
  echo "  artifact=$sfile"
}

cmd_status() {
  local env="$1"
  require_env_arg "$env"
  local pilot_dir
  pilot_dir="$(cd "$2" && pwd)"
  local pilot_name
  pilot_name="$(basename "$pilot_dir")"
  if [ "$env" = "production-like" ]; then
    local color="${3:?production-like status needs a color: blue or green}"
    pl_port "$color" >/dev/null
    docker compose -p "${pilot_name}-productionlike-${color}" -f "$pilot_dir/compose.yaml" ps
  else
    docker compose -p "${pilot_name}-${env}" -f "$pilot_dir/compose.yaml" ps
  fi
}

cmd_teardown() {
  local env="$1"
  require_env_arg "$env"
  local pilot_dir
  pilot_dir="$(cd "$2" && pwd)"
  local pilot_name
  pilot_name="$(basename "$pilot_dir")"
  if [ "$env" = "production-like" ]; then
    local color="${3:?production-like teardown needs a color: blue or green}"
    pl_port "$color" >/dev/null
    local sfile
    sfile="$(state_file "$pilot_name")"
    if [ "$(read_state_field "$sfile" active_color none)" = "$color" ]; then
      echo "Refusing to tear down '$color' -- it is the currently ACTIVE color receiving traffic." >&2
      echo "Promote the other color first, or edit $sfile manually if this is intentional cleanup." >&2
      exit 1
    fi
    docker compose -p "${pilot_name}-productionlike-${color}" -f "$pilot_dir/compose.yaml" down
  else
    docker compose -p "${pilot_name}-${env}" -f "$pilot_dir/compose.yaml" down
  fi
}

case "${1:-}" in
  build)    shift; [ $# -eq 1 ] || usage; cmd_build "$1" ;;
  deploy)   shift; [ $# -eq 2 ] || usage; cmd_deploy "$1" "$2" ;;
  promote)  shift; [ $# -eq 1 ] || usage; cmd_promote "$1" ;;
  rollback) shift; [ $# -eq 1 ] || usage; cmd_rollback "$1" ;;
  status)   shift; [ $# -ge 2 ] || usage; cmd_status "$1" "$2" "${3:-}" ;;
  teardown) shift; [ $# -ge 2 ] || usage; cmd_teardown "$1" "$2" "${3:-}" ;;
  *) usage ;;
esac

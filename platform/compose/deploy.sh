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
#   deploy.sh status   <develop|production-like> <pilot_dir>
#   deploy.sh teardown <develop|production-like> <pilot_dir>
#
# 'deploy' currently only supports the develop environment. production-like
# promotion (develop-validation gate, blue/green swap, human approval,
# rollback) is a separate, not-yet-built work item — see Plan.md
# "production-like blue/green 與 rollback". 'status'/'teardown' accept either
# environment name since they're non-destructive/cleanup-only operations.
#
# Example:
#   platform/compose/deploy.sh build pilots/station1-hello
#   platform/compose/deploy.sh deploy develop pilots/station1-hello

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

cmd_status() {
  local env="$1"
  require_env_arg "$env"
  local pilot_dir
  pilot_dir="$(cd "$2" && pwd)"
  local pilot_name
  pilot_name="$(basename "$pilot_dir")"
  docker compose -p "${pilot_name}-${env}" -f "$pilot_dir/compose.yaml" ps
}

cmd_teardown() {
  local env="$1"
  require_env_arg "$env"
  local pilot_dir
  pilot_dir="$(cd "$2" && pwd)"
  local pilot_name
  pilot_name="$(basename "$pilot_dir")"
  docker compose -p "${pilot_name}-${env}" -f "$pilot_dir/compose.yaml" down
}

case "${1:-}" in
  build)    shift; [ $# -eq 1 ] || usage; cmd_build "$1" ;;
  deploy)   shift; [ $# -eq 2 ] || usage; cmd_deploy "$1" "$2" ;;
  status)   shift; [ $# -eq 2 ] || usage; cmd_status "$1" "$2" ;;
  teardown) shift; [ $# -eq 2 ] || usage; cmd_teardown "$1" "$2" ;;
  *) usage ;;
esac

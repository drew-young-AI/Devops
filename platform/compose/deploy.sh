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
#   platform/compose/deploy.sh build pilots/station2-twin
#   platform/compose/deploy.sh deploy develop pilots/station2-twin
#   platform/compose/deploy.sh promote pilots/station2-twin

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PLATFORM_ROOT/.." && pwd)"

usage() {
  echo "Usage:" >&2
  echo "  $0 build    <pilot_dir>" >&2
  echo "  $0 push     <pilot_dir>" >&2
  echo "  $0 deploy   develop <pilot_dir>" >&2
  echo "  $0 promote  <pilot_dir>                 # blue/green, human-approved" >&2
  echo "  $0 rollback <pilot_dir>                 # flip back, human-approved" >&2
  echo "  $0 status   <develop|production-like> <pilot_dir> [blue|green]" >&2
  echo "  $0 teardown <develop|production-like> <pilot_dir> [blue|green]" >&2
  exit 1
}

# Registry promotion (Plan.md "Registry promotion 與 immutable artifact
# flow"). GitHub Container Registry -- a natural, zero-new-account
# extension of the GitHub account already in use for this repo, not an
# arbitrary choice. Requires VAULT_TOKEN with read access to
# secret/data/devops/github (the devops-readonly policy already grants
# this) -- the GitHub PAT is read from Vault, not ~/.env, closing part of
# the gap noted in platform/vault/README.md's "Known Gaps".
GHCR_OWNER="drew-young-ai"

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

cmd_push() {
  local pilot_dir
  pilot_dir="$(cd "$1" && pwd)"
  local pilot_name
  pilot_name="$(basename "$pilot_dir")"
  local sha
  sha="$(git_sha "$pilot_dir")"
  local registry_image="ghcr.io/${GHCR_OWNER}/${pilot_name}:${sha}"

  if ! docker image inspect "${pilot_name}:dev" >/dev/null 2>&1; then
    echo "No built image found for ${pilot_name}. Run: $0 build $1" >&2
    exit 1
  fi
  if [ -z "${VAULT_TOKEN:-}" ]; then
    echo "VAULT_TOKEN not set. Export a token with read access to secret/data/devops/*" >&2
    echo "(the devops-readonly policy grants this) -- see platform/vault/README.md." >&2
    exit 1
  fi

  echo "=== [push] ${pilot_name}:dev -> $registry_image ==="

  # GHCR requires a classic PAT with write:packages scope -- fine-grained
  # PATs are not supported for GitHub Packages at all, confirmed against
  # GitHub's own docs after the fine-grained token this repo already used
  # for `git push` failed with "permission_denied: ... does not match
  # expected scopes" despite having every repository permission
  # configured. Separate secret path/token from secret/devops/github
  # (that one stays scoped to git operations only).
  local ghcr_pat
  ghcr_pat="$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" vault-vault-1 \
    vault kv get -field=token secret/devops/ghcr)"
  if [ -z "$ghcr_pat" ]; then
    echo "Failed to read GHCR PAT from Vault (secret/devops/ghcr, field=token)." >&2
    exit 1
  fi

  # Docker Desktop's default credsStore ("desktop") opens a macOS Keychain
  # GUI prompt that hangs indefinitely in a non-interactive shell --
  # reproduced this directly (docker login hung past a 2-minute timeout)
  # before switching to a throwaway DOCKER_CONFIG dir with a plain
  # base64 auth entry, which bypasses the credential-helper path entirely.
  local tmp_docker_config
  tmp_docker_config="$(mktemp -d)"
  trap 'rm -rf "$tmp_docker_config"; unset ghcr_pat' RETURN

  local auth_b64
  auth_b64="$(printf '%s:%s' "$GHCR_OWNER" "$ghcr_pat" | base64)"
  cat > "$tmp_docker_config/config.json" <<EOF
{"auths":{"ghcr.io":{"auth":"${auth_b64}"}}}
EOF
  unset auth_b64

  docker tag "${pilot_name}:dev" "$registry_image"
  DOCKER_CONFIG="$tmp_docker_config" docker push "$registry_image"

  local registry_digest
  registry_digest="$(docker image inspect "$registry_image" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo "")"
  # Extract just the sha256:... portion regardless of what repo-name prefix
  # docker put in front of it -- needed to build an unambiguous
  # digest-pinned reference for cosign below.
  local digest_hash=""
  if [ -n "$registry_digest" ]; then
    digest_hash="${registry_digest#*@}"
  fi

  # Image signing is opt-in (SIGN_ARTIFACTS=1), same reasoning as SBOM
  # signing in platform/security/scan_image.sh: every cosign sign
  # publishes a permanent record to the public Sigstore Rekor transparency
  # log, which the user explicitly accepted for this platform but which
  # shouldn't happen silently on every routine push. Reuses the GHCR
  # credentials already staged in $tmp_docker_config -- cosign respects
  # DOCKER_CONFIG the same way `docker push` does.
  local signed="false"
  local signature_ref=""
  if [ "${SIGN_ARTIFACTS:-0}" = "1" ] && [ -n "$digest_hash" ]; then
    local digest_ref="ghcr.io/${GHCR_OWNER}/${pilot_name}@${digest_hash}"
    echo "=== [sign image] $digest_ref ==="
    echo "NOTE: publishes a hash+signature+timestamp record to the public," >&2
    echo "permanent Sigstore Rekor transparency log (see platform/security/" >&2
    echo "sign_artifact.sh's header for what this platform already accepted)." >&2
    if DOCKER_CONFIG="$tmp_docker_config" COSIGN_PASSWORD="" cosign sign \
      --key "$PLATFORM_ROOT/security/keys/cosign.key" \
      --use-signing-config=false --yes "$digest_ref"; then
      signed="true"
      signature_ref="$digest_ref"
      echo "Verifying..."
      DOCKER_CONFIG="$tmp_docker_config" cosign verify \
        --key "$PLATFORM_ROOT/security/keys/cosign.pub" "$digest_ref" \
        && echo "IMAGE VERIFY PASS"
    else
      echo "WARNING: image signing failed; push itself already succeeded, continuing" >&2
    fi
  fi

  local pushed_at
  pushed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  local evidence_dir="$REPO_ROOT/evidence/$pilot_name"
  mkdir -p "$evidence_dir"
  local evidence_file="$evidence_dir/push_${sha}.json"
  python3 - "$evidence_file" "$registry_image" "$registry_digest" "$sha" "$pushed_at" "$signed" "$signature_ref" <<'PY'
import json, pathlib, sys
output, image, digest, commit, pushed_at, signed, sig_ref = sys.argv[1:]
pathlib.Path(output).write_text(json.dumps({
    "registry_image": image,
    "registry_digest": digest or None,
    "commit_sha": commit,
    "pushed_at": pushed_at,
    "signed": signed == "true",
    "signature_ref": sig_ref or None,
}, indent=2) + "\n")
PY

  echo "PUSH PASS"
  echo "  registry_image: $registry_image"
  echo "  registry_digest: ${registry_digest:-<none returned>}"
  echo "  signed: $signed"
  echo "artifact=$evidence_file"
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
  local pilot="$2"
  # Per-pilot template, not a hardcoded one. The previous version named
  # station1-hello directly, so promoting any other pilot would have silently
  # published station1-hello's vhost pointing at the new pilot's port.
  local template="$PLATFORM_ROOT/nginx/conf.d/${pilot}.production-like.conf.template"
  local generated="$PLATFORM_ROOT/nginx/conf.d/_generated.${pilot}.production-like.conf"
  if [ ! -f "$template" ]; then
    echo "No production-like vhost template for '$pilot'." >&2
    echo "Expected: $template" >&2
    echo "A promote without a vhost would start the new colour and route" >&2
    echo "nothing to it, which looks like success and serves the old one." >&2
    exit 1
  fi
  sed "s/__UPSTREAM_PORT__/${port}/" "$template" > "$generated"
}

cmd_deploy() {
  local env="$1"
  if [ "$env" != "develop" ]; then
    echo "'deploy' currently only supports 'develop'." >&2
    echo "production-like is never deployed directly -- it is reached only" >&2
    echo "through '$0 promote <pilot_dir>', which enforces the" >&2
    echo "develop-validation gate, blue/green and human approval." >&2
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

# Surfaces the most recent DAST result before the promote confirmation.
#
# Unlike show_llm_review below, this reports a REAL GATE: DAST examines the
# deployed system, which is the only thing that can find a runtime-only
# problem (a missing security header, an exposed banner, a reachable debug
# endpoint). None of those exist in any file, so no source-level gate will
# ever catch them.
#
# Still display-only here, for a different reason than the LLM review: the
# gate belongs at scan time (scan_dast.sh exits non-zero), not bolted onto
# promote. Re-running a full scan inside promote would make an interactive
# release step take minutes and tempt people to skip it. What promote owes
# the human is the result, and a clear warning when there is no recent scan
# to show.
show_dast_result() {
  local pilot_name="$1"
  local report
  report="$(ls -1 "$REPO_ROOT/evidence/security/dast_summary_"*.json 2>/dev/null | tail -1 || true)"

  echo "--- DAST (deployed-system scan) ---"
  if [ -z "$report" ]; then
    echo "  No DAST result found."
    echo "  Run: platform/security/scan_dast.sh"
    echo ""
    return 0
  fi

  python3 - "$report" <<'PY'
import json, sys, datetime
d = json.load(open(sys.argv[1]))
counts = d["counts_by_risk"]
print(f"  {d['gate_result']}  target={d['target']}")
print(f"  HIGH={counts['HIGH']} MEDIUM={counts['MEDIUM']} LOW={counts['LOW']}"
      f"  ({len(d.get('sites_scanned', [])) or d.get('urls_in_alerts', d.get('urls_examined', 0))} site(s), gate: {d.get('fail_on','?')}+)")
for name in d.get("blocking_alerts", []):
    print(f"    BLOCKING: {name}")
# Age matters more than result: a green scan from three deploys ago says
# nothing about the code about to be promoted.
try:
    when = datetime.datetime.strptime(d["scanned_at"], "%Y%m%dT%H%M%SZ").replace(
        tzinfo=datetime.timezone.utc)
    age_h = (datetime.datetime.now(datetime.timezone.utc) - when).total_seconds() / 3600
    print(f"  scanned {age_h:.1f}h ago" + ("  <-- STALE, re-run before relying on it" if age_h > 24 else ""))
except ValueError:
    pass
print(f"  artifact={sys.argv[1]}")
PY
  echo ""
}

# Surfaces Station 5's LLM-generated evidence (platform/llm-review/) to the
# human standing at the promote confirmation prompt.
#
# Read-only and non-blocking, on purpose. A FAIL verdict prints in full and
# then still lets the human type PROMOTE; a missing review prints a notice
# and still lets them proceed. Making this gate the release would hand the
# LLM production release authority, which NEW_SERVICE_GUIDE.md section 8 and
# Plan-detail.md Station 5 ("產出 LLM-generated evidence，不產出 Human
# Acceptance") both forbid. The point is a better-informed human decision,
# not an automated one.
show_llm_review() {
  local pilot_name="$1" sha="$2"
  local review
  # `|| true` is load-bearing: this script runs under `set -euo pipefail`, so
  # without it the no-review case (ls exits 2, pipefail propagates it) aborts
  # the whole promote. That is the *common* case -- a review is optional --
  # so an advisory display would have killed the release path it was meant to
  # inform. Verified by running this function under `bash -euo pipefail`.
  review="$(ls -1 "$REPO_ROOT/evidence/$pilot_name/llm_review_${sha}_"*.json 2>/dev/null | tail -1 || true)"

  echo "--- LLM review (advisory evidence, not approval) ---"
  if [ -z "$review" ]; then
    echo "  No LLM review evidence for sha=$sha."
    echo "  To generate one: platform/llm-review/review.sh <pilot_dir> $sha"
    echo ""
    return 0
  fi

  python3 - "$review" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if d.get("status") != "OK":
    err = d.get("error") or {}
    print(f"  DEGRADED ({err.get('kind')}): {err.get('detail')}")
    print("  No usable LLM evidence -- human review only.")
else:
    print(f"  verdict: {d['verdict']}   ({d['generated_at']}, model={d['reproducibility']['model']})")
    print(f"  summary: {d['summary']}")
    for f in d.get("findings", []):
        print(f"    [{f.get('severity')}] {f.get('area')}: {f.get('detail')}")
print(f"  artifact={sys.argv[1]}")
PY
  echo ""
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
  show_dast_result "$pilot_name"
  show_llm_review "$pilot_name" "$sha"
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

  write_production_like_vhost "$new_port" "$pilot_name"
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

  # A promote is an EVENT: it happened, it is over, there is nothing to repeat
  # and nothing to resolve. It is also the one thing here that is NEVER
  # scheduled (it waits for a human to type PROMOTE), so the scheduler's own
  # ok->failed notifications can never cover it. Without this line, the single
  # most consequential action on the platform is the one nobody is told about.
  "$REPO_ROOT/platform/notify/emit_event.sh" promote ok \
    "$pilot_name $current_color -> $new_color (sha $sha)" >/dev/null 2>&1 || true

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

  write_production_like_vhost "$prev_port" "$pilot_name"
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
  push)     shift; [ $# -eq 1 ] || usage; cmd_push "$1" ;;
  deploy)   shift; [ $# -eq 2 ] || usage; cmd_deploy "$1" "$2" ;;
  promote)  shift; [ $# -eq 1 ] || usage; cmd_promote "$1" ;;
  rollback) shift; [ $# -eq 1 ] || usage; cmd_rollback "$1" ;;
  status)   shift; [ $# -ge 2 ] || usage; cmd_status "$1" "$2" "${3:-}" ;;
  teardown) shift; [ $# -ge 2 ] || usage; cmd_teardown "$1" "$2" "${3:-}" ;;
  *) usage ;;
esac

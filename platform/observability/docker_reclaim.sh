#!/usr/bin/env bash
# Reclaim Docker disk space on this host, WITHOUT deleting anything that
# cannot be got back or that belongs to someone else.
#
# WHY NOT `docker system prune -a`.
#
# It is the command everyone reaches for and it is wrong here, for two
# independent reasons:
#
#   1. It deletes every image without a running container. On this host that
#      includes station2-ingest:local, station2-mlops:local and the local
#      registry's v15 / v15-green -- images that are BUILT here, exist nowhere
#      else, and whose rebuild needs Docker Hub. The 2026-09-03 ingest failure
#      was caused by exactly that dependency being unavailable.
#   2. It does not know whose images these are. This machine also runs another
#      project's mongo and several MCP server images belonging to other CLIs.
#      platform/backup/backup.sh already records the rule for that case --
#      「不是這個平台的；沒被要求就替別人做資料處置決定，不是我們的權責」 --
#      and a prune would make that decision silently for everything at once.
#
# So this script reclaims only what is provably regenerable AND provably this
# platform's, and it PRINTS the rest as a list for a human to decide on.
#
# WHAT IT ACTUALLY GIVES BACK TO macOS.
#
# The usual answer is "nothing": Docker.raw is described everywhere as a
# grow-only sparse image, so freeing space inside the Linux VM is supposed to
# leave the host file exactly as large as it already was. That claim was
# written into this script first and then MEASURED, on 2026-09-03 with Docker
# Desktop 4.84.0 / engine 29.6.2 on Apple Silicon, and it did not hold:
#
#   before                    24.03 GB allocated to Docker.raw
#   reclaimed inside the VM   ~2.7 GB
#   after, within minutes     22.49 GB allocated -- 1.4 GiB returned to APFS,
#                             stable across three samples 20s apart
#
# The APPARENT size never moves: 926.30 GiB before and after, because that is
# the image's virtual size and has nothing to do with consumption. Check
# `stat -f %b`, never `ls -lh`.
#
# So on this version, pruning does help the host. It is still not a substitute
# for Docker Desktop's own "Reset disk image size" if the file has grown far
# beyond what is in it -- but a runbook saying "pruning cannot free host disk"
# would have sent someone down the destructive path for no reason.
#
# Usage:
#   platform/observability/docker_reclaim.sh --dry-run   report only
#   platform/observability/docker_reclaim.sh             reclaim
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

d() {  # run, or print what would run
  if [ "$DRY" = 1 ]; then echo "    would run: $*"; else "$@"; fi
}

echo "=== before ==="
timeout 120 docker system df || { echo "docker is not answering"; exit 1; }

# ---- the protected set, established from evidence not from memory ---------
# Three sources, unioned:
#   running   an image with a live container is in use by definition
#   declared  an image named in a compose file or script in this repo
#   built     an image produced here that no registry can supply
running="$(timeout 60 docker ps --format '{{.Image}}' | sort -u)"

# `image:` lines in compose files catch the long-running services. They do NOT
# catch the ones this platform starts with `docker run --rm`: the ZAP scanner,
# rclone, promtool. A first version of this script classified those as "not
# ours" -- and since the script prints that list for a human to delete from,
# a report is not harmless just because the script itself deletes nothing.
# Losing zaproxy/zap-stable (3.6GB) would have taken the DAST job with it.
#
# So the test is not "does a compose file declare it" but "does ANY tracked
# file in this repo mention its repository name". That over-includes rather
# than under-includes, which is the correct direction for a delete list.
# ONE pass over the repo, not one per image. platform/ is 3.6GB of virtualenvs
# and Parquet; grepping it 33 times took minutes and would have made this
# script something nobody runs -- and a reclaim script nobody runs reclaims
# nothing. `grep -o -f` finds every repository name in a single traversal.
REPO_TEXT="$(mktemp)"
trap 'rm -f "$REPO_TEXT" "$PATTERNS"' EXIT
PATTERNS="$(mktemp)"
timeout 60 docker images --format '{{.Repository}}' | grep -v '<none>' | sort -u > "$PATTERNS"
# Restricted to source extensions. Excluding directories was not enough:
# platform/ holds Parquet and virtualenv binaries, and grep reading those byte
# by byte is where the minutes went.
grep -rhoFf "$PATTERNS" \
  --include='*.sh' --include='*.py' --include='*.yaml' --include='*.yml' \
  --include='*.md' --include='*.json' --include='*.conf' --include='*.tf' \
  --include='Dockerfile*' --include='Makefile' \
  --exclude-dir=evidence --exclude-dir=.git --exclude-dir=venv \
  --exclude-dir=node_modules --exclude-dir=mirror --exclude-dir=__pycache__ \
  "$REPO_ROOT" 2>/dev/null | sort -u > "$REPO_TEXT"

repo_mentions() {
  grep -qxF "${1%%:*}" "$REPO_TEXT"
}

built="$(timeout 60 docker images --format '{{.Repository}}:{{.Tag}}' \
         | grep -E '^(station2-|localhost:5111/)' | sort -u)"

# Entries carrying an unexpanded variable or placeholder are template text, not
# images; they can never match a real reference either way.
protected="$(printf '%s\n%s\n' "$running" "$built" \
             | grep -vE '[$]|__' | sort -u | sed '/^$/d')"

echo
echo "=== protected: running or built here ==="
sed 's/^/    /' <<<"$protected"

# ---- what is reclaimed ----------------------------------------------------
echo
echo "=== 1. build cache ==="
# Layers only. Rebuilding from cache is a convenience, never a correctness
# requirement, and the cache is the largest purely regenerable thing here.
d docker builder prune -af

echo
echo "=== 2. dangling images (untagged leftovers of local builds) ==="
# Untagged and unreferenced: a previous build of a tag that has since moved.
# Nothing can refer to them by name, so nothing can lose them.
dangling="$(timeout 60 docker images -f dangling=true -q | sort -u)"
if [ -z "$dangling" ]; then
  echo "    none"
else
  d docker rmi $dangling
fi

# ---- what is only REPORTED ------------------------------------------------
echo
echo "=== 3. NOT this platform's -- reported, never deleted ==="
echo "    These have no container running and are named nowhere in this repo."
echo "    They may belong to another project or to another CLI's MCP servers."
echo "    Deleting them is a decision for the person who put them there."
foreign=0
referenced=""
while IFS=$'\t' read -r ref size; do
  [ -z "$ref" ] && continue
  case "$ref" in *"<none>"*) continue ;; esac
  if grep -qxF "$ref" <<<"$protected"; then continue; fi
  if repo_mentions "$ref"; then
    referenced="$referenced$(printf '    %-52s %s' "$ref" "$size")"$'\n'
    continue
  fi
  printf '    %-52s %s\n' "$ref" "$size"
  foreign=1
done < <(timeout 60 docker images --format '{{.Repository}}:{{.Tag}}	{{.Size}}' | sort)
[ "$foreign" = 0 ] && echo "    none"

echo
echo "=== 4. mentioned somewhere in this repo -- kept, decide by hand ==="
echo "    Matched on REPOSITORY name, tag ignored, which over-includes on"
echo "    purpose: for a delete list, a false keep costs disk and a false"
echo "    delete costs the thing itself. Two kinds land here and they are not"
echo "    the same -- most are started on demand (zaproxy by scan_dast.sh,"
echo "    rclone by sync_remote.sh, so 'not running' means intermittent, not"
echo "    idle) but mongo is here because backup.sh names it to record that it"
echo "    belongs to ANOTHER project. A mention is evidence of a reference,"
echo "    not evidence of ownership."
if [ -n "$referenced" ]; then printf '%s' "$referenced"; else echo "    none"; fi

echo
echo "=== after ==="
timeout 120 docker system df

cat <<'NOTE'

The figures above are INSIDE the Linux VM. What reaches macOS is a separate
question -- on Docker Desktop 4.84 the host file does shrink, by roughly half
of what was freed and with a lag of minutes. Measure it rather than assuming
either way, and read `allocated`, never `ls -lh`:

  platform/observability/host_disk_metrics.sh --stdout | grep docker_disk
NOTE

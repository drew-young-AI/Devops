#!/usr/bin/env bash
# Run the CI tier on the Linux node, before pushing.
#
# WHY THIS EXISTS.
#
# CI runs `PLATFORM_TIERS=1 platform/tests/run_all.sh` on ubuntu-latest. This
# repository develops on macOS. Between 2026-09-03 04:09 and 12:01 that gap
# produced four consecutive red CI runs, and every one of them was green on the
# Mac when it was pushed:
#
#   host_disk_metrics.sh hardcoded /System/Volumes/Data   macOS-only path
#   lib.sh / two suites used `sed -i ''`                  BSD-only spelling;
#                                                         on GNU it reads the
#                                                         script as a filename
#                                                         and every mutation
#                                                         silently does nothing
#   source_frequency_check.py shelled out to `docker`     absent on Linux, so
#                                                         a FileNotFoundError
#                                                         became a false defect
#
# ADR-0008 says this platform spans two instruction sets and two operating
# systems. It has said so since 2026-08-31. Nothing checked the second one
# until the second machine was switched on, and the first thing it found was
# three defects that had already been pushed.
#
# The fourth was found by this script on its first run: test_loki_coverage.sh's
# synthetic controls copied LIVE Loki metrics when Loki happened to be up, and
# an empty file when it was not -- so on this Mac they passed and everywhere
# else six of them failed. A control whose input depends on the environment is
# not a control.
#
# WHAT IT IS NOT.
#
# Not a replacement for CI: it runs from a working-tree copy, on one Linux
# machine, with whatever is installed there. It answers "would tier 1 pass on
# Linux" earlier and cheaper, and CI still answers it authoritatively.
#
# The copy is deliberate. Running the suite against a checkout on ubu would
# test what was last committed; the point is to test what is about to be.
#
# Usage:
#   platform/tests/run_on_ubu.sh            sync and run tier 1
#   platform/tests/run_on_ubu.sh --sync     sync only
set -uo pipefail

HOST="${UBU_HOST:-ubu}"
DEST="${UBU_DEST:-devops-ci}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

if ! timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" true 2>/dev/null; then
  echo "  SKIP  $HOST is not reachable -- Linux verification is UNVERIFIED"
  echo "        (it is a laptop and suspend is still enabled; see"
  echo "         docs/Ubu-Prod-Bringup.md §3.1)"
  exit 0
fi

echo "=== syncing working tree to $HOST:~/$DEST ==="
# archives/ is 3.3GB of backup tarballs and mirror/ is a rebuildable Parquet
# copy: neither is input to any tier-1 suite, and including them turned a
# 20-second sync into a ten-minute one on the first attempt.
rsync -a --delete \
  --exclude='.git/' \
  --exclude='platform/backup/archives/' \
  --exclude='**/venv/' \
  --exclude='**/__pycache__/' \
  --exclude='platform/analytics/mirror/' \
  "$REPO_ROOT/" "$HOST:$DEST/" || exit 1

# A git index, not the repository's history. Five suites enumerate their
# subject with `git ls-files`, and without an index they walk an empty tree and
# report "0 orphans" -- a clean bill of health from a scan that visited
# nothing, which those very suites exist to refuse. Their own floor checks
# caught it, which is the only reason this is a paragraph and not a silent pass.
ssh -o BatchMode=yes "$HOST" "cd ~/$DEST \
  && (git rev-parse --git-dir >/dev/null 2>&1 || git init -q) \
  && git config user.email ci@local && git config user.name ci \
  && git add -A >/dev/null 2>&1 && git commit -qm 'linux verification snapshot' >/dev/null 2>&1; true"

[ "${1:-}" = "--sync" ] && { echo "synced only"; exit 0; }

echo
echo "=== tier 1 on $HOST ($(ssh -o BatchMode=yes "$HOST" 'uname -s -m')) ==="
ssh -o BatchMode=yes "$HOST" "cd ~/$DEST && PLATFORM_TIERS=1 bash platform/tests/run_all.sh"

#!/usr/bin/env bash
# Minimal assertion + sandbox helpers for the platform's own test suite.
#
# Deliberately dependency-free (no bats, no shunit2): the platform's other
# scripts are plain bash + system python3, and a test suite that needs
# `brew install` before it runs is a test suite that stops being run.
#
# Sandbox model: platform scripts derive REPO_ROOT from their own path
# (`$(dirname $0)/../..`), so tests get isolation by copying `platform/`
# into a temp directory and invoking the copy. No production code needed a
# test-only environment override, which keeps the tested code identical to
# the shipped code.

set -uo pipefail

TESTS_PASSED=0
TESTS_FAILED=0
FAILURE_LOG=""
CURRENT_SUITE="${CURRENT_SUITE:-}"

# Captured by run_cmd
LAST_RC=0
LAST_STDOUT=""
LAST_STDERR=""

_repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

REPO_ROOT="$(_repo_root)"

# --- assertions ---------------------------------------------------------

_pass() {
  TESTS_PASSED=$((TESTS_PASSED + 1))
  printf '  \033[32mPASS\033[0m %s\n' "$1"
}

_fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  printf '       %s\n' "$2"
  FAILURE_LOG="${FAILURE_LOG}\n  - ${CURRENT_SUITE}: $1\n      $2"
}

# A MISTYPED ASSERTION MUST FAIL THE SUITE, NOT VANISH.
#
# These suites deliberately do not use `set -e`: an assertion that fails has
# to let the rest of the file keep running, and several tests exist precisely
# to observe a non-zero exit. The cost is that calling a helper that does not
# exist exits 127 and is simply ignored -- so the assertion never runs, and
# the suite reports green for a check it did not perform. That is strictly
# worse than a red test, because nothing indicates the gap.
#
# Not hypothetical: two calls to `assert_contains` (no such helper -- the real
# one is assert_output_contains) sat in test_scheduler.sh and the suite still
# printed "0 failed" while silently skipping both checks.
#
# The obvious fix, bash's `command_not_found_handle` hook, is NOT usable here:
# it arrived in bash 4.0 and macOS ships 3.2.57. Defining it looks like a
# safety net and silently does nothing, which is the same class of mistake.
# The guard therefore lives in test_static.sh as an undefined-helper scan,
# which does not depend on the shell version.

# run_cmd <description> -- <command...>
# Never lets a non-zero exit kill the suite; that IS the thing under test.
# Every call leaks two temp files unless they are tracked. Individually tiny,
# but a full run makes ~500 of them and they were never removed: 8,188 stray
# entries had built up in $TMPDIR alongside the sandbox directories. Same
# defect as the sandboxes, three orders of magnitude smaller, and invisible for
# exactly that reason.
#
# A FILE HERE TOO, and for the same reason as the sandbox registry. The first
# fix used an array, on the argument that run_cmd is called directly rather
# than through command substitution. That is true of most calls and not of all:
# a suite writing `X="$(run_cmd ...; cat "$LAST_STDOUT")"` runs run_cmd in a
# subshell, the array append is lost with it, and the two files stay. It was
# one leaked 20-byte file per run of test_backup_coverage.sh -- small enough to
# dismiss, and the same defect that had just cost 421GB one directory over.
run_cmd() {
  LAST_STDOUT="$(mktemp)"
  LAST_STDERR="$(mktemp)"
  printf '%s\n%s\n' "$LAST_STDOUT" "$LAST_STDERR" >> "$SANDBOX_REGISTRY"
  "$@" >"$LAST_STDOUT" 2>"$LAST_STDERR"
  LAST_RC=$?
  return 0
}

assert_rc() {
  local expected="$1" desc="$2"
  if [ "$LAST_RC" = "$expected" ]; then
    _pass "$desc"
  else
    _fail "$desc" "expected exit $expected, got $LAST_RC. stderr: $(head -3 "$LAST_STDERR" | tr '\n' ' ')"
  fi
}

assert_output_contains() {
  local needle="$1" desc="$2"
  if grep -qF -- "$needle" "$LAST_STDOUT" "$LAST_STDERR" 2>/dev/null; then
    _pass "$desc"
  else
    _fail "$desc" "output did not contain: $needle"
  fi
}

assert_output_not_contains() {
  local needle="$1" desc="$2"
  if grep -qF -- "$needle" "$LAST_STDOUT" "$LAST_STDERR" 2>/dev/null; then
    _fail "$desc" "output unexpectedly contained: $needle"
  else
    _pass "$desc"
  fi
}

# The Prometheus image the platform ACTUALLY RUNS, read out of compose rather
# than pinned a second time here.
#
# It was pinned twice, and the two copies had drifted: compose ran v3.5.0 while
# every promtool check in this suite ran v3.6.0. So the rules were being
# validated by a version that does not evaluate them, which is the same shape
# as validating a deployment against a config file the server never reads --
# a green check about a different system. Reading it from the one file that
# decides what runs makes the two impossible to disagree.
prom_image() {
  awk '/^  prometheus:/{f=1} f && /image:/{print $2; exit}' \
    "$REPO_ROOT/platform/observability/compose.yaml"
}

# sed_i <script> <file> -- portable in-place edit.
#
# GNU sed takes the backup suffix ATTACHED to the flag (`-i.bak`, or `-i` for
# none). BSD/macOS sed takes it as a SEPARATE argument, so `-i ''` is how you
# say "no backup" there. The two spellings are mutually incompatible, and the
# BSD form on GNU does not error at the flag -- it reads `''` as the script and
# the real script as a FILENAME:
#
#   sed: can't read s|for: 15m|for: 0m|: No such file or directory
#
# That is what CI reported on 2026-09-03. Every mutation in the suite silently
# changed nothing and the output said "mutant survived", which reads as a
# defect in the rules and was a defect in the test -- on Linux only, while the
# Mac stayed green. Same shape as the BSD-vs-GNU `stat` rule test_static.sh
# already enforces, and the reason ADR-0008 exists: this platform now runs on
# two operating systems and a macOS-only spelling is a latent outage on the
# other one.
sed_i() {
  local script="$1" file="$2"
  if sed --version >/dev/null 2>&1; then
    sed -i -e "$script" "$file"        # GNU
  else
    sed -i '' -e "$script" "$file"     # BSD / macOS
  fi
}

# mutate <file> <sed-script> <description>
#
# Apply an in-place edit for a mutation test, and FAIL if it changed nothing.
#
# A mutation that does not apply is indistinguishable from a mutant that
# survives: both end with the suite reporting a failure that reads as a defect
# in the code under test. That happened on 2026-09-03 -- sed patterns left over
# from an earlier spelling of a matcher silently changed nothing, and the
# output said "mutant survived", which is a claim about the rules and was
# actually a claim about the test. Verifying the edit landed separates the two.
mutate() {
  local file="$1" script="$2" desc="$3" before
  before="$(cksum < "$file")"
  sed_i "$script" "$file"
  if [ "$before" = "$(cksum < "$file")" ]; then
    _fail "mutation applies: $desc" "sed changed nothing -- the pattern is stale"
    return 1
  fi
  return 0
}

assert_file_exists() {
  local path="$1" desc="$2"
  if [ -f "$path" ]; then _pass "$desc"; else _fail "$desc" "missing file: $path"; fi
}

assert_equals() {
  local expected="$1" actual="$2" desc="$3"
  if [ "$expected" = "$actual" ]; then
    _pass "$desc"
  else
    _fail "$desc" "expected '$expected', got '$actual'"
  fi
}

# --- sandbox ------------------------------------------------------------

# A FILE, NOT AN ARRAY -- and that is the whole bug this replaces.
#
# Every caller writes `SANDBOX="$(make_sandbox)"`. Command substitution runs in
# a SUBSHELL, so `SANDBOXES+=("$sandbox")` appended to the subshell's copy and
# the parent's array stayed empty forever. cleanup_sandboxes then iterated
# nothing and deleted nothing -- not just on an abnormal exit, but on EVERY
# run. Sandboxes were never cleaned up at all.
#
# This repo has the identical shape on record already: a synthetic control
# whose counter was incremented inside `$(...)` and never reached 3. Same
# mistake, three weeks apart, in the same file. A subshell is where state goes
# to be forgotten.
#
# A file survives the subshell because the write is to the filesystem, not to
# the shell's memory. run_cmd keeps an array on purpose: it is called directly
# rather than through substitution, so its array IS the parent's.
SANDBOX_REGISTRY="${SANDBOX_REGISTRY:-$(mktemp)}"
export SANDBOX_REGISTRY

# Creates an isolated repo root containing a copy of platform/ plus a fake
# pilot, and echoes its path. Everything the scripts write (evidence, state,
# generated nginx conf) lands inside it and is discarded on cleanup.
# What a sandbox must NOT carry.
#
# `cp -R platform` copied platform/backup/archives with it -- 3.3GB of backup
# tarballs, into every sandbox, for tests that reference none of them. Each
# sandbox was 3.6GB where 300MB would do.
#
# Combined with the missing trap below, 124 of them accumulated in $TMPDIR
# between 2026-09-01 and 2026-09-03: 427GB, the dominant consumer of a 926GB
# volume, and the accumulation window covers the disk-full outage on
# 2026-09-03 that stopped the entire platform. The test suite was filling the
# disk, and nothing connected the two because nothing measured the disk --
# which is the gap alerts/host-capacity.yml was built to close, one level up
# from its actual cause.
#
# Excluded by NAME, listed here, rather than by a size threshold: a threshold
# would silently start excluding something a test needs the day that thing
# grows.
SANDBOX_EXCLUDE=(
  "backup/archives"      # 3.3GB of tarballs; no test reads one
  "backup/snapshots"     # same shape, same reason
  "analytics/venv"       # rebuildable by analytics/setup.sh
  "analytics/mirror"     # rebuildable Parquet copy
)

make_sandbox() {
  local sandbox ex args=()
  sandbox="$(mktemp -d)"
  printf '%s\n' "$sandbox" >> "$SANDBOX_REGISTRY"
  for ex in "${SANDBOX_EXCLUDE[@]}"; do
    args+=(--exclude="$ex")
  done
  # rsync rather than cp -R: cp has no exclude. Falls back to cp when rsync is
  # absent, because a missing rsync must not silently stop the suite -- but the
  # fallback says so, since it is the expensive path.
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "${args[@]}" "$REPO_ROOT/platform/" "$sandbox/platform/"
  else
    echo "  NOTE  rsync absent -- sandbox copies platform/ whole (slow, large)" >&2
    cp -R "$REPO_ROOT/platform" "$sandbox/platform"
  fi
  mkdir -p "$sandbox/evidence" "$sandbox/pilots/fake-pilot"
  # Minimal pilot: only needs to exist and be `cd`-able. Tests here never
  # reach docker, by design -- see test_deploy_contract.sh's header.
  printf 'services:\n  hello:\n    image: fake\n' > "$sandbox/pilots/fake-pilot/compose.yaml"
  echo "$sandbox"
}

# The sha deploy.sh will compute for a sandbox pilot. Mirrors git_sha()
# exactly rather than hardcoding "local-uncommitted", so the tests keep
# working if a sandbox ever lands inside a git worktree.
sandbox_sha() {
  git -C "$1" rev-parse --short HEAD 2>/dev/null || echo "local-uncommitted"
}

write_json() {
  local path="$1" content="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
}

# Same as make_sandbox, but the sandbox is a real git repo with one commit.
# Needed by scripts that resolve and verify a git ref (review.sh), which
# cannot run in a non-repo directory. Identity is passed via -c so the
# machine's global git config is neither read from nor written to.
make_git_sandbox() {
  local sandbox
  sandbox="$(make_sandbox)"
  git -C "$sandbox" init -q
  git -C "$sandbox" -c user.email=test@example.invalid -c user.name=test \
    commit -q --allow-empty -m "sandbox base"
  echo "$sandbox"
}

STUB_PIDS=()

# start_stub <port> <fixture_json_path> -- backgrounds a stub and waits for
# it to accept connections, so tests never race the server's startup.
start_stub() {
  local port="$1" fixture="$2"
  python3 "$REPO_ROOT/platform/tests/stub_http.py" "$port" "$fixture" &
  STUB_PIDS+=("$!")
  # Drop it from the job table: otherwise bash prints "Terminated: 15" for
  # every stub we kill, burying real test output in noise.
  disown 2>/dev/null || true
  local i
  for i in $(seq 1 50); do
    if nc -z 127.0.0.1 "$port" 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  echo "stub on port $port never came up" >&2
  return 1
}

stop_stubs() {
  local pid
  for pid in ${STUB_PIDS+"${STUB_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  STUB_PIDS=()
}

# Cleanup on ANY exit, not just the tidy one.
#
# cleanup_sandboxes was called from suite_summary() alone, so a suite that took
# an early `exit 0` on a SKIP path, or was interrupted, left its whole sandbox
# behind. CLAUDE.md §5c already requires that a test which mutates state
# restores it in a trap; that rule was being read as being about FILES, and a
# multi-gigabyte directory in $TMPDIR is state too.
#
# Registered here, at source time, so every suite gets it without remembering.
# suite_summary still calls cleanup_sandboxes directly: the trap is the safety
# net, not the mechanism, and a net nobody has fallen into is cheap to keep.
# COMPOSABLE EXIT HANDLERS.
#
# `trap X EXIT` REPLACES whatever was registered before it, so a suite that
# registered its own cleanup silently discarded lib.sh's -- and ten of them
# did. They survived only because suite_summary also calls cleanup_sandboxes
# on the tidy path; the safety net for an early exit was gone in exactly the
# suites that had thought about cleanup hardest.
#
# on_exit accumulates instead of replacing. Suites call it; nothing calls trap
# directly, and test_static.sh enforces that.
_EXIT_HANDLERS=()

on_exit() { _EXIT_HANDLERS+=("$1"); }

_run_exit_handlers() {
  local h
  for h in ${_EXIT_HANDLERS+"${_EXIT_HANDLERS[@]}"}; do
    eval "$h" || true
  done
  cleanup_sandboxes
}

trap _run_exit_handlers EXIT INT TERM

cleanup_sandboxes() {
  stop_stubs
  # One registry for both: directories are removed with -rf, files with -f, and
  # the entry says which by what it IS rather than by which list it came from.
  local box
  if [ -n "${SANDBOX_REGISTRY:-}" ] && [ -f "$SANDBOX_REGISTRY" ]; then
    while IFS= read -r box; do
      [ -z "$box" ] && continue
      if [ -d "$box" ]; then rm -rf "$box"
      elif [ -f "$box" ]; then rm -f "$box"
      fi
    done < "$SANDBOX_REGISTRY"
    : > "$SANDBOX_REGISTRY"
  fi
  [ -n "${SANDBOX_REGISTRY:-}" ] && [ -f "$SANDBOX_REGISTRY" ] && rm -f "$SANDBOX_REGISTRY"
  return 0
}

suite_summary() {
  echo ""
  echo "  $TESTS_PASSED passed, $TESTS_FAILED failed"
  cleanup_sandboxes
  [ "$TESTS_FAILED" -eq 0 ]
}

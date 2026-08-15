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

# run_cmd <description> -- <command...>
# Never lets a non-zero exit kill the suite; that IS the thing under test.
run_cmd() {
  LAST_STDOUT="$(mktemp)"
  LAST_STDERR="$(mktemp)"
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

SANDBOXES=()

# Creates an isolated repo root containing a copy of platform/ plus a fake
# pilot, and echoes its path. Everything the scripts write (evidence, state,
# generated nginx conf) lands inside it and is discarded on cleanup.
make_sandbox() {
  local sandbox
  sandbox="$(mktemp -d)"
  SANDBOXES+=("$sandbox")
  cp -R "$REPO_ROOT/platform" "$sandbox/platform"
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

cleanup_sandboxes() {
  stop_stubs
  local box
  for box in ${SANDBOXES+"${SANDBOXES[@]}"}; do
    [ -n "$box" ] && [ -d "$box" ] && rm -rf "$box"
  done
}

suite_summary() {
  echo ""
  echo "  $TESTS_PASSED passed, $TESTS_FAILED failed"
  cleanup_sandboxes
  [ "$TESTS_FAILED" -eq 0 ]
}

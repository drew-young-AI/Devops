#!/usr/bin/env bash
# The AppRole must actually reach the pilot's env file, with the right mode.
#
# WHY THIS SUITE EXISTS (2026-09-01).
#
# `.gitignore` reserved `pilots/station2-twin/.env.vault` weeks ago, with a
# comment describing it as "AppRole secret_id delivered to the pilot container".
# Nothing wrote it and nothing read it. The pilot therefore took its AppRole
# from whatever the operator's shell happened to export, and the app falls back
# to the static database password when that is empty.
#
# The fallback is deliberate -- the pilot must run without Vault. Reaching it by
# accident is not. After the host slept and `recover.sh` brought everything
# back, the develop copy returned on `mode: static` while the Kubernetes copy,
# whose deploy script syncs its own Secret, returned on `mode: vault`. The two
# copies had swapped credential models compared with the same morning, and the
# only thing that noticed was a comparison written hours earlier.
#
# Everything here runs against SYNTHETIC AppRole material in a sandbox. No real
# secret_id is read, written, or printed.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="approle-env"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== the pilot's AppRole must be delivered, not assumed =="

WRITER="$REPO_ROOT/platform/vault/scripts/write_pilot_approle_env.sh"
assert_file_exists "$WRITER" "the writer exists"

# A sandbox repo root: the script derives every path from its own location, so
# a copy of it under a temp tree writes entirely inside that tree.
BOX="$(mktemp -d)"
mkdir -p "$BOX/platform/vault/scripts" "$BOX/pilots/fake-pilot"
cp "$WRITER" "$BOX/platform/vault/scripts/"

# --- refuses, loudly, when there is no AppRole ------------------------------
#
# The important half. Silence here is what produced the incident: recovery
# continued, the pilot started on the static password, and nothing said so.
run_cmd bash "$BOX/platform/vault/scripts/write_pilot_approle_env.sh" fake-pilot
assert_rc 1 "refuses when the AppRole file is absent"
assert_output_contains "STATIC database password" \
  "names the consequence, not just the missing file"
if [ -f "$BOX/pilots/fake-pilot/.env.vault" ]; then
  _fail "writes no env file when it has no AppRole" ".env.vault was created anyway"
else
  _pass "writes no env file when it has no AppRole"
fi

# --- writes the env file from a synthetic AppRole ---------------------------
cat > "$BOX/platform/vault/.fake-pilot-approle.json" <<'EOF'
{
  "role_id": "00000000-1111-2222-3333-444444444444",
  "secret_id": "SYNTHETIC-SECRET-ID-FOR-TESTS-ONLY"
}
EOF
run_cmd bash "$BOX/platform/vault/scripts/write_pilot_approle_env.sh" fake-pilot
assert_rc 0 "writes the env file when the AppRole is present"
assert_file_exists "$BOX/pilots/fake-pilot/.env.vault" "the env file lands where compose reads it"

ENV_FILE="$BOX/pilots/fake-pilot/.env.vault"
KEYS="$(grep -oE '^VAULT_[A-Z_]+' "$ENV_FILE" 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//')"
assert_equals "VAULT_ROLE_ID,VAULT_SECRET_ID" "$KEYS" \
  "carries exactly the two variables compose.yaml reads"

VALUE="$(grep '^VAULT_SECRET_ID=' "$ENV_FILE" | cut -d= -f2-)"
assert_equals "SYNTHETIC-SECRET-ID-FOR-TESTS-ONLY" "$VALUE" \
  "the secret_id arrives intact -- an env file that mangles it fails at login, not here"

# --- the file must not be world-readable ------------------------------------
#
# Created under a umask rather than chmod'ed afterwards: a chmod leaves a window
# in which the file exists and anyone can read it. Checked because that window
# is invisible in review and obvious in a mode bit.
MODE="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || stat -c '%a' "$ENV_FILE" 2>/dev/null)"
assert_equals "600" "$MODE" "the env file is owner-only (600)"

# --- the secret must never appear in the script's own output ----------------
#
# The script prints a confirmation line. A confirmation that echoes the secret
# puts it in every terminal scrollback and CI log that ever runs recovery.
if grep -qF "SYNTHETIC-SECRET-ID-FOR-TESTS-ONLY" "$LAST_STDOUT" "$LAST_STDERR" 2>/dev/null; then
  _fail "never prints the secret_id" "the secret appeared in the script's output"
else
  _pass "never prints the secret_id"
fi

# --- an AppRole file missing a field is refused, not written empty ----------
cat > "$BOX/platform/vault/.fake-pilot-approle.json" <<'EOF'
{ "role_id": "00000000-1111-2222-3333-444444444444" }
EOF
rm -f "$ENV_FILE"
run_cmd bash "$BOX/platform/vault/scripts/write_pilot_approle_env.sh" fake-pilot
assert_rc 1 "refuses an AppRole file with no secret_id"
if [ -f "$ENV_FILE" ]; then
  _fail "writes no env file from an incomplete AppRole" ".env.vault was created from partial data"
else
  _pass "writes no env file from an incomplete AppRole"
fi

rm -rf "$BOX"
suite_summary

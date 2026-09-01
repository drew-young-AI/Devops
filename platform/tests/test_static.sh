#!/usr/bin/env bash
# Static gates over the platform's own source.
#
# Cheap, and catches the class of break that is otherwise only discovered by
# running a real deploy: a syntax error in a 600-line bash script that sits
# in an `if` branch nobody exercised. `bash -n` costs milliseconds and would
# have caught it before the daemon was ever touched.

set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="static"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

# Third-party code is not our code. platform/analytics/venv/ holds thousands of
# vendored .py and .sh files, and running our style gates over them turns a
# report about this repo into a report about other people's packaging -- the
# assertion count jumped from 226 to 830 the moment the venv appeared. Same
# defect okf_check.py had on the same day, for the same reason.
PRUNE_VENV="-not -path */venv/* -not -path */site-packages/* -not -path */node_modules/*"

echo "== static analysis =="

while IFS= read -r script; do
  rel="${script#"$REPO_ROOT/"}"
  if bash -n "$script" 2>/dev/null; then
    _pass "bash syntax: $rel"
  else
    _fail "bash syntax: $rel" "$(bash -n "$script" 2>&1 | head -2)"
  fi
  if [ -x "$script" ]; then
    _pass "executable bit: $rel"
  else
    _fail "executable bit: $rel" "script is not executable; callers will need an explicit interpreter"
  fi
done < <(find "$REPO_ROOT/platform" -name '*.sh' -type f $PRUNE_VENV | sort)

while IFS= read -r module; do
  rel="${module#"$REPO_ROOT/"}"
  if python3 -m py_compile "$module" 2>/dev/null; then
    _pass "python syntax: $rel"
  else
    _fail "python syntax: $rel" "$(python3 -m py_compile "$module" 2>&1 | tail -2)"
  fi
done < <(find "$REPO_ROOT/platform" -name '*.py' -type f -not -path '*__pycache__*' $PRUNE_VENV | sort)

# YAML that only fails at container start is YAML that fails in production.
while IFS= read -r doc; do
  rel="${doc#"$REPO_ROOT/"}"
  if python3 -c "import yaml,sys; list(yaml.safe_load_all(open('$doc')))" 2>/dev/null; then
    _pass "yaml parses: $rel"
  else
    _fail "yaml parses: $rel" "$(python3 -c "import yaml; list(yaml.safe_load_all(open('$doc')))" 2>&1 | tail -2)"
  fi
done < <(find "$REPO_ROOT/platform" \( -name '*.yml' -o -name '*.yaml' \) -type f $PRUNE_VENV | sort)

# Prometheus rule files have a schema beyond "valid YAML": a rule with a
# typo'd key parses fine and then never fires.
while IFS= read -r rules; do
  rel="${rules#"$REPO_ROOT/"}"
  ok="$(python3 -c "
import yaml
d = yaml.safe_load(open('$rules'))
groups = d.get('groups') or []
problems = []
for g in groups:
    if not g.get('name'):
        problems.append('group without name')
    for r in g.get('rules') or []:
        # Two kinds of rule live in these files. A RECORDING rule has no
        # severity and no summary and should not be asked for them; an ALERT
        # rule without them fires into a message nobody can act on. Treating
        # them alike would either reject every recording rule or stop checking
        # alerts, and the second failure is silent.
        if r.get('record'):
            if not r.get('expr'):
                problems.append(f\"record {r['record']}: no expr\")
            continue
        if not r.get('alert'):
            problems.append('rule with neither alert: nor record:')
        if not r.get('expr'):
            problems.append(f\"{r.get('alert')}: no expr\")
        if not (r.get('labels') or {}).get('severity'):
            problems.append(f\"{r.get('alert')}: no severity label\")
        if not (r.get('annotations') or {}).get('summary'):
            problems.append(f\"{r.get('alert')}: no summary annotation\")
print('; '.join(problems))
" 2>&1)"
  assert_equals "" "$ok" "alert rules well-formed: $rel"
done < <(find "$REPO_ROOT/platform/observability/prometheus/alerts" -name '*.yml' -type f 2>/dev/null | sort)

# `docker exec -i` attaches the caller's stdin. That has now caused three
# separate failures in this repo, each one silent and each one looking like
# something else entirely:
#
#   1. restore_drill.sh -- the unseal loop applied one key and exited, with
#      Vault left sealed at 1/3 and no error printed. docker had eaten the
#      remaining keys from the `while read` loop's input.
#   2. audit_query.sh -- every query returned zero records, because the
#      heredoc was python's stdin and the piped log was discarded.
#   3. verify_identity.sh -- the whole suite hung for seven minutes on
#      `policy write evil -`, which waits on stdin forever.
#
# Three occurrences is a class, not a coincidence. This check makes the class
# fail the build instead of costing another debugging session: every
# `docker exec -i` must either close stdin (`</dev/null`), deliberately
# redirect something into it (`< file`), or be marked `# stdin: intentional`.
while IFS= read -r script; do
  rel="${script#"$REPO_ROOT/"}"
  unguarded="$(python3 - "$script" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
bad = []
for i, line in enumerate(lines):
    if "docker exec -i" not in line or line.lstrip().startswith("#"):
        continue
    # Follow bash line-continuations to the end of the logical command, and
    # include the two preceding lines so the `# stdin: intentional` marker can
    # sit above the command, where a reader would naturally write it.
    j, chunk = i, lines[max(0, i - 2):i] + [line]
    while lines[j].rstrip().endswith("\\") and j + 1 < len(lines):
        j += 1
        chunk.append(lines[j])
    text = " ".join(chunk)
    if "/dev/null" in text or re.search(r'<\s*["$\w/]', text) or "stdin: intentional" in text:
        continue
    bad.append(str(i + 1))
print(",".join(bad))
PY
)"
  if [ -z "$unguarded" ]; then
    _pass "docker exec -i stdin guarded: $rel"
  else
    _fail "docker exec -i stdin guarded: $rel" \
      "unguarded at line(s) $unguarded -- add </dev/null, an explicit redirect, or '# stdin: intentional'"
  fi
# This file is excluded because it necessarily contains the pattern it
# searches for. Excluded by path rather than by loosening the pattern: a
# looser pattern would stop catching the real cases too.
done < <(grep -rl "docker exec -i" "$REPO_ROOT/platform" --include='*.sh' \
           | grep -v '/tests/test_static.sh$' | sort)

# Bash 4 builtins on a bash 3.2 host.
#
# macOS ships bash 3.2.57 and `#!/usr/bin/env bash` resolves to it. `bash -n`
# above does NOT catch this: `mapfile` is a builtin lookup at RUN time, so a
# script using it parses cleanly and then exits 127 the first time that line
# runs. set_rotation_policy.sh did exactly that on 2026-08-25 -- found by a
# self-test, not by the gate that exists to find this kind of thing.
#
# Checked by pattern rather than by running anything, because the failing line
# may sit behind a condition no test reaches.
while IFS= read -r script; do
  rel="${script#$REPO_ROOT/}"
  hits="$(grep -nE '(^|[^[:alnum:]_])(mapfile|readarray)[[:space:]]|declare[[:space:]]+-A[[:space:]]|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)\}' "$script" \
            | grep -v 'has no `mapfile`' | cut -d: -f1 | paste -sd, - | tr -d ' ')"
  if [ -z "$hits" ]; then
    _pass "bash 3.2 compatible: $rel"
  else
    _fail "bash 3.2 compatible: $rel" \
      "bash 4 builtin/expansion at line(s) $hits -- macOS bash is 3.2, this exits 127 at run time"
  fi
# Excluded for the same reason as the stdin check above: this file necessarily
# contains the patterns it searches for.
done < <(find "$REPO_ROOT/platform" -name '*.sh' -type f $PRUNE_VENV \
           | grep -v '/tests/test_static.sh$' | sort)

# Generated-from-template drift.
#
# deploy.sh renders _generated.*.conf from its .template ONLY during promote
# and rollback. So an edit to the template -- including a security fix -- has
# no effect on production-like until the next release, while the repo reads
# as though the fix is applied everywhere.
#
# That is not hypothetical: a Cross-Origin-Resource-Policy header added to
# the template after a DAST finding was live on develop and silently absent
# from production-like, because nothing had promoted since. Found by curling
# the vhost, not by reading the config.
while IFS= read -r generated; do
  rel="${generated#"$REPO_ROOT/"}"
  template="${generated/_generated./}"
  template="${template}.template"
  # Re-render the template exactly the way deploy.sh does and compare. An
  # earlier attempt tried to reverse-normalise the port back out of the
  # generated file and failed on its own in-sync case: the substitution also
  # rewrites the port inside a comment, so no regex round-trips cleanly.
  # Rendering forward is what deploy.sh does, so it is what the check does.
  #
  # Either blue or green may legitimately be active, so a match against
  # either rendering passes.
  if [ ! -f "$template" ]; then
    _fail "template exists for $rel" "no matching .template"
    continue
  fi
  matched=0
  for port in 18081 18082; do
    if diff -q <(sed "s/__UPSTREAM_PORT__/${port}/g" "$template") "$generated" >/dev/null 2>&1; then
      matched=1
      break
    fi
  done
  if [ "$matched" = "1" ]; then
    _pass "generated config matches its template: $rel"
  else
    _fail "generated config matches its template: $rel" \
      "template changed but $rel was not re-rendered -- production-like is still serving the old config. Re-run promote, or re-render it."
  fi
done < <(find "$REPO_ROOT/platform/nginx/conf.d" -name '_generated.*.conf' -type f 2>/dev/null | sort)

# OKF v0.1 conformance for the repo's markdown.
#
# Adopting a documentation standard IS the checker. Hand-adding frontmatter
# to two dozen files and never verifying again means the standard is broken
# within a month and nobody notices -- the documents still render and still
# read fine, they just quietly stop being machine-consumable. That is the
# same silent-failure shape as everything else guarded here.
#
# Only the spec's normative requirements fail the build. House conventions
# (title, description, the type taxonomy) are reported as warnings, because
# enforcing our taste as if it were the standard is how a standard gets
# resented and then bypassed.
OKF_OUT="$(python3 "$REPO_ROOT/platform/docs/okf_check.py" 2>&1)"
OKF_RC=$?
if [ "$OKF_RC" -eq 0 ]; then
  _pass "OKF v0.1 conformance: $(echo "$OKF_OUT" | head -1 | sed 's/^OKF v0.1 conformance: //')"
else
  _fail "OKF v0.1 conformance" "$(echo "$OKF_OUT" | head -4 | tr '\n' ' ')"
fi

# EVERY ASSERTION HELPER A TEST CALLS MUST ACTUALLY EXIST.
#
# The suites do not use `set -e`, on purpose -- a failed assertion has to let
# the rest of the file run. So a call to a helper that does not exist exits
# 127, is ignored, and the check silently never happens while the suite still
# reports "0 failed". A test that cannot fail is not a test, and this is the
# one failure mode the test suite could not catch about itself.
#
# Found by writing two `assert_contains` calls (the real helper is
# assert_output_contains) and watching the suite stay green.
#
# bash's command_not_found_handle would be the natural home for this, but it
# needs bash 4.0 and macOS ships 3.2.57 -- so it is a static scan instead.
DEFINED_HELPERS="$(grep -oE '^[a-z_]+\(\)' "$REPO_ROOT/platform/tests/lib.sh" | sed 's/()//' | sort -u)"
UNDEFINED_CALLS=""
for tf in "$REPO_ROOT"/platform/tests/test_*.sh; do
  # Helper calls only ever appear at the start of a line (possibly indented).
  # sed, not `tr -d '[:space:]'`: tr deletes newlines too, which glued every
  # match in the file into one giant token that matched nothing.
  CALLED="$(grep -oE '^[[:space:]]*(assert|run_cmd|_pass|_fail|suite)[a-z_]*' "$tf" \
            | sed 's/^[[:space:]]*//' | sort -u)"
  for c in $CALLED; do
    printf '%s\n' "$DEFINED_HELPERS" | grep -qx "$c" \
      || UNDEFINED_CALLS="$UNDEFINED_CALLS $(basename "$tf"):$c"
  done
done
assert_equals "" "$UNDEFINED_CALLS" \
  "every assertion helper called by a test suite is defined in lib.sh"

find "$REPO_ROOT/platform" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

suite_summary

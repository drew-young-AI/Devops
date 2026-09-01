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

# ---- GitHub Actions: no third-party action on a mutable ref ---------------
#
# `.github/workflows/iac-validate.yml` argues at length that pinning to a
# mutable ref means the bytes executed can change between runs -- and then used
# `bridgecrewio/checkov-action@master` two steps later. A rule stated in a
# comment and contradicted by the line below it is worse than no rule: it reads
# as settled.
#
# The same file also carried `aquasecurity/trivy-action@0.28.0`, a version that
# HAS NEVER EXISTED. It failed every run for 17 days. `continue-on-error: true`
# did not cover it, because action resolution happens BEFORE the step runs --
# so the flag read as "this scan may fail" while the whole job died at setup.
#
# This check is hermetic and therefore cannot tell a nonexistent tag from a
# real one; it enforces the part that CAN be decided offline. `actions/*` is
# exempt: those are GitHub's own, and their major tags are the documented
# interface rather than a moving branch.
MUTABLE=""
for wf in "$REPO_ROOT"/.github/workflows/*.yml; do
  while read -r ref; do
    [ -n "$ref" ] || continue
    case "$ref" in actions/*) continue ;; esac
    r="${ref#*@}"
    # 40 hex characters is a commit. Anything shorter that is not a version
    # tag is a branch, and a branch is a promise nobody made.
    case "$r" in
      v[0-9]*|[0-9]*.[0-9]*) continue ;;
    esac
    printf '%s' "$r" | grep -qE '^[0-9a-f]{40}$' && continue
    MUTABLE="$MUTABLE $(basename "$wf"):$ref"
  done < <(grep -ohE 'uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+' "$wf" | sed 's/uses: //')
done
assert_equals "" "$MUTABLE" \
  "no third-party GitHub Action is pinned to a mutable ref"

# ---- no Kubernetes manifest may carry a literal credential -----------------
#
# WHY (2026-09-01). `deployment-template.yaml` carried
# `PGPASSWORD: "twin-bootstrap"` in plain text -- a shared password, never
# expiring, with no revocation path -- for as long as the K8s copy existed,
# while the Compose copy of the SAME pilot had held dynamic Vault credentials
# since 2026-08-19. The copy being promoted toward production had the weaker
# credential model of the two, and nothing said so.
#
# The manifests are now credential-free: the AppRole arrives through a
# secretKeyRef and the database user is issued by Vault at startup. This check
# exists so a future edit cannot quietly put a password back -- which is
# exactly how the first one got there, since a literal value in YAML is the
# path of least resistance every single time.
#
# It matches assignment of a value, not the mere mention of a variable name,
# so `secretKeyRef: {key: PGPASSWORD}` and comments about PGPASSWORD stay legal.
LITERAL_CREDS=""
for mf in "$REPO_ROOT"/platform/k8s/**/*.yaml "$REPO_ROOT"/platform/k8s/*.yaml; do
  [ -f "$mf" ] || continue
  hits="$(grep -nE '(name: *)?(PGPASSWORD|VAULT_TOKEN|VAULT_SECRET_ID|POSTGRES_PASSWORD)[",]? *,? *value: *"[^"]+"' "$mf" 2>/dev/null | head -3)"
  [ -n "$hits" ] && LITERAL_CREDS="$LITERAL_CREDS $(basename "$mf")"
done
LITERAL_CREDS="$(printf '%s' "$LITERAL_CREDS" | sed 's/^ *//')"
assert_equals "" "$LITERAL_CREDS" \
  "no Kubernetes manifest assigns a literal credential value"

# ---- stat: GNU form first, BSD as the fallback -----------------------------
#
# WHY (2026-09-01). This is the FIFTH instance of one defect in this repo.
#
# `stat -f` on BSD/macOS means "format". On GNU coreutils it means "filesystem
# status" -- and it SUCCEEDS, printing `File: ...`. So a BSD-first chain
#
#     stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f" 2>/dev/null
#
# never reaches its fallback on Linux: it captures a filesystem description and
# compares that against the expected value. The `||` reads as portability and
# provides none.
#
# The first four instances kept CI red from 2026-08-08 to 2026-08-31 -- 13 of
# 20 runs -- while every local run stayed green, because the only machine
# anyone watched was the one BSD stat works on. The fifth was written on the
# day the fourth was documented, in a suite whose entire subject is a mode bit,
# and again only cloud CI caught it.
#
# Four fixes and a comment did not stop it. A guard might.
BAD_STAT=""
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  file="${hit%%:*}"
  rest="${hit#*:}"
  line="${rest#*:}"
  # Legal only when the GNU form appears earlier on the same line.
  case "$line" in
    *"stat -c"*)
      gnu_at="${line%%stat -c*}"
      bsd_at="${line%%stat -f*}"
      [ "${#gnu_at}" -lt "${#bsd_at}" ] || BAD_STAT="$BAD_STAT $(basename "$file")"
      ;;
    *) BAD_STAT="$BAD_STAT $(basename "$file")" ;;
  esac
# Comments are stripped first, and `%%stat`/`##stat` are excluded: those are
# shell parameter expansions (this guard's own implementation uses one), not
# invocations of stat. Matching text rather than calls is how the previous two
# guards in this file were wrong; see their notes.
done < <(grep -rnE 'stat +-f' "$REPO_ROOT/platform" --include='*.sh' 2>/dev/null \
           | sed 's/[[:space:]]*#.*$//' \
           | grep -vE '[%#]{2}stat' \
           | grep -E 'stat +-f')
BAD_STAT="$(printf '%s' "$BAD_STAT" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/^ *//; s/ *$//')"
# The message deliberately spells neither flag literally. The FIRST version read
# "every 'stat -f' is preceded by the GNU 'stat -c' form", and this guard
# flagged its own assertion message -- the third time in one session that a
# grep-based check in this file matched prose instead of a call. A guard whose
# own description is a false positive is telling you something about the method,
# not about the code.
assert_equals "" "$BAD_STAT" \
  "BSD-format stat is never invoked ahead of the GNU form on the same line"

# ---- the pilot's AppRole must be delivered by the start path, not the shell -
#
# WHY (2026-09-01). `compose.yaml` reads ${VAULT_ROLE_ID:-} from the ambient
# environment and the app falls back to the static database password when it is
# empty. `recover.sh` used to run `docker compose up` from whatever shell
# recovery happened in, so a restart without those variables exported silently
# downgraded the credential model -- which is exactly what happened after the
# host slept: the develop copy came back on `mode: static` while the Kubernetes
# copy came back on `mode: vault`.
#
# This asserts only the wiring, which is the part that is decidable offline:
# recovery must pass --env-file. Whether the writer actually produces a usable
# file is behaviour, and is tested in test_redaction.sh's neighbour
# test_approle_env.sh; whether the RUNNING copies ended up agreeing is tier 3,
# in test_migration_observed.sh. Three checks because they can each fail
# without the others noticing.
#
# NOTE ON THE FIRST VERSION OF THIS CHECK. It grepped the repo for the string
# `pilots/station2-twin/.env.vault` and passed if anything mentioned it. A
# mutation that pointed the WRITER at a different filename left it green,
# because recover.sh still mentioned the path as a READER. It verified that
# somebody talked about the file, not that anybody wrote it -- a guard whose
# subject was the wrong noun.
# Comment lines are stripped first. The FIRST version of this check grepped the
# whole file, and a mutation that deleted the actual --env-file argument left it
# green -- because the explanatory comment a few lines above still contained the
# string. Twice in one session, in this same file, a guard matched a MENTION of
# the mechanism rather than the mechanism. Worth leaving on the record: a
# grep-based check must be told which lines are code.
if sed 's/[[:space:]]*#.*$//' "$REPO_ROOT/platform/recover.sh" 2>/dev/null \
     | grep -q -- '--env-file'; then
  _pass "recovery hands the pilot an --env-file instead of trusting the shell"
else
  _fail "recovery hands the pilot an --env-file instead of trusting the shell" \
        "recover.sh runs docker compose without --env-file: a restart from a shell with no AppRole exported downgrades to the static password silently"
fi

# ---- .gitignore rules must actually apply to what is tracked ---------------
#
# WHY (2026-09-01). `.gitignore` line 207 excludes `evidence/scheduler/*_last.json`
# and explains itself at length: they rewrite every 15 minutes, so tracking them
# "means permanent churn and a conflict on every branch switch". All nine of
# them were tracked anyway, and had been since before the rule was written.
#
# .gitignore only governs UNTRACKED files. A rule added after a file is already
# in the index is inert -- it reads as enforcement, produces no error, and the
# churn it forbids continues indefinitely. That is this repository's signature
# defect: a thing that REGISTERS as present but does not EXECUTE. Same shape as
# `promtool check rules` reporting SUCCESS on a rule that fails every evaluation
# (ADR-0007), and as `continue-on-error` not covering action resolution.
#
# --no-index is the whole point: without it, git check-ignore stays silent about
# tracked files, which is exactly the set being audited here.
#
# Negation rules (`!path`) are filtered out. `git check-ignore -v` reports them
# as matches too, but a `!` line means "keep this one", so a file matching it is
# correctly tracked -- counting those would make this check permanently red.
IGNORED_BUT_TRACKED="$(cd "$REPO_ROOT" && git ls-files \
  | git check-ignore --stdin --no-index -v 2>/dev/null \
  | grep -v ':[0-9]*:!' | awk '{print $2}' | tr '\n' ' ' | sed 's/ *$//')"
assert_equals "" "$IGNORED_BUT_TRACKED" \
  "no tracked file matches a .gitignore rule that claims to exclude it"

find "$REPO_ROOT/platform" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

suite_summary

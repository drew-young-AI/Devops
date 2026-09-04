#!/usr/bin/env bash
# The test suite must not fill the disk it runs on.
#
# WHY THIS SUITE EXISTS.
#
# `make_sandbox` copied platform/ with `cp -R`, which brought
# platform/backup/archives -- 3.3GB of backup tarballs -- into every sandbox,
# for tests that reference none of them. And `cleanup_sandboxes` was called
# only from `suite_summary`, so any early `exit` or interruption left the whole
# copy behind.
#
# Measured 2026-09-04: 124 leaked sandboxes in $TMPDIR, 421GB, dating from
# 2026-09-01. The volume was at 89% used and the disk alert built the previous
# day was about to fire. Removing them took it from 95GiB free to 516GiB.
#
# That accumulation window covers the disk-full outage of 2026-09-03 that
# stopped Prometheus, killed Docker's engine and took every container down --
# the outage that prompted building host-disk monitoring in the first place.
# The monitoring was aimed one level above its own cause: the test suite was
# filling the disk, and nothing connected the two because nothing measured it.
#
# So this suite watches the watcher's own footprint. It is deliberately about
# BYTES rather than tidiness -- a stray empty file is noise, a 3.6GB directory
# per suite run is an outage with a delay fuse.

set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="sandbox-hygiene"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== the test suite must not fill the disk it runs on =="

TMP="${TMPDIR:-/tmp}"; TMP="${TMP%/}"

# ---- 1. the exclusion list is not stale ------------------------------------
#
# An exclusion naming a path that no longer exists is silently inert: the
# sandbox goes back to being enormous and nothing says so. Checked against the
# real tree, because that is the only thing that can contradict it.
MISSING=""
for ex in "${SANDBOX_EXCLUDE[@]}"; do
  [ -e "$REPO_ROOT/platform/$ex" ] || MISSING="$MISSING $ex"
done
# Absent is not automatically wrong -- archives only exist once a backup has
# run -- so this REPORTS rather than fails. What would be wrong is the reverse,
# and that is assertion 2.
if [ -n "$MISSING" ]; then
  echo "  NOTE  excluded but not present right now:$MISSING"
else
  _pass "every excluded path exists in the tree (the list is not stale)"
fi

# ---- 2. the exclusion actually excludes ------------------------------------
BOX="$(make_sandbox)"
BOX_BYTES="$(du -sk "$BOX" 2>/dev/null | awk '{print $1}')"
if [ -e "$BOX/platform/backup/archives" ]; then
  _fail "the sandbox does not carry backup archives" \
        "platform/backup/archives is inside $BOX"
else
  _pass "the sandbox does not carry backup archives"
fi

# 50MB. Not a tidiness threshold -- it is two orders of magnitude below the
# 3.6GB that caused the incident and one above the ~2MB a real sandbox needs,
# so it catches a regression without failing on ordinary growth.
if [ "${BOX_BYTES:-0}" -lt 51200 ]; then
  _pass "a sandbox is under 50MB (measured $((BOX_BYTES / 1024))MB)"
else
  _fail "a sandbox is under 50MB" \
        "measured $((BOX_BYTES / 1024))MB -- something large is being copied again"
fi

# ---- 3. a suite leaves nothing large behind --------------------------------
#
# Run as a SUBPROCESS: cleanup happens at that process's exit, so it cannot be
# observed from inside the suite doing the cleaning. test_deploy_contract.sh is
# the subject because it makes several sandboxes and is fast.
BEFORE_KB="$(du -sk "$TMP" 2>/dev/null | awk '{print $1}')"
"$SUITE_DIR/test_deploy_contract.sh" >/dev/null 2>&1
AFTER_KB="$(du -sk "$TMP" 2>/dev/null | awk '{print $1}')"
GROWTH_KB=$(( AFTER_KB - BEFORE_KB ))
# Can go negative if something else in TMPDIR shrank meanwhile; that is not a
# leak, and clamping keeps an unrelated cleanup from reading as a pass.
[ "$GROWTH_KB" -lt 0 ] && GROWTH_KB=0
if [ "$GROWTH_KB" -lt 51200 ]; then
  _pass "a completed suite leaves under 50MB behind (measured ${GROWTH_KB}KB)"
else
  _fail "a completed suite leaves under 50MB behind" \
        "TMPDIR grew by $((GROWTH_KB / 1024))MB -- sandboxes are leaking again"
fi

# ---- 4. cleanup survives an ABNORMAL exit ----------------------------------
#
# This is the half the original code missed: cleanup lived in suite_summary, so
# it ran on the tidy path and only there. The trap is what covers an early
# `exit` on a SKIP branch or an interrupted run, and a trap nobody has seen
# fire is indistinguishable from no trap.
LEAK="$(mktemp -d)"
cat > "$LEAK/abrupt.sh" <<SH
#!/usr/bin/env bash
source "$SUITE_DIR/lib.sh"
box="\$(make_sandbox)"
echo "\$box" > "$LEAK/boxpath"
# No suite_summary, no cleanup call. Only the trap can save this.
exit 0
SH
chmod +x "$LEAK/abrupt.sh"
"$LEAK/abrupt.sh" >/dev/null 2>&1
LEAKED="$(cat "$LEAK/boxpath" 2>/dev/null)"
if [ -n "$LEAKED" ] && [ -d "$LEAKED" ]; then
  _fail "a suite that exits without calling suite_summary still cleans up" \
        "$LEAKED survived"
elif [ -n "$LEAKED" ]; then
  _pass "a suite that exits without calling suite_summary still cleans up"
else
  _fail "a suite that exits without calling suite_summary still cleans up" \
        "the fixture never recorded a sandbox path"
fi
rm -rf "$LEAK"

# ---- 5. the check itself can fail ------------------------------------------
#
# Assertion 3 measures TMPDIR growth. If that measurement were broken it would
# report 0 forever and pass on a suite leaking gigabytes. So: make TMPDIR grow
# by a known amount and confirm the same measurement notices.
# `dd`, NOT `mkfile -n`. mkfile -n creates a SPARSE file: right apparent size,
# zero blocks occupied, so `du` reports no growth and this control failed on
# its first run reporting "the check is blind" -- about itself. Same
# distinction as apparent-vs-allocated on Docker.raw, one file along: du
# measures blocks, and a control that writes no blocks tests nothing.
#
# `bs=1024k`, NOT `bs=1m`. GNU dd rejects a lowercase suffix outright --
# `dd: invalid number '1m'` -- so on the Linux CI runner nothing was written
# and this control reported "the check is blind" about a `du` that was working
# perfectly. Verified in an alpine container rather than assumed: `bs=1m` fails
# there, `bs=1024k` writes 2097152 bytes on both systems.
#
# Third BSD-vs-GNU trap in two days, after `stat -f` and `sed -i ''`.
# test_static.sh now forbids the lowercase suffix the same way it forbids the
# other two.
#
# Measured on the PROBE DIRECTORY rather than on all of $TMPDIR: the claim
# under test is "du -sk notices 60MB appearing", and unrelated churn elsewhere
# in the directory is noise against that claim, not evidence.
PROBE="$(mktemp -d)"
B4="$(du -sk "$PROBE" 2>/dev/null | awk '{print $1}')"
dd if=/dev/zero of="$PROBE/ballast" bs=1024k count=60 >/dev/null 2>&1
BALLAST_KB="$(du -sk "$PROBE/ballast" 2>/dev/null | awk '{print $1}')"
AF="$(du -sk "$PROBE" 2>/dev/null | awk '{print $1}')"
rm -rf "$PROBE"
if [ "${BALLAST_KB:-0}" -lt 51200 ]; then
  # Name the real cause. "The check is blind" would be a claim about du when
  # the truth is that dd never wrote the bytes.
  _fail "the growth measurement notices 60MB appearing" \
        "the ballast itself is only $(( ${BALLAST_KB:-0} / 1024 ))MB -- dd did not write it"
elif [ $(( AF - B4 )) -ge 51200 ]; then
  _pass "the growth measurement notices 60MB appearing (it can go red)"
else
  _fail "the growth measurement notices 60MB appearing" \
        "measured only $(( (AF - B4) / 1024 ))MB of growth -- the check is blind"
fi

suite_summary

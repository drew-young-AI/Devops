#!/usr/bin/env bash
# Decision records exist so that in three months nobody re-estimates a number
# they could have re-measured. That only works if two things hold:
#
#   1. every measured claim carries the command that reproduces it, and
#   2. that command points at something that still exists.
#
# The second is the one with teeth, and it is the one this suite spends most of
# its assertions on. A `rerun:` line naming a script renamed six weeks ago is
# WORSE than no line: it reads as reproducible right up until someone tries it.
# Same rule as the AIS capability registry -- an entry whose `verify` does not
# work is treated as unregistered, because an unverifiable capability is a
# zombie, and an unreproducible measurement is the same thing.
#
# Every rule is checked by writing a deliberately broken record into a temp
# directory. Nothing under docs/decisions/ is modified.

set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="decisions"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== decision records: a number without a rerun is an estimate =="

TOOL="$REPO_ROOT/platform/docs/decisions.py"
assert_file_exists "$TOOL" "decisions.py exists"

# ---- POSITIVE FIRST -------------------------------------------------------
run_cmd python3 "$TOOL" --check
assert_rc 0 "the real decision records validate"
assert_output_contains "reproducible measurement" "and report how many are reproducible"

TMP="$(mktemp -d -t decisions.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# A known-good record, so every failure below is caused by the one thing changed.
write_record() {   # write_record <filename> <decision-block-yaml>
  cat > "$TMP/$1" <<EOF
---
type: explanation
title: 測試用紀錄
description: "Fixture."
tags:
  - decision
decision:
$2
---

# 測試
EOF
}

check() { run_cmd env DECISIONS_DIR="$TMP" python3 "$TOOL" --check; }

write_record "0001-good.md" "  id: 1
  status: accepted
  date: 2026-01-01
  measured: true
  rerun: platform/analytics/benchmark.sh"
check
assert_rc 0 "a well-formed record passes"

# ---- NEGATIVE: the rule with teeth ---------------------------------------
write_record "0001-good.md" "  id: 1
  status: accepted
  date: 2026-01-01
  measured: true
  rerun: platform/analytics/this-was-renamed.sh"
check
assert_rc 1 "a rerun pointing at a missing file is refused"
assert_output_contains "does not exist" "and says the file is gone"

write_record "0001-good.md" "  id: 1
  status: accepted
  date: 2026-01-01
  measured: true"
check
assert_rc 1 "measured: true with no rerun command is refused"
assert_output_contains "estimate" "and says why it matters"

# ---- NEGATIVE: structural ------------------------------------------------
write_record "0001-good.md" "  id: 7
  status: accepted
  date: 2026-01-01"
check
assert_rc 1 "an id that disagrees with the filename is refused"

write_record "0001-good.md" "  id: 1
  status: probably-fine
  date: 2026-01-01"
check
assert_rc 1 "an unknown status is refused"

write_record "0001-good.md" "  id: 1
  status: superseded
  date: 2026-01-01"
check
assert_rc 1 "a superseded record that does not say what replaced it is refused"

write_record "0001-good.md" "  id: 1
  status: superseded
  date: 2026-01-01
  superseded_by: 99"
check
assert_rc 1 "superseded_by pointing at a record that does not exist is refused"

write_record "0001-good.md" "  id: 1
  status: accepted
  date: 2026-01-01"
cat > "$TMP/not-numbered.md" <<'EOF'
---
type: explanation
title: x
decision:
  id: 2
  status: accepted
  date: 2026-01-01
---
EOF
check
assert_rc 1 "a filename that is not NNNN-slug.md is refused"
rm -f "$TMP/not-numbered.md"

# ---- the positive still holds after all that ------------------------------
check
assert_rc 0 "the fixture directory is valid again once the defect is removed"

run_cmd python3 "$TOOL" --check
assert_rc 0 "the real records were never touched"

suite_summary

#!/usr/bin/env bash
# Conformance: does the evidence the platform actually produces match the
# contract the platform actually publishes?
#
# platform/ci/pipeline-contract.yml is the provider-neutral interface that a
# future consumer repo (docs/Future-DataOps.md's platform-as-a-service
# decision) is told to build against. A contract that has quietly drifted
# from its producer is worse than no contract: it is a promise that reads as
# kept. Nothing checked this before, so drift was invisible by construction.

set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="evidence-contract"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== evidence / contract conformance =="

CONTRACT="$REPO_ROOT/platform/ci/pipeline-contract.yml"
assert_file_exists "$CONTRACT" "pipeline-contract.yml exists"

REQUIRED_FIELDS="$(python3 -c "
import yaml
c = yaml.safe_load(open('$CONTRACT'))
print(' '.join(c['artifact_metadata']['required']))
")"

BUILD_FILES="$(find "$REPO_ROOT/evidence" -name 'build_*.json' 2>/dev/null | sort)"
if [ -z "$BUILD_FILES" ]; then
  _fail "build evidence exists to check" "no evidence/*/build_*.json found"
else
  _pass "build evidence exists to check"
fi

for field in $REQUIRED_FIELDS; do
  missing=""
  for file in $BUILD_FILES; do
    present="$(python3 -c "
import json, sys
d = json.load(open('$file'))
v = d.get('$field')
print('yes' if v not in (None, '') else 'no')
")"
    [ "$present" = "yes" ] || missing="$missing $(basename "$file")"
  done
  if [ -z "$missing" ]; then
    _pass "contract field '$field' present in all build evidence"
  else
    _fail "contract field '$field' present in all build evidence" "missing in:$missing"
  fi
done

# Deploy evidence is what the promote gate reads. If health_status ever
# stops being written, promote fails closed (good) but for the wrong reason,
# and every promotion breaks at once.
DEPLOY_FILES="$(find "$REPO_ROOT/evidence" -name 'deploy_develop_*.json' 2>/dev/null | sort)"
for file in $DEPLOY_FILES; do
  ok="$(python3 -c "
import json
d = json.load(open('$file'))
need = ['environment', 'commit_sha', 'image_digest', 'health_status', 'deployed_at']
print('yes' if all(d.get(k) not in (None, '') for k in need) else 'no')
")"
  assert_equals "yes" "$ok" "deploy evidence complete: $(basename "$file")"
done

# Every evidence file must be valid JSON. A truncated or half-written
# artifact silently poisons any consumer that reads it.
BAD_JSON="$(python3 -c "
import glob, json, os
bad = []
for path in sorted(glob.glob(os.path.join('$REPO_ROOT', 'evidence', '**', '*.json'), recursive=True)):
    try:
        json.load(open(path))
    except Exception as exc:
        bad.append(os.path.basename(path))
print(','.join(bad))
")"
assert_equals "" "$BAD_JSON" "all evidence files are valid JSON"

# Evidence must never carry a secret value. platform/security/ scans the
# repo's git history; this asserts the same invariant at the artifact level,
# where a future producer is most likely to leak one by accident.
LEAKY="$(python3 -c "
import glob, json, os, re
pattern = re.compile(r'(ghp_|github_pat_|hvs\.|-----BEGIN [A-Z ]*PRIVATE KEY)')
bad = []
for path in sorted(glob.glob(os.path.join('$REPO_ROOT', 'evidence', '**', '*.json'), recursive=True)):
    try:
        if pattern.search(open(path, encoding='utf-8', errors='replace').read()):
            bad.append(os.path.basename(path))
    except Exception:
        pass
print(','.join(bad))
")"
assert_equals "" "$LEAKY" "no evidence file contains a credential-shaped value"

# The SAST and DAST gates both treat "scanned nothing" as a failure rather
# than a clean result, because a mistyped ruleset or an unreachable target
# produces zero findings that are indistinguishable from a healthy scan.
# This asserts that any recorded PASS actually examined something -- a PASS
# with zero coverage would otherwise sit in evidence/ looking like assurance.
for summary in $(find "$REPO_ROOT/evidence/security" -name 'sast_summary_*.json' 2>/dev/null | sort); do
  ok="$(python3 -c "
import json
d = json.load(open('$summary'))
print('yes' if (d['gate_result'] != 'PASS' or d['files_scanned'] > 0) else 'no')
")"
  assert_equals "yes" "$ok" "SAST PASS implies files were scanned: $(basename "$summary")"
done

for summary in $(find "$REPO_ROOT/evidence/security" -name 'dast_summary_*.json' 2>/dev/null | sort); do
  ok="$(python3 -c "
import json
d = json.load(open('$summary'))
# Accepts either field name: older evidence predates the rename, and
# rewriting historical artifacts to satisfy a test would be falsifying them.
covered = len(d.get('sites_scanned', [])) or d.get('urls_in_alerts', d.get('urls_examined', 0))
print('yes' if (d['gate_result'] != 'PASS' or covered > 0) else 'no')
")"
  assert_equals "yes" "$ok" "DAST PASS implies URLs were examined: $(basename "$summary")"
done

suite_summary

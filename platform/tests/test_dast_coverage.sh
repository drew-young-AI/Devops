#!/usr/bin/env bash
# A DAST PASS must say how much of the application it actually looked at.
#
# WHY THIS SUITE EXISTS (2026-09-01).
#
# `scan_dast.sh` reports `gate_result: PASS`, HIGH=0 MEDIUM=0. True, and
# misleading: the ZAP baseline profile is passive rules plus a GET spider, and
# station2-twin serves a JSON API with no links, so the spider finds four
# health/metrics endpoints and nothing else. `POST /twin/<asset>/observation`
# -- the only write path in the system -- cannot be reached by a GET spider at
# all.
#
# Measured: 4 of 10 routes. The gate was reporting PASS on 40% of the surface
# and saying nothing about the other 60%. That is the platform's oldest defect
# shape in security clothing -- a green line whose real content is "almost
# nothing was examined". VACUOUS is not PASS.
#
# WHY THE CONTROLS ARE SYNTHETIC.
#
# Running the reporter against the real app proves it produces *a* number. It
# does not prove the number responds to anything. Each control below writes a
# throwaway dispatcher with a KNOWN route set and requires the reporter to
# classify it correctly -- including the case that matters most: adding a route
# must make coverage go DOWN, because a coverage metric that cannot fall is
# decoration.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="dast-coverage"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== a DAST pass must state how much of the app it could not reach =="

COV="$REPO_ROOT/platform/security/dast_coverage.py"

# Writes a fake dispatcher in the shape the real one uses. Nine routes, which
# clears the reporter's MIN_EXPECTED_ROUTES floor of 8.
fixture_app() {  # <path> [extra-get-route]
  local path="$1" extra="${2:-}"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
class H:
    def do_GET(self):
        if path == "/health/live":
            return 1
        if path == "/health/ready":
            return 1
        if path == "/version":
            return 1
        if path == "/metrics":
            return 1
        if parts == ["forecast"]:
            return 1
        if parts == ["surveillance", "scan"]:
            return 1
        if len(parts) == 2 and parts[0] == "twin":
            return 1
        if len(parts) == 3 and parts[0] == "twin" and parts[2] == "history":
            return 1

    def do_POST(self):
        if not (len(parts) == 3 and parts[0] == "twin" and parts[2] == "observation"):
            return 0
EOF
  if [ -n "$extra" ]; then
    # Insert one more GET route before do_POST, so the added route is
    # attributed to GET and the total goes up by exactly one.
    python3 - "$path" "$extra" <<'PY'
import sys
p, route = sys.argv[1], sys.argv[2]
s = open(p).read()
s = s.replace("\n    def do_POST",
              '\n        if path == "%s":\n            return 1\n\n    def do_POST' % route, 1)
open(p, "w").write(s)
PY
  fi
}

run_cov() {  # <app-path> <sandbox>
  run_cmd python3 "$COV" --app "$1" \
    --out "$2/cov.json" --prom "$2/cov.prom" --json
}

field() {  # <json-path> <key>
  python3 -c "
import json,sys
print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$1" "$2" 2>/dev/null || echo ERR
}

# --- the shape of the answer ------------------------------------------------
BOX="$(mktemp -d)"
fixture_app "$BOX/app.py"
run_cov "$BOX/app.py" "$BOX"
assert_rc 0 "reports coverage for a well-formed dispatcher"
assert_equals "9" "$(field "$BOX/cov.json" routes_total)" \
  "finds every route the dispatcher serves, literal and parameterised"
assert_equals "4" "$(field "$BOX/cov.json" routes_reachable)" \
  "only the four unparameterised GET endpoints are reachable by a GET spider"

# The write path must be its own category. Counting it as just another
# uncovered route would bury the one finding that changes what someone does.
WRITE="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for r in d['routes'] if r['reason']=='write'))" "$BOX/cov.json" 2>/dev/null || echo ERR)"
assert_equals "1" "$WRITE" "the write endpoint is reported as its own reason, not lumped in"

# The REASON breakdown, not just the count. Found by mutation: deleting the
# parameterised branch left every assertion above green, because a
# parameterised route falls through to "unlinked" and is still unreachable --
# the coverage number was identical and the diagnosis was wrong. A report whose
# numbers survive the removal of its own reasoning is a report nobody can act
# on: "unlinked" says add a link, "parameterised" says give the scanner an
# example id, and they are not the same instruction.
REASONS="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(','.join('%s=%d' % kv for kv in sorted(d['unreachable_by_reason'].items())))" "$BOX/cov.json" 2>/dev/null || echo ERR)"
assert_equals "parameterised=2,unlinked=2,write=1" "$REASONS" \
  "each unreachable route carries the reason that says what to do about it"

# --- control: adding a route must LOWER coverage ----------------------------
#
# The one that matters. A coverage number that cannot fall when the surface
# grows is decoration, and it would go stale silently the first time somebody
# adds an endpoint.
BEFORE="$(field "$BOX/cov.json" coverage_ratio)"
GROWN="$(mktemp -d)"
fixture_app "$GROWN/app.py" "/admin/debug"
run_cov "$GROWN/app.py" "$GROWN"
assert_rc 0 "reports coverage for a dispatcher that grew a route"
assert_equals "10" "$(field "$GROWN/cov.json" routes_total)" \
  "catches: a route added to the dispatcher appears without anyone updating a list"
AFTER="$(field "$GROWN/cov.json" coverage_ratio)"
LOWER="$(python3 -c "
import sys
print('yes' if float(sys.argv[2]) < float(sys.argv[1]) else 'no')" "$BEFORE" "$AFTER" 2>/dev/null || echo ERR)"
assert_equals "yes" "$LOWER" "catches: an unlinked new endpoint drives coverage DOWN ($BEFORE -> $AFTER)"
rm -rf "$GROWN"

# --- control: a dispatcher it can no longer read must be REFUSED ------------
#
# If the parser rots, the comfortable output is "0 uncovered routes", derived
# from 0 routes found. That is the exact failure this whole suite is about, so
# the reporter has to refuse rather than divide by a surface it cannot see.
BLIND="$(mktemp -d)"
printf 'class H:\n    def do_GET(self):\n        return route_table[path]()\n' > "$BLIND/app.py"
run_cov "$BLIND/app.py" "$BLIND"
assert_rc 2 "refuses a dispatcher whose routes it cannot parse"
assert_output_contains "0 gaps out of 0" "says why refusing beats reporting a comfortable zero"
if [ -f "$BLIND/cov.prom" ]; then
  _fail "writes no metrics when it cannot see the routes" "cov.prom was created"
else
  _pass "writes no metrics when it cannot see the routes"
fi
rm -rf "$BLIND"

# --- the emitted metrics must be parseable ----------------------------------
run_cmd python3 "$COV" --app "$BOX/app.py" --out "$BOX/c2.json" --prom "$BOX/c2.prom"
assert_rc 0 "writes the textfile output"
assert_file_exists "$BOX/c2.prom" "textfile metrics written for the collector"
BAD="$(python3 -c "
import re,sys
bad=0
for line in open(sys.argv[1]):
    line=line.rstrip('\n')
    if not line or line.startswith('#'):
        continue
    if not re.match(r'^[a-zA-Z_:][a-zA-Z0-9_:]*(\{[^}]*\})? -?[0-9.eE+-]+\$', line):
        bad+=1
print(bad)" "$BOX/c2.prom" 2>/dev/null || echo ERR)"
assert_equals "0" "$BAD" "every metric line matches the Prometheus exposition format"
rm -rf "$BOX"

# --- the real pilot ---------------------------------------------------------
#
# Not a threshold assertion: coverage is allowed to be low, and today it is.
# What is NOT allowed is for it to be unmeasured, or for the write endpoint to
# quietly stop being reported as unscanned while it is still unscanned.
REAL="$(mktemp -d)"
run_cmd python3 "$REPO_ROOT/platform/security/dast_coverage.py" \
  --out "$REAL/cov.json" --prom "$REAL/cov.prom" --json
assert_rc 0 "the real pilot's dispatcher is readable"
REAL_TOTAL="$(field "$REAL/cov.json" routes_total)"
if [ "$REAL_TOTAL" -ge 8 ] 2>/dev/null; then
  _pass "the real pilot reports a plausible route count ($REAL_TOTAL)"
else
  _fail "the real pilot reports a plausible route count" "got '$REAL_TOTAL'"
fi
REAL_WRITE="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
w=[r for r in d['routes'] if r['method']=='POST']
print('%d:%s' % (len(w), all(not r['reachable_by_baseline'] for r in w)))" "$REAL/cov.json" 2>/dev/null || echo ERR)"
assert_equals "1:True" "$REAL_WRITE" \
  "the pilot's one write endpoint is reported as NOT reachable by the baseline profile"
rm -rf "$REAL"

suite_summary

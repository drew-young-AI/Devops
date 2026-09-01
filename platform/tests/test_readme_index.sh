#!/usr/bin/env bash
# The README is the central index, which makes it the one file whose rot is
# invisible: a dead link in an index reads exactly like a link to something
# that is fine. Everything it points at is checked here.
#
# It is an index ON PURPOSE and not a summary. Copying content into it produces
# two accounts of the same fact that drift apart, and a reader cannot tell
# which one is current -- the defect this platform has now hit four times
# (a threshold in install.sh and its test, LINES in stage_report.py and a
# dashboard regex, RANK in dag.py and a Grafana mapping, a drift expression in
# an alert and a panel). So this suite also asserts that the hostname in the
# URLs is derived from the machine rather than typed twice.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="readme-index"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== README: the index must point at things that exist =="

README="$REPO_ROOT/README.md"
assert_file_exists "$README" "README.md exists"

# ---- 1. every relative link resolves --------------------------------------
MISSING=""
while read -r target; do
  [ -n "$target" ] || continue
  [ -e "$REPO_ROOT/$target" ] || MISSING="$MISSING $target"
done < <(grep -oE '\]\([^)#]+\)' "$README" | sed 's/^](//; s/)$//' \
         | grep -v '^https\?://' | sed 's/#.*//' | sort -u)
if [ -z "$MISSING" ]; then
  _pass "every relative link in the README resolves to a real path"
else
  _fail "every relative link in the README resolves to a real path" \
        "missing:$MISSING"
fi

# ---- 2. the hostname is this machine's, not a leftover ---------------------
#
# `70.local` sat in PLATFORM_LAN_HOST for weeks without resolving. A README
# full of links to a non-existent host is worse than a README with no links:
# the reader concludes the platform is down, not that the index is stale.
# `scutil` is macOS-only. On any other machine this used to yield the empty
# string, EXPECT became the bare ".local", and every URL in the README was
# reported as pointing at a "wrong" host -- a red result that says nothing
# about the README and everything about which machine ran the check.
#
# The assertions in this section are about THE MACHINE THAT SERVES THE BOARD.
# On a machine that does not serve it they are not weaker, they are
# inapplicable, and they say so out loud rather than passing or failing.
BOARD_HOST="$(scutil --get LocalHostName 2>/dev/null || true)"
if [ -z "$BOARD_HOST" ]; then
  echo "  SKIP  not the board host (no scutil) -- hostname, ports and live URLs are UNVERIFIED"
  SKIP_HOST_CHECKS=1
else
  SKIP_HOST_CHECKS=0
fi
EXPECT="${BOARD_HOST}.local"

if [ "$SKIP_HOST_CHECKS" = "0" ]; then
BADHOST="$(grep -oE 'https?://[a-zA-Z0-9._-]+' "$README" | sed -E 's|https?://||' \
           | sort -u | grep -v "^${EXPECT}$" || true)"
if [ -z "$BADHOST" ]; then
  _pass "every URL uses this machine's name ($EXPECT)"
else
  _fail "every URL uses this machine's name ($EXPECT)" \
        "found other hosts: $(echo "$BADHOST" | tr '\n' ' ')"
fi

# ---- 3. every port in the README is actually published --------------------
#
# Read from the compose file and the nginx vhost rather than restated here.
PUBLISHED="$(
  { grep -ohE '"0\.0\.0\.0:[0-9]+:' "$REPO_ROOT/platform/observability/compose.yaml" \
      | grep -oE ':[0-9]+:' | tr -d ':'
    docker ps --format '{{.Ports}}' 2>/dev/null \
      | grep -oE '0\.0\.0\.0:[0-9]+' | cut -d: -f2
  } | sort -u)"
UNPUB=""
for port in $(grep -oE 'https?://[a-zA-Z0-9._-]+:[0-9]+' "$README" \
              | cut -d: -f3 | sort -u); do
  printf '%s\n' "$PUBLISHED" | grep -qx "$port" || UNPUB="$UNPUB $port"
done
if [ -z "$UNPUB" ]; then
  _pass "every port the README advertises is published to 0.0.0.0"
else
  _fail "every port the README advertises is published to 0.0.0.0" \
        "not published:$UNPUB -- a reviewer on another machine gets a hung connection"
fi

# ---- 4. every advertised URL actually answers -----------------------------
#
# Paths matter as much as ports. A Grafana dashboard URL with a uid that was
# renamed returns 404 and looks, to a reviewer, exactly like a broken platform.
if curl -s -m 5 -o /dev/null "http://${EXPECT}:13000/api/health" 2>/dev/null; then
  DEAD=""
  while read -r url; do
    [ -n "$url" ] || continue
    code="$(curl -4 -s -o /dev/null -w '%{http_code}' -m 8 "$url" 2>/dev/null)"
    # 302 is Grafana redirecting an unauthenticated browser to /login, which is
    # the correct behaviour for the one service that authenticates.
    case "$code" in 200|302) ;; *) DEAD="$DEAD $url($code)" ;; esac
  done < <(grep -oE 'https?://[a-zA-Z0-9._-]+:[0-9]+[^ )|]*' "$README" | sort -u)
  if [ -z "$DEAD" ]; then
    _pass "every URL the README advertises answers 200 or 302"
  else
    _fail "every URL the README advertises answers 200 or 302" "dead:$DEAD"
  fi
else
  echo "  SKIP  platform not running -- advertised URLs are UNVERIFIED"
fi

fi   # end of the board-host-only assertions

# ---- 5. the decisions index it points at must be current ------------------
run_cmd python3 "$REPO_ROOT/platform/docs/decisions.py" --check
assert_rc 0 "the decision records the README points at all validate"

# ---- negative controls: each rule broken on purpose ------------------------
FIX="$(mktemp -d)"; cleanup() { rm -rf "$FIX"; }; trap cleanup EXIT

check_catches() {  # <label> <sed-expr> <expected-fragment>
  local label="$1" expr="$2" want="$3"
  sed "$expr" "$README" > "$FIX/README.md"
  local out
  out="$(cd "$FIX" && {
    grep -oE '\]\([^)#]+\)' README.md | sed 's/^](//; s/)$//' \
      | grep -v '^https\?://' | sed 's/#.*//' | sort -u \
      | while read -r x; do [ -e "$REPO_ROOT/$x" ] || echo "MISSINGLINK $x"; done
    grep -oE 'https?://[a-zA-Z0-9._-]+' README.md | sed -E 's|https?://||' \
      | sort -u | grep -v "^${EXPECT}$" | sed 's/^/BADHOST /'
    for port in $(grep -oE 'https?://[a-zA-Z0-9._-]+:[0-9]+' README.md \
                  | cut -d: -f3 | sort -u); do
      printf '%s\n' "$PUBLISHED" | grep -qx "$port" || echo "UNPUBLISHED $port"
    done
  })"
  if printf '%s' "$out" | grep -q "$want"; then
    _pass "catches: $label"
  else
    _fail "catches: $label" "not reported. got: ${out:-<nothing>}"
  fi
}

check_catches "a link to a file that does not exist" \
  's|(Plan.md)|(Plan-that-was-renamed.md)|' "MISSINGLINK"
# The host and port controls replay rules that only apply on the board host,
# so they are gated by the same condition -- otherwise they would report the
# checks as working on a machine where the checks did not run.
if [ "$SKIP_HOST_CHECKS" = "0" ]; then
  check_catches "a URL pointing at a different host" \
    "s|${EXPECT}:18085|70.local:18085|" "BADHOST"
  check_catches "a port that is not published" \
    "s|${EXPECT}:13000|${EXPECT}:19093|" "UNPUBLISHED"
else
  echo "  SKIP  host and port controls not applicable off the board host"
fi

# Positive control. Without it, the three assertions above would still pass if
# the checks simply reported everything as broken.
cp "$README" "$FIX/README.md"
CLEAN="$(cd "$FIX" && grep -oE '\]\([^)#]+\)' README.md | sed 's/^](//; s/)$//' \
         | grep -v '^https\?://' | sed 's/#.*//' | sort -u \
         | while read -r x; do [ -e "$REPO_ROOT/$x" ] || echo "MISSING $x"; done)"
if [ -z "$CLEAN" ]; then
  _pass "an unmodified README reports nothing (the checks are not always red)"
else
  _fail "an unmodified README reports nothing" "$CLEAN"
fi

suite_summary

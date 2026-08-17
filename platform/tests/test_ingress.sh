#!/usr/bin/env bash
# The ingress mechanism: what may leave this machine, and how far.
#
# THE TEST SUITE MUST NOT BE ABLE TO EXPOSE ANYTHING. EVER.
#
# The first version of this file drove the real ingress.sh against the real
# targets.conf, on the reasoning that a refusal is decided before the script
# touches tailscale, so nothing could be exposed. That reasoning holds only
# while every ceiling is already correct -- which is precisely the thing the
# suite exists to doubt.
#
# It failed exactly that way. Temporarily raising vault's ceiling to `funnel`
# to check the guard fired turned `--serve vault` into an ALLOWED operation,
# and running the suite published Vault's API to the tailnet for real. The
# tests reported the misconfiguration and caused it in the same breath.
#
# So behaviour is now driven against a FIXTURE config pointing at dead ports.
# A bug in the refusal logic then exposes a closed port on a scratch target
# instead of Vault. The live targets.conf is still checked -- but only read,
# never executed against.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
CURRENT_SUITE="ingress"

INGRESS="$REPO_ROOT/platform/ingress/ingress.sh"
TARGETS="$REPO_ROOT/platform/ingress/targets.conf"

assert_file_exists "$INGRESS" "ingress.sh exists"
assert_file_exists "$TARGETS" "targets.conf exists"

# --- live config: READ ONLY ---------------------------------------------

BAD="$(python3 - "$TARGETS" <<'PY'
import sys
bad = []
valid = {"never", "tailnet", "funnel"}
seen_names, seen_ports = set(), set()
for n, line in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    parts = line.split("|")
    if len(parts) != 4:
        bad.append(f"line {n}: {len(parts)} fields, want 4")
        continue
    name, port, ceiling, reason = (p.strip() for p in parts)
    if ceiling not in valid:
        bad.append(f"{name}: ceiling '{ceiling}' not in {sorted(valid)}")
    if not port.isdigit():
        bad.append(f"{name}: non-numeric port '{port}'")
    # A ceiling with no stated reason is a decision nobody can review later.
    if len(reason) < 20:
        bad.append(f"{name}: reason too short to be a justification")
    if name in seen_names:
        bad.append(f"{name}: duplicate target name")
    # Two targets on one port would silently share a serve slot.
    if port in seen_ports:
        bad.append(f"{name}: port {port} already claimed by another target")
    seen_names.add(name); seen_ports.add(port)
print("; ".join(bad))
PY
)"
assert_equals "" "$BAD" "targets.conf is well-formed and every ceiling is justified"

# The services with NO authentication must be pinned at never. This catches
# someone raising a ceiling "temporarily" to debug and leaving it raised.
for svc in vault prometheus alertmanager loki; do
  CEIL="$(grep -E "^${svc}\|" "$TARGETS" | cut -d'|' -f3)"
  assert_equals "never" "$CEIL" "$svc is pinned at ceiling 'never'"
done

# --- refusals, against a fixture that cannot expose anything real --------

FIXTURE="$(mktemp -t ingress_targets)"
cat > "$FIXTURE" <<'FIX'
fixture-open|19990|funnel|Scratch target on a closed port; nothing listens here.
fixture-capped|19991|tailnet|Scratch target whose ceiling forbids public exposure.
fixture-forbidden|19992|never|Scratch target that must be refused at every level.
FIX
trap 'rm -f "$FIXTURE"' EXIT

run_cmd env INGRESS_TARGETS="$FIXTURE" "$INGRESS" --serve fixture-forbidden
assert_rc 1 "a 'never' target is refused at --serve"

run_cmd env INGRESS_TARGETS="$FIXTURE" "$INGRESS" --funnel fixture-forbidden
assert_rc 1 "a 'never' target is refused at --funnel too"

run_cmd env INGRESS_TARGETS="$FIXTURE" "$INGRESS" --funnel fixture-capped
assert_rc 1 "--funnel is refused when it would exceed a tailnet ceiling"

run_cmd env INGRESS_TARGETS="$FIXTURE" "$INGRESS" --serve definitely-not-a-target
assert_rc 2 "an unknown target exits 2 rather than doing something"

# --- nothing forbidden is live ------------------------------------------

# Derive the forbidden ports from the config rather than hard-coding a
# pattern. The previous version matched a hand-written regex that did not
# actually cover 18200, so it reported "no leak" while Vault was live on the
# tailnet -- a leak check that could not see the leak it was written for.
if command -v tailscale >/dev/null 2>&1; then
  SERVE_NOW="$(tailscale serve status 2>/dev/null || true)"
  LEAKED=""
  while IFS='|' read -r name port ceiling _; do
    case "$name" in \#*|"") continue ;; esac
    [ "$ceiling" = "never" ] || continue
    case "$SERVE_NOW" in
      *"127.0.0.1:${port}"*) LEAKED="$LEAKED $name(port $port)" ;;
    esac
  done < <(grep -vE '^\s*#|^\s*$' "$TARGETS")
  assert_equals "" "$LEAKED" "no 'never' service is present in the live serve config"
else
  _pass "no 'never' service is present in the live serve config (skipped: no tailscale)"
fi

# --- regressions ---------------------------------------------------------

# `tailscale funnel ... off` BLOCKS FOREVER on a tailnet without funnel
# enabled (measured: still running at 25s). It used to sit unguarded in the
# teardown path, so the routine whose whole job is undoing a bad exposure was
# the one that could hang.
UNGUARDED="$(python3 - "$INGRESS" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
bad = []
for m in re.finditer(r'^\s*ts funnel .*off', src, re.M):
    before = src[:m.start()].splitlines()[-4:]
    if not any('funnel_is_up' in b for b in before):
        bad.append(m.group(0).strip())
print("; ".join(bad))
PY
)"
assert_equals "" "$UNGUARDED" "no unguarded 'tailscale funnel ... off' anywhere in the script"

# curl -w '%{http_code}' already prints 000 on a connection failure, so a
# `|| echo 000` fallback yields "000000", which never equals "000" -- the
# dead-backend branch then cannot fire and the failure is misdiagnosed.
assert_equals "0" \
  "$(grep -c "http_code}' .*|| echo 000" "$INGRESS" || true)" \
  "no doubled-000 fallback on the curl status probes"

# The whole point of the mechanism: exposure is proven by fetching it, not by
# trusting that `tailscale serve` exited 0.
assert_equals "1" "$(grep -c 'cmp -s "\$REMOTE_BODY" "\$LOCAL_BODY"' "$INGRESS" || true)" \
  "exposure is verified by comparing fetched bodies, not by exit code"

suite_summary

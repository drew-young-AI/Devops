#!/usr/bin/env bash
# Expose a local service off this machine, through Tailscale, on purpose.
#
# This closes the platform's oldest open item. `Plan.md` has carried "Public
# URL -- needs a human to choose a cloud provider" for weeks; it turned out
# not to need one. Every service here binds 127.0.0.1, Tailscale already runs
# on this host, and `tailscale serve` reaches loopback directly. No port is
# opened on the router, no inbound firewall rule exists, and no traffic
# transits a provider account nobody has created yet.
#
# TWO LEVELS, AND THE DIFFERENCE IS NOT COSMETIC.
#
#   serve    reachable by devices signed into this tailnet
#   funnel   reachable by the entire public internet
#
# `tailscale serve` and `tailscale funnel` differ by one word on the command
# line and by everything in blast radius. So the default action here is
# always serve, funnel must be named explicitly AND confirmed by typing, and
# each target carries a ceiling in targets.conf that funnel cannot exceed.
#
# THE REFUSAL.
#
# Prometheus, Alertmanager and Loki have no authentication at all. Exposing
# them is declined at any level -- not warned about, declined. Alertmanager
# is the sharpest case: /api/v2/silences is a write endpoint, so reaching it
# is enough to switch the monitoring off without switching anything off.
#
# Sibling in spirit to backup/sync_remote.sh, which refuses to upload
# unencrypted state to a third party. Same shape of mistake, same treatment:
# the dangerous thing is easy to do by accident and looks like the useful
# thing while you are doing it.
#
# VERIFICATION IS BY OBSERVATION.
#
# `tailscale serve` exiting 0 means the proxy was configured, not that the
# right service answers on it. So after configuring, this fetches the public
# URL and the local port and compares the bodies. If they differ, or the
# fetch fails, the serve is TORN DOWN again rather than left half-working.
#
# Usage:
#   ingress.sh --status
#   ingress.sh --serve  <name>     tailnet only (the default level)
#   ingress.sh --funnel <name>     public internet; asks for confirmation
#   ingress.sh --off    <name>
#   ingress.sh --reset             remove every proxy this machine serves
#
# Exit 0 only when the exposure exists AND was observed to serve the right
# service. Exit 78 (EX_CONFIG) when a prerequisite is missing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && cd .. && pwd)"
# Overridable so the teardown-on-mismatch path can be exercised against a
# deliberately broken target. A safety net that has never been observed
# catching anything is a claim, not a net.
TARGETS="${INGRESS_TARGETS:-$SCRIPT_DIR/targets.conf}"

# Serve ports are assigned per target so two exposures cannot collide. The
# base is deliberately not 80/443: those need root on macOS and would make
# this mechanism require privileges it has no other reason to hold.
SERVE_PORT_BASE=8080

die()  { echo "$@" >&2; exit 1; }
conf() { grep -vE '^\s*#|^\s*$' "$TARGETS"; }

ts() {
  # The CLI lives inside the app bundle; /usr/local/bin/tailscale is a two
  # line shim. Call it through the shim so this keeps working if the bundle
  # path changes.
  command tailscale "$@"
}

lookup() {
  local want="$1"
  conf | while IFS='|' read -r name port ceiling reason; do
    [ "$name" = "$want" ] && printf '%s|%s|%s\n' "$port" "$ceiling" "$reason"
  done
}

serve_port_for() {
  local want="$1" idx=0
  while IFS='|' read -r name _ _ _; do
    if [ "$name" = "$want" ]; then echo $((SERVE_PORT_BASE + idx)); return 0; fi
    idx=$((idx + 1))
  done < <(conf)
  return 1
}

usage() {
  echo "Usage: $0 [--status | --serve <name> | --funnel <name> | --off <name> | --reset]" >&2
  echo "" >&2
  echo "Targets:" >&2
  conf | while IFS='|' read -r name port ceiling _; do
    printf '  %-24s local:%-6s ceiling:%s\n' "$name" "$port" "$ceiling" >&2
  done
  exit 2
}

command -v tailscale >/dev/null 2>&1 || die "tailscale is not on PATH."
[ -f "$TARGETS" ] || die "Missing $TARGETS"

ACTION="${1:-}"
NAME="${2:-}"

# --- status --------------------------------------------------------------

if [ "$ACTION" = "--status" ]; then
  echo "=== tailscale ==="
  BACKEND="$(ts status --json 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin); s=d.get('Self',{})
    print(f\"  node    : {s.get('DNSName','?').rstrip('.')}\")
    print(f\"  online  : {s.get('Online')}\")
except Exception as e:
    print('  unavailable:', e)
" 2>/dev/null)"
  echo "$BACKEND"
  echo ""
  echo "=== exposures ==="
  SERVE_STATUS="$(ts serve status 2>&1)"
  if printf '%s' "$SERVE_STATUS" | grep -q "No serve config"; then
    echo "  none -- nothing on this machine is reachable off it"
  else
    printf '%s\n' "$SERVE_STATUS" | sed 's/^/  /'
  fi
  echo ""
  echo "=== ceilings ==="
  conf | while IFS='|' read -r name port ceiling _; do
    printf '  %-24s local:%-6s max:%s\n' "$name" "$port" "$ceiling"
  done
  exit 0
fi

if [ "$ACTION" = "--reset" ]; then
  ts serve reset 2>&1 | sed 's/^/  /'
  echo "All proxies removed. Nothing on this machine is reachable off it."
  exit 0
fi

[ -n "$NAME" ] || usage

ROW="$(lookup "$NAME")"
if [ -z "$ROW" ]; then
  echo "Unknown target '$NAME'." >&2
  usage
fi
IFS='|' read -r PORT CEILING REASON <<< "$ROW"
SERVE_PORT="$(serve_port_for "$NAME")"

# NEVER call `tailscale funnel ... off` speculatively.
#
# On a tailnet without funnel enabled it does not fail -- it BLOCKS, forever.
# Measured at 25s and still going when killed. Because it sat in the cleanup
# path, the one code path whose entire job is to undo a bad exposure was the
# path that could hang, taking the teardown with it. A safety net that wedges
# is worse than none, because the caller is left believing cleanup ran.
#
# So funnel is only ever torn down when it is actually up.
funnel_is_up() {
  ts serve status 2>/dev/null | grep -qi 'funnel'
}

drop_exposure() {
  local port="$1"
  ts serve --http="$port"  off >/dev/null 2>&1 || true
  ts serve --https="$port" off >/dev/null 2>&1 || true
  if funnel_is_up; then
    ts funnel --https="$port" off >/dev/null 2>&1 || true
  fi
}

if [ "$ACTION" = "--off" ]; then
  drop_exposure "$SERVE_PORT"
  echo "  $NAME is no longer exposed."
  exit 0
fi

case "$ACTION" in
  --serve)  WANT="tailnet" ;;
  --funnel) WANT="funnel" ;;
  *) usage ;;
esac

# --- the refusal ---------------------------------------------------------

if [ "$CEILING" = "never" ]; then
  echo "REFUSED: '$NAME' must not be exposed at any level." >&2
  echo "" >&2
  echo "  $REASON" >&2
  echo "" >&2
  echo "This is a property of the service, not of the request. If it ever" >&2
  echo "gains real authentication, change its ceiling in:" >&2
  echo "  $TARGETS" >&2
  exit 1
fi

if [ "$WANT" = "funnel" ] && [ "$CEILING" != "funnel" ]; then
  echo "REFUSED: '$NAME' has ceiling '$CEILING'; funnel would exceed it." >&2
  echo "" >&2
  echo "  $REASON" >&2
  echo "" >&2
  echo "Use --serve to reach it from inside the tailnet instead." >&2
  exit 1
fi

# --- prerequisites -------------------------------------------------------

# Funnel is HTTPS-only and needs a tailnet TLS cert. Without HTTPS enabled in
# the admin console the failure is a 500 from the control plane, which is not
# self-explanatory, so it is translated here rather than passed through.
if [ "$WANT" = "funnel" ]; then
  if ! ts cert --cert-file /dev/null --key-file /dev/null \
        "$(ts status --json 2>/dev/null | python3 -c "
import json,sys; print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))" 2>/dev/null)" >/dev/null 2>&1; then
    cat >&2 <<'EOF'
Cannot funnel: this tailnet cannot issue TLS certificates yet.

Funnel serves public HTTPS, so it needs a cert for the node's ts.net name.
That is a one-time tailnet setting, not something this script can do:

  https://login.tailscale.com/admin/dns
    -> enable "HTTPS Certificates"

  https://login.tailscale.com/admin/acls
    -> the node needs the "funnel" attribute in nodeAttrs, e.g.
       "nodeAttrs": [{"target": ["autogroup:member"], "attr": ["funnel"]}]

Then re-run. Tailnet-only exposure works today and needs neither:
  platform/ingress/ingress.sh --serve NAME
EOF
    exit 78
  fi
fi

NODE="$(ts status --json 2>/dev/null | python3 -c "
import json,sys; print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))" 2>/dev/null)"
[ -n "$NODE" ] || die "Could not determine this node's tailnet name."

# --- confirmation for public exposure ------------------------------------

if [ "$WANT" = "funnel" ]; then
  cat <<EOF

  ABOUT TO PUBLISH TO THE PUBLIC INTERNET

    target : $NAME  (local port $PORT)
    url    : https://${NODE}/
    reach  : anyone, anywhere, no Tailscale account required

  $REASON

EOF
  if [ ! -t 0 ]; then
    echo "REFUSED: publishing to the internet needs an interactive confirmation" >&2
    echo "and stdin is not a terminal. Run this from a terminal." >&2
    exit 1
  fi
  printf '  Type PUBLISH to continue: '
  read -r answer
  if [ "$answer" != "PUBLISH" ]; then
    echo "  Aborted. Nothing was exposed."
    exit 1
  fi
fi

# --- configure -----------------------------------------------------------

echo ""
echo "=== exposing $NAME (local $PORT) ==="

if [ "$WANT" = "funnel" ]; then
  ts funnel --bg --https="$SERVE_PORT" "http://127.0.0.1:${PORT}" >/dev/null 2>&1 \
    || die "tailscale funnel failed."
  URL="https://${NODE}/"
  LEVEL="PUBLIC INTERNET"
else
  # Plain HTTP inside the tailnet. Deliberate: tailnet traffic is already
  # WireGuard-encrypted node to node, and requiring HTTPS here would make
  # tailnet exposure depend on the same admin-console setting funnel needs --
  # blocking the useful, low-risk case on a prerequisite it does not have.
  ts serve --bg --http="$SERVE_PORT" "http://127.0.0.1:${PORT}" >/dev/null 2>&1 \
    || die "tailscale serve failed."
  URL="http://${NODE}:${SERVE_PORT}/"
  LEVEL="tailnet only"
fi

# --- verify by observation -----------------------------------------------

echo "  configured: $URL  ($LEVEL)"
echo "  verifying it actually serves $NAME ..."

REMOTE_BODY="$(mktemp)"; LOCAL_BODY="$(mktemp)"
# No `|| echo 000` here. curl -w already prints 000 when it cannot connect,
# so the fallback appended a SECOND one and produced "000000" -- which never
# equals "000", so the "local service is dead" branch below could not fire
# and the failure was misreported as a code mismatch instead.
REMOTE_CODE="$(curl -sS -m 20 -o "$REMOTE_BODY" -w '%{http_code}' "$URL" 2>/dev/null)"
LOCAL_CODE="$(curl -sS -m 10 -o "$LOCAL_BODY"  -w '%{http_code}' "http://127.0.0.1:${PORT}/" 2>/dev/null)"
[ -z "$REMOTE_CODE" ] && REMOTE_CODE=000
[ -z "$LOCAL_CODE" ]  && LOCAL_CODE=000

teardown() { drop_exposure "$SERVE_PORT"; }

if [ "$LOCAL_CODE" = "000" ]; then
  teardown; rm -f "$REMOTE_BODY" "$LOCAL_BODY"
  die "The local service on port $PORT is not answering. Nothing was left exposed."
fi

if [ "$REMOTE_CODE" != "$LOCAL_CODE" ]; then
  teardown; rm -f "$REMOTE_BODY" "$LOCAL_BODY"
  die "Exposed URL returned $REMOTE_CODE but the local service returned $LOCAL_CODE.
Torn down rather than left half-working."
fi

if ! cmp -s "$REMOTE_BODY" "$LOCAL_BODY"; then
  teardown; rm -f "$REMOTE_BODY" "$LOCAL_BODY"
  die "Exposed URL answered, but with a DIFFERENT body than the local service.
Something else is on that address. Torn down."
fi

rm -f "$REMOTE_BODY" "$LOCAL_BODY"

echo "  verified: $URL returns byte-identical output to 127.0.0.1:$PORT"
echo ""
echo "EXPOSED  $NAME  ->  $URL  ($LEVEL)"
echo ""
echo "  status: platform/ingress/ingress.sh --status"
echo "  remove: platform/ingress/ingress.sh --off $NAME"

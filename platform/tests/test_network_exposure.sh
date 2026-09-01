#!/usr/bin/env bash
# Which listeners are reachable from the LAN, and which are not.
#
# On 2026-08-26 the platform stopped being loopback-only: Grafana, Prometheus
# and the status vhost were published so a reviewer on another machine could
# open them. That is a deliberate decision with a real blast radius, and a
# decision like that decays into an accident unless something re-checks it.
#
# THE SPLIT, AND WHY IT IS WHERE IT IS.
#
#   published   grafana 13000    authenticates (anonymous off, admin password
#                                from Vault) -- the only one here that can
#               prometheus 19090 no auth, but READ-ONLY: neither
#                                --web.enable-lifecycle nor --web.enable-admin-api
#                                is set. Accepted by the platform owner.
#               status 18085     static, non-secret, allowlisted artifacts
#
#   loopback    alertmanager     its API SILENCES ALERTS. That is a write, and
#                                an attacker who can silence alerts can make an
#                                outage invisible -- worse than reading metrics
#               node-exporter    raw textfile source for the board
#               loki             log content, including anything the redaction
#                                pipeline did not catch
#               nginx TLS vhosts the pilot apps
#
# THE TRAP THIS TEST WAS WRITTEN AROUND.
#
# The first version probed the mDNS name (`<host>.local`) and reported every
# loopback-only service as REACHABLE. The name resolves to the LAN address AND
# to ::1, curl picked ::1, and the probe travelled over loopback the whole time.
# The refusals it was supposed to prove were never tested. So: IPv4 only, the
# LAN address literally, and -- because a refusal is worthless if the probe
# itself is broken -- the reachable set is proven FIRST. Nothing believes a
# connection refusal until the same method has demonstrably connected.

set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_SUITE="network-exposure"
# shellcheck source=lib.sh
source "$SUITE_DIR/lib.sh"

echo "== network exposure: what the LAN can reach =="

# LAN_IP_OVERRIDE exists so this suite can be tested against itself. Pointing
# it at 127.0.0.1 makes every loopback-only service answer, which MUST turn the
# refusal assertions red -- that is how we know they are assertions and not
# decoration. It is read from the environment and never set here.
LAN_IP="${LAN_IP_OVERRIDE:-$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)}"
if [ -z "$LAN_IP" ]; then
  echo "  SKIP  no LAN address on en0/en1 -- exposure cannot be measured from here"
  echo "        (this is a LOUD skip: it means the split below is UNVERIFIED)"
  suite_summary
  exit 0
fi
echo "  LAN address: $LAN_IP"

probe() {   # probe <port> <path> -> http code, or 000 when refused
  # No `|| echo 000` fallback: curl ALREADY writes 000 for a refused connection
  # and then exits 7, so the fallback appended a second 000 and every refusal
  # read as the string "000000" -- which is not "000", so the assertion failed
  # while the platform was behaving exactly as intended.
  /usr/bin/curl -4 -s -o /dev/null -w '%{http_code}' -m 5 \
    "http://${LAN_IP}:${1}${2}" 2>/dev/null
  return 0
}

# ---- 1. POSITIVE FIRST. A refusal means nothing until this passes. --------
PUBLIC_OK=0
for spec in "13000:/api/health:Grafana" "19090:/-/healthy:Prometheus" "18085:/healthz:狀態頁"; do
  port="${spec%%:*}"; rest="${spec#*:}"; path="${rest%%:*}"; name="${rest##*:}"
  code="$(probe "$port" "$path")"
  if [ "$code" = "200" ]; then
    _pass "$name ($port) is reachable from the LAN"
    PUBLIC_OK=$((PUBLIC_OK + 1))
  else
    _fail "$name ($port) is reachable from the LAN" "got HTTP $code from $LAN_IP:$port"
  fi
done

# ---- 2. Only now are refusals evidence of anything. ----------------------
if [ "$PUBLIC_OK" -eq 0 ]; then
  _fail "the probe method works at all" \
        "nothing answered on the LAN address, so every 'refused' below would be meaningless"
else
  _pass "the probe method works (${PUBLIC_OK} public listener(s) answered)"

  for spec in "19093:/-/healthy:Alertmanager（可靜音告警）" \
              "19100:/metrics:node-exporter" \
              "13100:/ready:Loki（日誌內容）" \
              "18443:/:nginx TLS vhost"; do
    port="${spec%%:*}"; rest="${spec#*:}"; path="${rest%%:*}"; name="${rest##*:}"
    code="$(probe "$port" "$path")"
    if [ "$code" = "000" ]; then
      _pass "$name ($port) is NOT reachable from the LAN"
    else
      _fail "$name ($port) is NOT reachable from the LAN" \
            "it answered HTTP $code -- this listener was never meant to leave loopback"
    fi
  done
fi

# ---- 3. Grafana must not have become anonymous while being published. ----
ANON="$(probe 13000 "/api/datasources")"
if [ "$ANON" = "401" ] || [ "$ANON" = "403" ]; then
  _pass "Grafana still refuses unauthenticated API access from the LAN"
else
  _fail "Grafana still refuses unauthenticated API access from the LAN" \
        "GET /api/datasources returned $ANON without credentials"
fi

# ---- 4. The status vhost serves an allowlist, not the docs directory. ----
LEAK="$(probe 18085 "/Plan-detail.md")"
if [ "$LEAK" = "404" ]; then
  _pass "status vhost does not serve internal design documents"
else
  _fail "status vhost does not serve internal design documents" \
        "/Plan-detail.md returned $LEAK -- the allowlist is not holding"
fi

# ---- 5. The name in the links must be a name that resolves. ----------------
#
# PLATFORM_LAN_HOST is not decoration. Grafana builds every share link and every
# alert link from it, and the Alertmanager mail template puts it in the
# Board:/Grafana: footer of every notification that goes out. It sat at
# `70.local` -- a leftover from an earlier hostname -- which does not resolve at
# all. Everything kept working locally, because nothing local ever follows those
# links. The only person who would have found out is the reviewer clicking the
# link in an alert mail, which is the worst possible moment.
#
# Asserted against DNS, not against a literal: hardcoding "mac.local" here would
# just be the same stale-name bug with a second copy.
ENVF="$REPO_ROOT/platform/observability/.env"
if [ -f "$ENVF" ]; then
  LAN_NAME="$(sed -n 's/^PLATFORM_LAN_HOST=//p' "$ENVF" | tail -1)"
  EXPECT="$(scutil --get LocalHostName 2>/dev/null).local"
  if [ -z "$LAN_NAME" ]; then
    _fail "PLATFORM_LAN_HOST is set" "not present in $ENVF"
  elif ! python3 -c "import socket,sys; socket.gethostbyname(sys.argv[1])" "$LAN_NAME" 2>/dev/null; then
    _fail "PLATFORM_LAN_HOST resolves" \
          "$LAN_NAME does not resolve. Every Grafana share link and every alert
          mail footer points at it. This machine answers to $EXPECT."
  else
    _pass "PLATFORM_LAN_HOST ($LAN_NAME) resolves"
  fi

  # And the running Grafana must be using it -- the file being right proves
  # nothing about the container, which only reads it at start.
  RU="$(docker inspect observability-grafana-1 \
        --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | sed -n 's/^GF_SERVER_ROOT_URL=//p')"
  case "$RU" in
    *"$LAN_NAME"*) _pass "the running Grafana builds links with $LAN_NAME" ;;
    "")            echo "  SKIP  Grafana container not running -- root_url UNVERIFIED" ;;
    *)             _fail "the running Grafana builds links with $LAN_NAME" \
                         "container still has GF_SERVER_ROOT_URL=$RU -- restart it" ;;
  esac
fi

suite_summary

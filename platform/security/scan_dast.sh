#!/usr/bin/env bash
# Dynamic application security testing (DAST) gate -- OWASP ZAP baseline.
#
# The counterpart to scan_sast.sh, and it catches a genuinely different
# class of problem. SAST reads source and cannot see anything that only
# exists at runtime: a missing security header added (or not added) by the
# reverse proxy, a debug endpoint left reachable, a TLS misconfiguration, a
# version banner. Those are properties of the DEPLOYED SYSTEM, not of any
# file in the repo -- no amount of source analysis will ever find them.
#
# Target defaults to the NGINX develop vhost rather than the container port,
# on purpose: that is the path a real client takes, so it measures what is
# actually exposed rather than what the application would expose if nothing
# sat in front of it. Scanning the app directly answers a different and less
# important question.
#
# Uses the ZAP *baseline* scan: passive rules plus a short spider. It sends
# no attack traffic, so it is safe to point at a running develop deployment
# and fast enough to belong in a pipeline. Active scanning (zap-full-scan)
# genuinely attacks the target and is deliberately not wired in -- that
# needs an explicit decision about what may be attacked and when.
#
# Policy: hard-fail at MEDIUM and above; LOW/INFO recorded without blocking.
#
# MEDIUM, not HIGH, and that threshold was chosen by measurement rather than
# by instinct. A passive baseline scan essentially never emits HIGH -- those
# come from active attack traffic, which this scan deliberately does not
# send. A HIGH-only gate was tested against a deliberately header-less page
# that produced three MEDIUM findings (missing CSP, missing anti-clickjacking,
# absent anti-CSRF tokens) and still reported PASS. A gate that passes that
# target is not a gate.
#
# MEDIUM findings from a baseline scan are also exactly the actionable kind:
# missing security headers, cross-domain misconfiguration. Override with
# DAST_FAIL_ON=HIGH|MEDIUM|LOW if a specific target needs different handling.
#
# Usage:
#   scan_dast.sh [target_url] [evidence_dir]
#
# Exit code: 0 if nothing at or above the threshold and the scan actually
# ran, 1 otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# host.docker.internal, not 127.0.0.1: ZAP runs in a container, so localhost
# there is the container itself.
#
# TARGET CHANGED 2026-08-25, from https://host.docker.internal:18443.
#
# That was station1-hello's nginx develop vhost. station1-hello was retired, its
# vhost removed, and nothing replaced it -- nginx now serves only
# _platform-health.conf on plain 8080. Compose still PUBLISHES 8443, so the TCP
# connect succeeded and the TLS handshake then died with SSL_ERROR_SYSCALL:
# a port that accepts and closes, which is exactly the shape of a target that
# looks alive from the outside and is not there.
#
# So the job had been red every day since the retirement, with the message
# "Is the develop deployment up?" pointing at a deployment that no longer
# exists. Nobody was going to bring it up.
#
# station2-twin is the platform's actual HTTP surface (Backlog.md 4 records why
# it is exposed directly rather than through nginx) and is the target Backlog.md
# 3 asked for: its POST /twin/<asset>/observation is the first write endpoint
# here that takes a JSON body.
#
# http, not https: station2-twin publishes plain HTTP on the loopback and TLS
# is terminated at the tailnet edge, not here. Scanning the real surface over
# the protocol it really speaks beats scanning a scheme that was only ever
# true of the retired vhost.
TARGET="${1:-http://host.docker.internal:18090}"
EVIDENCE_DIR="${2:-$REPO_ROOT/evidence/security}"
ZAP_IMAGE="${ZAP_IMAGE:-zaproxy/zap-stable}"
SPIDER_MINUTES="${SPIDER_MINUTES:-1}"
DAST_FAIL_ON="${DAST_FAIL_ON:-MEDIUM}"
# ZAP's own limit (minutes) and this script's hard limit (seconds).
ZAP_MAX_MINUTES="${ZAP_MAX_MINUTES:-5}"
DAST_TIMEOUT="${DAST_TIMEOUT:-600}"

if ! docker image inspect "$ZAP_IMAGE" >/dev/null 2>&1; then
  echo "ZAP image not present. Pull it with:" >&2
  echo "  docker pull --platform linux/arm64 $ZAP_IMAGE" >&2
  exit 1
fi

mkdir -p "$EVIDENCE_DIR"
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
SUMMARY_FILE="$EVIDENCE_DIR/dast_summary_${STAMP}.json"
RAW_FILE="$EVIDENCE_DIR/_raw.zap_${STAMP}.json"

WORK_DIR="$(mktemp -d)"
# ZAP runs as a non-root uid inside the container and must be able to write
# its report into the bind mount.
chmod 777 "$WORK_DIR"
echo "=== [dast] OWASP ZAP baseline against $TARGET ==="
echo "    gate: fail at $DAST_FAIL_ON and above"

# Reachability is checked first so an unreachable target is reported as such
# rather than as a scan that found nothing wrong.
#
# The URL is rewritten for this check only: `host.docker.internal` resolves
# INSIDE a container, not on the host running this script, so probing the
# target verbatim always fails and reports a healthy service as unreachable.
# ZAP still receives the original URL, because from its side that name is
# the correct one. -k because the develop vhost uses a mkcert certificate
# that is not in this shell's trust store.
PROBE_URL="${TARGET//host.docker.internal/127.0.0.1}"
if ! curl -sk -o /dev/null --max-time 10 "$PROBE_URL"; then
  echo "DAST FAILED: target $TARGET (probed as $PROBE_URL) is not reachable." >&2
  echo "Check, in this order:" >&2
  echo "  1. Is the target up?   docker compose -f pilots/station2-twin/compose.yaml ps" >&2
  echo "  2. Is it still THERE?  A published port whose service was retired still" >&2
  echo "     accepts TCP and then closes -- that is what 18443 did for days after" >&2
  echo "     station1-hello went away. curl -v will show the handshake dying." >&2
  exit 1
fi

# -I: do not use the exit code to signal warnings. The gate decision is made
# below from the report, so that the policy lives in one readable place
# instead of being split between a CLI flag and this script.
#
# -T bounds ZAP's own wait for startup and passive scanning.
#
# THE MARKETPLACE HOSTS ARE POINTED AT 127.0.0.1 ON PURPOSE.
#
# zap-baseline.py always starts ZAP with `-addonupdate -addoninstall`, with no
# flag to skip it, so every run reaches out to the ZAP marketplace. When that
# is unreachable -- measured here: `wget` to the ZapVersions XML fails from
# inside the container -- ZAP does not fail fast, it retries until something
# gives up. Same scan: **over 10 minutes with no output at all**, versus
# **29 seconds** once the lookup fails immediately.
#
# Mapping the hosts to 127.0.0.1 turns a slow timeout into an instant
# connection refused. The scan runs entirely on the rules baked into the
# image, which is what a reproducible gate wants anyway: pulling fresh rules
# from the internet mid-scan means the same commit can pass today and fail
# tomorrow, exactly the non-determinism the pinned Semgrep rulesets avoid.
#
# The deeper point: this gate had been silently depending on outbound internet
# since the day it was written. It only looked reliable because the network
# happened to cooperate. A gate that can hang indefinitely is a gate people
# start skipping.
#
# The container is NAMED rather than anonymous so it can be killed by name if
# the outer timeout fires -- `docker run --rm` cleans up on normal exit, but
# killing the client leaves the container running, which is how a stale ZAP
# ends up holding CPU for an hour after the script that started it is gone.
CONTAINER_NAME="zap-dast-$$"
cleanup_zap() { docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true; }
trap 'cleanup_zap; rm -rf "$WORK_DIR"' EXIT

RC_FILE="$WORK_DIR/.zap_rc"

set +e
( docker run --rm --name "$CONTAINER_NAME" \
  -v "$WORK_DIR:/zap/wrk:rw" \
  --add-host=host.docker.internal:host-gateway \
  --add-host=raw.githubusercontent.com:127.0.0.1 \
  --add-host=github.com:127.0.0.1 \
  "$ZAP_IMAGE" zap-baseline.py \
    -t "$TARGET" \
    -J report.json \
    -I \
    -m "$SPIDER_MINUTES" \
    -T "$ZAP_MAX_MINUTES" \
  > "$WORK_DIR/zap.log" 2>&1; echo $? > "$RC_FILE" ) &
DOCKER_PID=$!
disown 2>/dev/null || true

# Poll for the RESULT FILE, not for the pid.
#
# The obvious `while kill -0 "$DOCKER_PID"` loop is wrong here, and wrong in a
# way that produces a false failure rather than an error: after `disown` the
# shell never reaps the finished child, so it lingers as a zombie -- and
# `kill -0` succeeds on a zombie. The loop therefore never exits, and every
# scan burned the full timeout and reported DAST FAILED while ZAP had in fact
# completed cleanly minutes earlier.
#
# A gate that falsely fails is as corrosive as one that falsely passes: people
# start ignoring it. This is the second time this exact shape has bitten this
# repo (see run_job.sh) -- hence the rc-file pattern is now the convention.
ELAPSED=0
ZAP_TIMED_OUT=0
while [ ! -f "$RC_FILE" ]; do
  if [ "$ELAPSED" -ge "$DAST_TIMEOUT" ]; then
    echo "DAST FAILED: exceeded ${DAST_TIMEOUT}s hard timeout -- killing ZAP." >&2
    cleanup_zap
    kill -KILL "$DOCKER_PID" 2>/dev/null
    ZAP_TIMED_OUT=1
    break
  fi
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done
ZAP_RC="$(cat "$RC_FILE" 2>/dev/null || echo 0)"
[ "$ZAP_TIMED_OUT" -eq 1 ] && ZAP_RC=124
set -e

if [ "$ZAP_TIMED_OUT" -eq 1 ]; then
  exit 1
fi

if [ ! -f "$WORK_DIR/report.json" ]; then
  echo "DAST FAILED: ZAP produced no report (rc=$ZAP_RC)" >&2
  tail -15 "$WORK_DIR/zap.log" >&2
  exit 1
fi

cp "$WORK_DIR/report.json" "$RAW_FILE"

# set +e around the gate block: it exits non-zero to signal "blocked", and
# under `set -e` that terminated the script instantly -- skipping the
# cleanup, the failure message and the artifact path, so a blocked scan
# printed its findings and then just vanished with a bare exit code. Found
# by a leftover .err file, not by reading the code.
set +e
python3 - "$RAW_FILE" "$SUMMARY_FILE" "$TARGET" "$STAMP" "$DAST_FAIL_ON" <<'PY'
import json, pathlib, sys

raw_path, summary_path, target, stamp, fail_on = sys.argv[1:]
data = json.loads(pathlib.Path(raw_path).read_text())

RISK = {0: "INFO", 1: "LOW", 2: "MEDIUM", 3: "HIGH"}
counts = {"HIGH": 0, "MEDIUM": 0, "LOW": 0, "INFO": 0}
alerts, urls = [], set()

for site in data.get("site", []):
    for alert in site.get("alerts", []):
        level = RISK.get(int(alert.get("riskcode", 0)), "INFO")
        counts[level] += 1
        instances = alert.get("instances", [])
        for inst in instances:
            if inst.get("uri"):
                urls.add(inst["uri"])
        alerts.append({
            "risk": level,
            "confidence": int(alert.get("confidence", 0)),
            "name": alert.get("alert"),
            "instances": len(instances),
            "example_uri": instances[0].get("uri") if instances else None,
            "solution": (alert.get("solution") or "").strip()[:300],
        })

# Integrity: did ZAP actually reach and scan the target?
#
# The first version tested `len(urls) == 0`, where `urls` came from ALERT
# INSTANCES -- so it counted URLs that produced findings, not URLs scanned.
# On a clean target that number falls to zero, which meant **a target with no
# security findings at all would fail the gate for "scanning nothing"**. The
# better the system under test, the more likely a false failure.
#
# `site` entries are the honest signal: ZAP emits one per host it actually
# connected to and scanned, findings or not.
sites = [s.get("@name") for s in data.get("site", []) if s.get("@name")]
integrity_failed = len(sites) == 0

# Everything at or above the configured threshold blocks.
ORDER = ["INFO", "LOW", "MEDIUM", "HIGH"]
threshold = ORDER.index(fail_on)
blocking = [a for a in alerts if ORDER.index(a["risk"]) >= threshold]
blocked = bool(blocking)

summary = {
    "tool": "owasp-zap-baseline",
    "scanned_at": stamp,
    "target": target,
    "scan_type": "baseline (passive rules + spider; no attack traffic)",
    "gate_policy": f"fail at {fail_on} and above; below that recorded, not blocking",
    "fail_on": fail_on,
    "blocking_alerts": [a["name"] for a in blocking],
    "gate_result": "FAIL" if (blocked or integrity_failed) else "PASS",
    "sites_scanned": sites,
    # Named for what it is. This counts URLs appearing in alerts, NOT scan
    # coverage -- conflating the two is what produced the false-failure above.
    "urls_in_alerts": len(urls),
    "counts_by_risk": counts,
    "alerts": sorted(alerts, key=lambda a: -["INFO", "LOW", "MEDIUM", "HIGH"].index(a["risk"])),
    "scan_integrity": {
        "ok": not integrity_failed,
        "note": ("No site entry means ZAP never reached the target. That "
                 "is a broken scan, not a clean result, and is treated as a "
                 "gate failure. Coverage is judged by sites scanned, never "
                 "by how many findings were produced."),
    },
}
pathlib.Path(summary_path).write_text(json.dumps(summary, indent=2) + "\n")

print(f"  sites scanned: {', '.join(sites) if sites else 'NONE'}"
      f"   (urls in alerts: {len(urls)})")
print(f"  HIGH={counts['HIGH']}  MEDIUM={counts['MEDIUM']}  LOW={counts['LOW']}  INFO={counts['INFO']}")
for a in summary["alerts"]:
    if a["risk"] != "INFO":
        mark = " <-- BLOCKING" if ORDER.index(a["risk"]) >= threshold else ""
        print(f"    [{a['risk']}] {a['name']}  (x{a['instances']}){mark}")
if integrity_failed:
    print("  SCAN INTEGRITY FAILURE: ZAP produced no site entry -- it never "
          "reached the target. Results are not trustworthy.")

sys.exit(1 if (blocked or integrity_failed) else 0)
PY
GATE_RC=$?
set -e

if [ "$GATE_RC" -eq 0 ]; then
  echo "DAST PASS"
else
  echo "DAST FAILED -- see $SUMMARY_FILE" >&2
fi
echo "artifact=$SUMMARY_FILE"
exit "$GATE_RC"

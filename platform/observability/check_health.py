#!/usr/bin/env python3
"""Health verdict engine -- see check_health.sh for the exit-code contract.

The ordering below is deliberate and is the whole design: every
monitoring-integrity check runs and must pass BEFORE the alert list is
interpreted. An empty alert list is only meaningful once we have proven
something was actually watching.
"""

import json
import os
import socket
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

TIMEOUT = 10

HEALTHY, DEGRADED, CRITICAL, UNKNOWN = 0, 1, 2, 3


def fetch(url):
    """Returns (parsed_json, error_string)."""
    try:
        with urllib.request.urlopen(url, timeout=TIMEOUT) as response:
            return json.load(response), None
    except urllib.error.HTTPError as exc:
        return None, f"HTTP {exc.code} {exc.reason}"
    except urllib.error.URLError as exc:
        if isinstance(exc.reason, socket.timeout):
            return None, f"no response within {TIMEOUT}s"
        return None, str(exc.reason)
    except socket.timeout:
        # Python 3.9: socket.timeout is not TimeoutError. See
        # platform/llm-review/README.md for the same trap found there.
        return None, f"no response within {TIMEOUT}s"
    except (OSError, json.JSONDecodeError) as exc:
        return None, str(exc)


def main():
    prometheus = os.environ["PROMETHEUS_URL"].rstrip("/")
    alertmanager = os.environ["ALERTMANAGER_URL"].rstrip("/")

    checked_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    integrity = []   # (name, ok, detail)
    blockers = []

    # --- Monitoring integrity, all of it, before touching the alert list ---

    rules, err = fetch(f"{prometheus}/api/v1/rules")
    if err:
        integrity.append(("prometheus_reachable", False, err))
        blockers.append(f"Prometheus unreachable: {err}")
        rules = None
    else:
        integrity.append(("prometheus_reachable", True, "api/v1/rules responded"))

    rule_count = 0
    broken_rules = []
    if rules:
        for group in rules.get("data", {}).get("groups", []):
            for rule in group.get("rules", []):
                rule_count += 1
                if rule.get("health") != "ok":
                    broken_rules.append(f"{rule.get('name')}: {rule.get('lastError')}")
        # Zero loaded rules means nothing can ever fire. That is the same
        # silent failure as a dead Prometheus, wearing a healthy costume.
        integrity.append(("alert_rules_loaded", rule_count > 0, f"{rule_count} rules"))
        if rule_count == 0:
            blockers.append("Prometheus has 0 alert rules loaded -- nothing can fire")
        integrity.append(
            ("alert_rules_evaluating", not broken_rules, "; ".join(broken_rules) or "all ok")
        )
        if broken_rules:
            blockers.append(f"{len(broken_rules)} alert rule(s) failing to evaluate")

    # Prometheus can be perfectly healthy and still have no Alertmanager
    # wired, in which case alerts fire into the void and the alert list this
    # script reads stays empty forever.
    ams, err = fetch(f"{prometheus}/api/v1/alertmanagers")
    if err:
        integrity.append(("alertmanager_wired", False, err))
        blockers.append(f"Cannot confirm Alertmanager wiring: {err}")
    else:
        active = ams.get("data", {}).get("activeAlertmanagers", [])
        integrity.append(("alertmanager_wired", bool(active), f"{len(active)} active"))
        if not active:
            blockers.append("Prometheus has no active Alertmanager -- alerts go nowhere")

    alerts, err = fetch(f"{alertmanager}/api/v2/alerts?active=true")
    if err:
        integrity.append(("alertmanager_reachable", False, err))
        blockers.append(f"Alertmanager unreachable: {err}")
        alerts = None
    else:
        integrity.append(("alertmanager_reachable", True, "api/v2/alerts responded"))

    targets, err = fetch(f"{prometheus}/api/v1/targets")
    scrape_summary = {}
    if err:
        integrity.append(("scrape_targets_visible", False, err))
    else:
        active_targets = targets.get("data", {}).get("activeTargets", [])
        for target in active_targets:
            labels = target.get("labels", {})
            key = f"{labels.get('job')}/{labels.get('color') or labels.get('environment') or '-'}"
            scrape_summary[key] = target.get("health")
        # Not a blocker: a target being down is what the ALERTS are for, and
        # the idle blue/green color is legitimately down. Recorded for
        # diagnosis, not used for the verdict.
        integrity.append(
            ("scrape_targets_visible", bool(active_targets), f"{len(active_targets)} targets")
        )

    # --- Verdict ---

    if blockers:
        verdict, exit_code = "UNKNOWN", UNKNOWN
        active_alerts = []
    else:
        active_alerts = [
            {
                "alertname": a["labels"].get("alertname"),
                "severity": a["labels"].get("severity", "unknown"),
                "environment": a["labels"].get("environment"),
                "service": a["labels"].get("service"),
                "summary": a.get("annotations", {}).get("summary"),
                "runbook": a.get("annotations", {}).get("runbook"),
                "started_at": a.get("startsAt"),
            }
            for a in (alerts or [])
        ]
        severities = {a["severity"] for a in active_alerts}
        if "critical" in severities:
            verdict, exit_code = "CRITICAL", CRITICAL
        elif active_alerts:
            verdict, exit_code = "DEGRADED", DEGRADED
        else:
            verdict, exit_code = "HEALTHY", HEALTHY

    record = {
        "verdict": verdict,
        "exit_code": exit_code,
        "checked_at": checked_at,
        "monitoring_integrity": [
            {"check": name, "ok": ok, "detail": detail} for name, ok, detail in integrity
        ],
        "integrity_blockers": blockers,
        "active_alerts": active_alerts,
        "scrape_targets": scrape_summary,
        "sources": {"prometheus": prometheus, "alertmanager": alertmanager},
    }

    if os.environ.get("CHECK_EVIDENCE") == "1":
        evidence_dir = os.environ["EVIDENCE_DIR"]
        os.makedirs(evidence_dir, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        base = os.path.join(evidence_dir, f"health_{stamp}")
        path, dedupe = f"{base}.json", 2
        while os.path.exists(path):
            path = f"{base}-{dedupe}.json"
            dedupe += 1
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(record, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        record["artifact"] = path

    if os.environ.get("CHECK_JSON") == "1":
        print(json.dumps(record, indent=2, ensure_ascii=False))
        sys.exit(exit_code)

    print(f"verdict: {verdict}")
    for name, ok, detail in integrity:
        print(f"  [{'ok ' if ok else 'FAIL'}] {name}: {detail}")
    if blockers:
        print("\nHealth could NOT be determined -- monitoring itself is broken:")
        for blocker in blockers:
            print(f"  - {blocker}")
        print("\n'No alerts' from a broken monitor is not health. Fix monitoring first.")
    elif active_alerts:
        print(f"\n{len(active_alerts)} active alert(s):")
        for alert in active_alerts:
            print(f"  [{alert['severity']}] {alert['alertname']} ({alert['environment']})")
            print(f"      {alert['summary']}")
            if alert["runbook"]:
                print(f"      runbook: {alert['runbook']}")
    else:
        print("\nNo active alerts, and monitoring verified working.")
    if "artifact" in record:
        print(f"\nartifact={record['artifact']}")

    sys.exit(exit_code)


if __name__ == "__main__":
    main()

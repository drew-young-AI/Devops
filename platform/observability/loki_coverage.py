#!/usr/bin/env python3
"""The log pipeline: is anything actually flowing through it, and into which tenant.

THE PROBLEM THIS SOLVES.

`docker ps` says loki is Up. compose declares two tenants with different
retention. `config.alloy` declares redaction on both pipelines. The ingress
guard refuses to expose loki. Every one of those is a statement about
CONFIGURATION, and not one of them is evidence that a single log line has ever
arrived -- which is the same shape as a rotation sweep passing over an empty
set, and as a DAST run reporting PASS over four of ten routes.

So this asks the three questions the configuration cannot answer:

  1. how many lines and streams has each tenant actually received
  2. which DECLARED tenant has never received anything
  3. does every service declare a data class that the routing rules recognise

QUESTION 3 IS THE ONE WITH TEETH, AND IT FAILS OPEN.

`discovery.relabel` keeps a container in the restricted tenant only when its
`platform.data_class` label matches the literal string "restricted"; the
internal pipeline is the exact complement. That is a correct partition, and it
means an UNRECOGNISED value is not an error -- it silently lands in `internal`,
which is the tenant with the WIDER audience and the LONGER retention (168h vs
72h). A service that meant `restricted` and typed `restrictd` would ship its
sensitive logs to the wider tenant and nothing anywhere would say so.

The label is deliberately owned by the service rather than by a hardcoded list
in Alloy, and that is the right call -- a central list goes stale every time a
service is added. But a declaration nobody validates is a declaration that can
be wrong, so the validation belongs here rather than in the routing rules,
where adding it would break the complement property that makes the partition
provable.

Question 2 is reported, never failed. `restricted` having zero streams is the
correct state when no service currently declares itself restricted; failing on
it would produce a check that is red by design, and a check that is always red
is a check people stop reading.

Usage:
  loki_coverage.py             human-readable report
  loki_coverage.py --json      machine-readable
  loki_coverage.py --check     exit 1 on an unrecognised data class

Exit codes:
  0  every declared class is recognised, and the primary tenant is carrying logs
  1  --check found a service declaring a data class the routing does not know
  2  Loki unreachable, or below the floor -- refusing to report
"""

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

METRICS_URL = os.environ.get("LOKI_METRICS_URL", "http://127.0.0.1:13100/metrics")
# Tests substitute a captured metrics body rather than pointing a real Loki at
# synthetic data. Simulating the fault beats manufacturing it (CLAUDE.md 5c).
METRICS_FILE = os.environ.get("LOKI_COVERAGE_METRICS_FILE") or ""
PROM_OUT = os.environ.get("LOKI_COVERAGE_PROM") or os.path.join(
    REPO_ROOT, "evidence", "statusdag", "loki_coverage.prom")
ALLOY_CONF = os.environ.get("LOKI_ALLOY_CONFIG") or os.path.join(
    HERE, "alloy", "config.alloy")

# The classes the routing rules can actually distinguish. Anything else is
# indistinguishable from a typo, and lands in the wider tenant.
VALID_CLASSES = {"internal", "restricted"}

# A pipeline that has been up for hours and carries a handful of lines has not
# started; it has failed quietly. Reporting "0 unrecognised classes" over an
# empty pipeline is a clean bill of health derived from nothing.
MIN_LINES = 100
MIN_STREAMS = 5
PRIMARY_TENANT = "platform"

LINES_RE = re.compile(r'^loki_distributor_lines_received_total\{([^}]*)\}\s+([0-9.e+]+)', re.M)
STREAMS_RE = re.compile(r'^loki_ingester_streams_created_total\{([^}]*)\}\s+([0-9.e+]+)', re.M)
BYTES_RE = re.compile(r'^loki_distributor_bytes_received_total\{([^}]*)\}\s+([0-9.e+]+)', re.M)
TENANT_RE = re.compile(r'tenant(?:_id)?="([^"]*)"')
DECLARED_TENANT_RE = re.compile(r'tenant_id\s*=\s*"([^"]+)"')


def read_metrics():
    if METRICS_FILE:
        with open(METRICS_FILE, "r") as handle:
            return handle.read()
    try:
        with urllib.request.urlopen(METRICS_URL, timeout=10) as response:
            return response.read().decode("utf-8", "replace")
    except (urllib.error.URLError, OSError) as exc:
        sys.stderr.write(
            "REFUSED: cannot reach Loki metrics at %s (%s).\n"
            "  Without them there is no evidence either way, and 'no findings'\n"
            "  from a check that could not look is worse than no check.\n"
            % (METRICS_URL, exc))
        return None


def sum_by_tenant(pattern, body):
    """Loki splits these counters across label sets; sum them per tenant."""
    totals = {}
    for labels, value in pattern.findall(body):
        match = TENANT_RE.search(labels)
        if not match:
            continue
        totals[match.group(1)] = totals.get(match.group(1), 0.0) + float(value)
    return totals


def declared_tenants():
    try:
        with open(ALLOY_CONF, "r") as handle:
            return sorted(set(DECLARED_TENANT_RE.findall(handle.read())))
    except OSError:
        return []


def declared_classes():
    """Every platform.data_class value any tracked compose file declares.

    Read from the repository rather than from `docker inspect`, so the check
    means the same thing whether or not the service happens to be running --
    a stopped service with a typo is still a typo.
    """
    override = os.environ.get("LOKI_COVERAGE_CLASS_VALUES")
    if override is not None:
        return sorted({v.strip() for v in override.split(",") if v.strip()})
    out = subprocess.run(
        ["git", "-C", REPO_ROOT, "grep", "-h", "-E",
         r"platform\.data_class\s*[:=]", "--", "*.yaml", "*.yml"],
        capture_output=True, text=True, check=False).stdout
    values = set()
    for line in out.splitlines():
        # A commented-out example is not a declaration. Counting one would
        # report a finding against documentation, and a check that fires on
        # its own docs is a check people learn to ignore.
        if line.lstrip().startswith("#"):
            continue
        match = re.search(r"platform\.data_class\s*[:=]\s*\"?'?([A-Za-z0-9_.-]+)", line)
        if match:
            values.add(match.group(1))
    return sorted(values)


def report():
    body = read_metrics()
    if body is None:
        return None
    lines = sum_by_tenant(LINES_RE, body)
    streams = sum_by_tenant(STREAMS_RE, body)
    payload = sum_by_tenant(BYTES_RE, body)
    declared = declared_tenants()
    classes = declared_classes()
    unrecognised = [c for c in classes if c not in VALID_CLASSES]
    unexercised = [t for t in declared if streams.get(t, 0) == 0]
    return {
        "primary_tenant": PRIMARY_TENANT,
        "lines": {k: int(v) for k, v in sorted(lines.items())},
        "streams": {k: int(v) for k, v in sorted(streams.items())},
        "bytes": {k: int(v) for k, v in sorted(payload.items())},
        "declared_tenants": declared,
        "unexercised_tenants": unexercised,
        "declared_classes": classes,
        "unrecognised_classes": unrecognised,
    }


def reportable_tenants(data):
    """Declared tenants, plus any tenant that actually carried traffic.

    Loki mints a counter for every X-Scope-OrgID it is ever asked about, so a
    stray curl leaves a zero-valued tenant behind for ever. Exporting those
    would put series like tenant="fake" into Prometheus permanently, where
    they outlive the probe that created them and read as real tenants.
    """
    return sorted(set(data["declared_tenants"]) | {
        t for t in set(data["lines"]) | set(data["streams"])
        if data["lines"].get(t, 0) or data["streams"].get(t, 0)
    })


def write_prom(data):
    shown = reportable_tenants(data)
    lines = [
        "# HELP devops_loki_lines_received_total Log lines Loki has accepted, by tenant.",
        "# TYPE devops_loki_lines_received_total counter",
    ]
    for tenant in shown:
        lines.append('devops_loki_lines_received_total{tenant="%s"} %d'
                     % (tenant, data["lines"].get(tenant, 0)))
    lines += [
        "# HELP devops_loki_streams_total Distinct log streams per tenant.",
        "# TYPE devops_loki_streams_total gauge",
    ]
    for tenant in shown:
        lines.append('devops_loki_streams_total{tenant="%s"} %d'
                     % (tenant, data["streams"].get(tenant, 0)))
    lines += [
        "# HELP devops_loki_unrecognised_class_total Services declaring a data class the routing cannot distinguish.",
        "# TYPE devops_loki_unrecognised_class_total gauge",
        "devops_loki_unrecognised_class_total %d" % len(data["unrecognised_classes"]),
        "# HELP devops_loki_unexercised_tenant_total Declared tenants that have never carried a stream.",
        "# TYPE devops_loki_unexercised_tenant_total gauge",
        "devops_loki_unexercised_tenant_total %d" % len(data["unexercised_tenants"]),
    ]
    os.makedirs(os.path.dirname(PROM_OUT), exist_ok=True)
    tmp = PROM_OUT + ".tmp"
    with open(tmp, "w") as handle:
        handle.write("\n".join(lines) + "\n")
    os.replace(tmp, PROM_OUT)


def main(argv):
    data = report()
    if data is None:
        return 2

    primary_lines = data["lines"].get(PRIMARY_TENANT, 0)
    primary_streams = data["streams"].get(PRIMARY_TENANT, 0)
    if primary_lines < MIN_LINES or primary_streams < MIN_STREAMS:
        sys.stderr.write(
            "REFUSED: tenant %s carries %d line(s) in %d stream(s), below the floor "
            "(%d/%d).\n"
            "  The log pipeline is configured but is not moving anything. Reporting\n"
            "  on data classes when no logs are flowing describes a pipeline that\n"
            "  is not running.\n"
            % (PRIMARY_TENANT, primary_lines, primary_streams, MIN_LINES, MIN_STREAMS))
        return 2

    write_prom(data)

    if "--json" in argv:
        print(json.dumps(data, indent=2, ensure_ascii=False))
    else:
        print("log pipeline coverage")
        for tenant in reportable_tenants(data):
            mark = "" if data["streams"].get(tenant, 0) else "   <- declared, never used"
            print("  %-16s %8d lines  %5d streams  %9d bytes%s"
                  % (tenant, data["lines"].get(tenant, 0), data["streams"].get(tenant, 0),
                     data["bytes"].get(tenant, 0), mark))
        print("  data classes declared in compose: %s"
              % (", ".join(data["declared_classes"]) or "(none)"))
        if data["unrecognised_classes"]:
            print("  UNRECOGNISED DATA CLASS (routes to the wider tenant silently):")
            for value in data["unrecognised_classes"]:
                print("      platform.data_class=%s   not in {%s}"
                      % (value, ", ".join(sorted(VALID_CLASSES))))
        else:
            print("  every declared data class is one the routing can distinguish")

    if "--check" in argv:
        return 1 if data["unrecognised_classes"] else 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

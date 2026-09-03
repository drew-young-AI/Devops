#!/usr/bin/env bash
# Export the HOST's disk capacity as Prometheus text, into node-exporter's
# textfile directory.
#
# WHY THIS EXISTS.
#
# On 2026-09-03 the macOS data volume reached 100% (133Mi free). Prometheus
# stopped answering, Docker's engine died at 11:23, and the entire platform
# stopped -- 91 capabilities, 777 green assertions, 14 alert rules, all of it
# taken down by one quantity that nothing measured. Not one of the 14 rules
# referenced free space. The failure shape is
# 「監控系統被它沒有監控的東西弄停了」.
#
# WHY NOT node-exporter's OWN filesystem COLLECTOR.
#
# Two independent reasons, either one sufficient:
#
#   1. It is switched off. compose.yaml starts node-exporter with
#      `--collector.disable-defaults --collector.textfile`, so the ONLY thing
#      that exporter produces is whatever is written into /textfile.
#      `node_filesystem_avail_bytes` does not exist in this Prometheus.
#
#   2. Turning it on would measure the WRONG DISK. node-exporter is a Linux
#      container; on macOS it runs inside Docker's Linux VM and its /proc
#      describes that VM's ext4 filesystem living INSIDE Docker.raw -- not the
#      APFS volume that actually filled up. Enabling the collector would give
#      a confident green number about a disk that was never the problem, which
#      is worse than the acknowledged gap it replaces.
#
# So the host figure has to be produced ON the host and handed in through the
# textfile channel, which is exactly what dag.py already does. Same mechanism,
# separate file and separate schedule so that a dag.py failure cannot take the
# disk metric with it.
#
# WHICH MOUNT POINT.
#
# `/System/Volumes/Data` (/dev/disk3s5), NOT `/`. On Apple Silicon `/` is the
# sealed, read-only system snapshot (/dev/disk3s1s1); `df /` reports it as
# ~100% used at all times because it is a fixed-size seal, and reading that as
# "the disk is full" -- or worse, as "the disk is fine" -- answers a different
# question than the one being asked. This misreading has already happened once
# during the outage.
#
# Usage: platform/observability/host_disk_metrics.sh [--stdout]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

DATA_VOLUME="${HOST_DISK_MOUNT:-/System/Volumes/Data}"
# HOME, resolved rather than assumed. launchd starts scheduled jobs with an
# almost empty environment -- no HOME -- and under `set -u` a bare $HOME is an
# unbound-variable error, so this script would have failed on EVERY scheduled
# run while working perfectly by hand. That is the platform's oldest failure
# shape: 「登記為存在，但不執行」. Verified with `env -i`, which is what the
# 2026-09-03 scheduler check used.
HOME_DIR="${HOME:-}"
if [ -z "$HOME_DIR" ]; then
  HOME_DIR="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
fi
DOCKER_RAW="${HOST_DOCKER_RAW:-$HOME_DIR/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw}"
# Same directory node-exporter mounts as /textfile (compose.yaml). The three
# env overrides exist so the synthetic control can point every input at a
# fixture and prove the alert can go red WITHOUT filling a real disk -- CLAUDE.md
# §5c forbids injecting the real fault on this host.
OUT="${HOST_DISK_PROM:-$REPO_ROOT/evidence/statusdag/host_disk.prom}"

emit() {
  # -k, not -h. Human-readable output rounds ("292Gi") and a rounded number
  # cannot be compared against a threshold without silently importing the
  # rounding error. 1024-byte blocks convert exactly.
  local line size_kb avail_kb
  line="$(df -k "$DATA_VOLUME" 2>/dev/null | awk 'NR==2')"
  if [ -z "$line" ]; then
    echo "host_disk_metrics: df failed for $DATA_VOLUME" >&2
    return 1
  fi
  size_kb="$(awk '{print $2}' <<<"$line")"
  avail_kb="$(awk '{print $4}' <<<"$line")"

  echo "# HELP host_filesystem_size_bytes Total size of a macOS host volume."
  echo "# TYPE host_filesystem_size_bytes gauge"
  echo "host_filesystem_size_bytes{mountpoint=\"$DATA_VOLUME\"} $((size_kb * 1024))"
  echo "# HELP host_filesystem_avail_bytes Space available to an unprivileged user on a macOS host volume."
  echo "# TYPE host_filesystem_avail_bytes gauge"
  echo "host_filesystem_avail_bytes{mountpoint=\"$DATA_VOLUME\"} $((avail_kb * 1024))"

  # HOW BIG IS Docker.raw, REALLY.
  #
  #   apparent   what `ls -lh` prints -- the virtual size the guest sees. On
  #              this machine that is 926.30 GiB, i.e. the entire volume. Read
  #              alone it looks like an emergency and is not one; it has not
  #              moved by a byte through any of the work below.
  #   allocated  blocks APFS has actually handed over (st_blocks x 512). This is
  #              the number that competes with everything else on the volume,
  #              and the only one worth alerting on.
  #
  # Exporting only the first would manufacture a false alarm. Exporting only the
  # second would hide that the two differ by a factor of 44.
  #
  # AND IT SHRINKS -- MEASURED, AGAINST THE OPPOSITE EXPECTATION.
  #
  # The widely repeated rule is that Docker.raw on macOS only ever grows, so
  # pruning inside the VM returns nothing to the host. That was written into
  # this file first and then tested, on 2026-09-03 (Docker Desktop 4.84.0,
  # engine 29.6.2, Apple Silicon):
  #
  #   before reclaim            24.03 GB allocated
  #   reclaimed inside the VM   ~2.7 GB (build cache 1.67 GB, three dangling
  #                             images, one unreferenced 424 MB image)
  #   after, within minutes     22.49 GB allocated, stable across three samples
  #                             20s apart -- 1.4 GiB returned to APFS
  #
  # So this version does discard and the host file does shrink. The old rule
  # still holds for older Docker Desktop builds; it does not hold here. The
  # reason to keep exporting both numbers is unchanged either way -- but a
  # runbook telling someone that pruning cannot help them would have been wrong.
  if [ -f "$DOCKER_RAW" ]; then
    # GNU form first, BSD second, on one line each. test_static.sh enforces
    # that order: `stat -f` alone is macOS-only, and a script that works here
    # and dies on the Ubuntu box is the two-machines problem (ADR-0008) shipped
    # inside a monitoring script -- which would take the disk alert down on the
    # one host where nobody is watching the terminal.
    local apparent blocks allocated
    apparent="$(stat -c %s "$DOCKER_RAW" 2>/dev/null || stat -f %z "$DOCKER_RAW" 2>/dev/null)"
    blocks="$(stat -c %b "$DOCKER_RAW" 2>/dev/null || stat -f %b "$DOCKER_RAW" 2>/dev/null)"
    allocated="$(( blocks * 512 ))"
    echo "# HELP host_docker_disk_apparent_bytes Virtual size of Docker's disk image (NOT space consumed)."
    echo "# TYPE host_docker_disk_apparent_bytes gauge"
    echo "host_docker_disk_apparent_bytes $apparent"
    echo "# HELP host_docker_disk_allocated_bytes Blocks Docker's sparse disk image actually occupies."
    echo "# TYPE host_docker_disk_allocated_bytes gauge"
    echo "host_docker_disk_allocated_bytes $allocated"
  fi

  # The guard on the guard. When the volume is genuinely full this script
  # cannot write its own output, so the LAST GOOD VALUE stays on disk and keeps
  # being scraped -- a comfortable number, frozen, at precisely the moment it
  # is wrong. `absent()` does not help: the series is still there. Only its age
  # gives it away, so the age has to be a metric.
  echo "# HELP host_disk_metrics_generated_seconds Unix time these host disk figures were taken."
  echo "# TYPE host_disk_metrics_generated_seconds gauge"
  echo "host_disk_metrics_generated_seconds $(date +%s)"
}

if [ "${1:-}" = "--stdout" ]; then
  emit
  exit $?
fi

mkdir -p "$(dirname "$OUT")" || exit 1
tmp="$OUT.tmp"
# Atomic replace: node-exporter scrapes this directory on its own schedule and
# must never read a half-written file and report a volume as zero bytes.
if emit > "$tmp"; then
  mv -f "$tmp" "$OUT"
  echo "host_disk_metrics: wrote $OUT"
else
  rm -f "$tmp"
  exit 1
fi

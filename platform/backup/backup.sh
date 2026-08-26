#!/usr/bin/env bash
# Backup mechanism for stateful platform volumes.
#
# What gets backed up, and what deliberately does not:
#
#   vault_vault-file            YES  irreplaceable -- every secret
#   vault_vault-logs            YES  the audit trail; unreconstructable
#   observability_grafana-data  YES  users, orgs, API keys, annotations
#   observability_alertmanager-data YES silences (losing them re-floods alerts)
#   observability_prometheus-data NO  24h retention, regenerable by scraping
#   observability_loki-data     NO   24h retention; see note below
#
# Prometheus and Loki are excluded on purpose rather than by omission: both
# hold at most 24h of regenerable telemetry, and backing them up would
# multiply backup size by an order of magnitude for data that is worthless
# 24 hours later. If retention is ever extended for compliance reasons, that
# decision must revisit this list -- noted in README.md.
#
# THE CRITICAL PROPERTY, stated because it is easy to get wrong:
# Vault's file storage is encrypted at rest. This backup is therefore safe
# to hold, but it is ALSO USELESS ON ITS OWN -- restoring it requires the
# unseal keys from platform/vault/.init-output.json, which this script
# deliberately does NOT include. Backing up data and backing up the ability
# to read it are two different things, and putting both in one archive would
# turn a safe backup into a single file that hands over every secret.
#
# Usage:
#   backup.sh [dest_dir]        # default: platform/backup/archives/
#
# Verify a backup is restorable: platform/backup/restore_drill.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# --check-only runs the COVERAGE GATE and nothing else: no archives, no
# pg_dump, no PVC pods. The gate is the part that answers "is anything
# unprotected", and it is worth being able to ask that in seconds -- before a
# migration, in a test, or after adding a service -- rather than only as a side
# effect of a two-minute backup nobody wants to wait for.
CHECK_ONLY=0
if [ "${1:-}" = "--check-only" ]; then CHECK_ONLY=1; shift; fi
DEST="${1:-$SCRIPT_DIR/archives}"

VOLUMES=(
  vault_vault-file
  # The audit trail. Added when the audit device was enabled: an access log
  # that cannot survive a disk failure is not an audit capability, and it is
  # the one record here that cannot be reconstructed from anything else --
  # git can be re-cloned, evidence re-generated, but nobody can re-derive
  # who read a secret last Tuesday.
  vault_vault-logs
  observability_grafana-data
  observability_alertmanager-data
  # Alloy's log read positions. Small, and easy to dismiss as regenerable --
  # but losing them does not fail, it makes Alloy either re-read files from
  # the start (duplicate log lines) or resume at the tail (a silent hole in
  # the record). After a restore, a gap in logs looks exactly like a period
  # when nothing happened. Surfaced by the coverage check below, not by
  # anybody remembering it existed.
  observability_alloy-data
)

# Volumes that must NOT be tarred while their service is running.
#
#   container|database|user|volume
#
# Tarring a live PostgreSQL data directory is not a backup. The files are
# mutating while tar walks them, so the archive is a mix of pages from
# different instants -- torn in a way that produces no error at backup time
# and may fail, or silently restore a corrupt database, months later when it
# is finally needed. Postgres has a supported answer (`pg_dump`), so it gets
# used instead of hoping the tar lands between writes.
#
# When the container is NOT running, tar is correct and is what happens:
# nothing is writing, so the on-disk state is consistent by definition.
PG_SERVICES=(
  "station2-twin-db-1|twin|twin|station2-twin-db"
)

# Named volumes that are deliberately not backed up. Listed explicitly so the
# coverage check below can tell "decided against" apart from "never noticed".
declare -a EXCLUDED_VOLUMES=(
  observability_prometheus-data
  observability_loki-data
  # Not this platform's. Belongs to another project on the same host; backing
  # up someone else's database without being asked would be both a surprise
  # and a data-handling decision that is not ours to make. Listed rather than
  # ignored so the next person sees it was considered.
  mongo
  # RE-ADDED 2026-08-25, on the terms the 2026-08-19 removal set: the cluster was
  # rebuilt (platform/k8s/create_cluster.sh) and this is the name the volume
  # actually has now, verified against `docker volume ls`, not assumed from the
  # old entry. It is k3s's containerd image cache -- every byte of it is a layer
  # that create_cluster.sh pulls or that platform/k8s/*/build.sh rebuilds, so
  # backing it up would archive gigabytes of reproducible content and, worse,
  # restore a stale image set over a rebuilt cluster.
  #
  # This exclusion is why the 2026-08-24 19:30 backup went ok -> failed: the
  # rebuild introduced a volume nothing classified, and the job refused to claim
  # the platform was backed up. That refusal was correct. Recorded here because
  # the failure looked like a backup bug and was actually the gate working.
  k3d-devops-lab-images
)

# ---------------------------------------------------------------------------
# KUBERNETES PVCs
#
# The k3d cluster is where the stateful layer is heading, and the coverage gate
# has to understand PVCs BEFORE anything moves. Otherwise the first service to
# move is protected by nothing and the backup still says PASS -- which is not a
# hypothetical: local-path writes PVC data into the node's
# /var/lib/rancher/k3s/storage, and that path sits on an ANONYMOUS docker
# volume, which the gate below classifies as "docker's own scratch".
#
# Same three-way rule as volumes: every PVC on the cluster must be backed up,
# logically dumped, or excluded with a reason. Nothing may be merely absent.
#
#   namespace|pvc
PVC_BACKUP=()

# Databases in the cluster. Tarring a live data directory is not a backup for
# the same reason it is not one in Compose, so these get a logical dump.
#   namespace|pvc|pod-label-selector|database|user
PVC_PG=()

# Deliberately not backed up, with the reason.
#   namespace|pvc|reason
PVC_EXCLUDED=()

# Where the last successful enumeration is recorded. Without this, a cluster
# that is simply switched off is indistinguishable from a cluster with no PVCs
# -- and the second reading lets a backup pass while real data sits unreachable.
PVC_STATE_FILE="$REPO_ROOT/evidence/backup/last_known_pvcs.txt"

STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
OUT_DIR="$DEST/$STAMP"
mkdir -p "$OUT_DIR"

echo "=== [backup] $STAMP -> $OUT_DIR ==="

manifest_entries=()
UNCOVERED=()

for volume in "${VOLUMES[@]}"; do
  [ "$CHECK_ONLY" -eq 1 ] && break
  if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    echo "  SKIP $volume (does not exist)" >&2
    continue
  fi

  archive="$OUT_DIR/${volume}.tar.gz"

  # Read-only mount of the source volume: a backup process must not be able
  # to modify what it is backing up.
  docker run --rm \
    -v "${volume}:/src:ro" \
    -v "$OUT_DIR:/out" \
    alpine:3.20 \
    tar czf "/out/${volume}.tar.gz" -C /src . 2>/dev/null

  size="$(wc -c < "$archive" | tr -d ' ')"
  digest="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
  echo "  $volume -> $(basename "$archive")  ${size} bytes"
  manifest_entries+=("$volume|$(basename "$archive")|$size|$digest")
done

# --- PostgreSQL: logical dump while running, tar while stopped -----------

for spec in "${PG_SERVICES[@]}"; do
  [ "$CHECK_ONLY" -eq 1 ] && break
  IFS='|' read -r container db user volume <<< "$spec"
  docker volume inspect "$volume" >/dev/null 2>&1 || { echo "  SKIP $volume (does not exist)" >&2; continue; }

  RUNNING="$(docker ps --format '{{.Names}}' 2>/dev/null)"
  case "$RUNNING" in
    *"$container"*)
      archive="$OUT_DIR/${volume}.dump"
      # -Fc: custom format. Compressed, and restorable selectively with
      # pg_restore rather than being a plain SQL stream that can only be
      # replayed whole.
      if docker exec "$container" pg_dump -U "$user" -d "$db" -Fc > "$archive" 2>/dev/null; then
        size="$(wc -c < "$archive" | tr -d ' ')"
        digest="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
        echo "  $volume -> $(basename "$archive")  ${size} bytes  [pg_dump, consistent snapshot]"
        manifest_entries+=("$volume|$(basename "$archive")|$size|$digest")
      else
        echo "  FAILED $volume: pg_dump did not succeed" >&2
        rm -f "$archive"
        UNCOVERED+=("$volume (pg_dump failed)")
      fi
      ;;
    *)
      # Stopped: the data directory is quiescent, so a tar IS consistent.
      archive="$OUT_DIR/${volume}.tar.gz"
      docker run --rm -v "${volume}:/src:ro" -v "$OUT_DIR:/out" alpine:3.20 \
        tar czf "/out/${volume}.tar.gz" -C /src . 2>/dev/null
      size="$(wc -c < "$archive" | tr -d ' ')"
      digest="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
      echo "  $volume -> $(basename "$archive")  ${size} bytes  [tar, container stopped]"
      manifest_entries+=("$volume|$(basename "$archive")|$size|$digest")
      ;;
  esac
done

# --- Kubernetes PVCs ------------------------------------------------------
#
# K8S_STATE is the honest three-way answer to "did we check the cluster":
#   enumerated  the cluster answered; PVC_SEEN is complete
#   empty       the cluster answered and holds no PVCs
#   unreachable we could not ask -- which is NOT the same as "nothing there"
K8S_STATE="unreachable"
PVC_SEEN=()

if command -v kubectl >/dev/null 2>&1 \
   && kubectl --context "${K8S_CTX:-k3d-devops-lab}" get --raw /readyz >/dev/null 2>&1; then
  while IFS= read -r line; do
    [ -n "$line" ] && PVC_SEEN+=("$line")
  done < <(kubectl --context "${K8S_CTX:-k3d-devops-lab}" get pvc -A \
             -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  K8S_STATE="enumerated"
  [ "${#PVC_SEEN[@]}" -eq 0 ] && K8S_STATE="empty"

  mkdir -p "$(dirname "$PVC_STATE_FILE")"
  # Truncate, then append. `printf '%s\n' "${arr[@]}"` on an EMPTY array still
  # writes one newline, and `[ -s file ]` reads that 1-byte file as non-empty --
  # so a cluster with no PVCs at all was recorded as having one, and taking the
  # cluster offline then blocked the backup with "1 PVC(s) were present at the
  # last check". A false alarm that fires whenever the laptop's cluster is off
  # is a false alarm nobody will keep reacting to.
  : > "$PVC_STATE_FILE"
  for entry in "${PVC_SEEN[@]+"${PVC_SEEN[@]}"}"; do
    printf '%s\n' "$entry" >> "$PVC_STATE_FILE"
  done

  for spec in "${PVC_BACKUP[@]+"${PVC_BACKUP[@]}"}"; do
    [ "$CHECK_ONLY" -eq 1 ] && break
    IFS='|' read -r ns pvc <<< "$spec"
    archive="$OUT_DIR/pvc_${ns}_${pvc}.tar.gz"
    if size="$("$SCRIPT_DIR/pvc_archive.sh" "$ns" "$pvc" "$archive" 2>&1 | tail -1)" \
       && [ "${size//[^0-9]/}" = "$size" ] && [ -n "$size" ]; then
      digest="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
      echo "  pvc $ns/$pvc -> $(basename "$archive")  ${size} bytes  [tar from a pinned node]"
      manifest_entries+=("pvc:$ns/$pvc|$(basename "$archive")|$size|$digest")
    else
      echo "  FAILED pvc $ns/$pvc: $size" >&2
      rm -f "$archive"
      UNCOVERED+=("pvc $ns/$pvc (archive failed)")
    fi
  done

  for spec in "${PVC_PG[@]+"${PVC_PG[@]}"}"; do
    [ "$CHECK_ONLY" -eq 1 ] && break
    IFS='|' read -r ns pvc selector db user <<< "$spec"
    archive="$OUT_DIR/pvc_${ns}_${pvc}.dump"
    pod="$(kubectl --context "${K8S_CTX:-k3d-devops-lab}" -n "$ns" get pod -l "$selector" \
             -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    if [ -n "$pod" ] && kubectl --context "${K8S_CTX:-k3d-devops-lab}" -n "$ns" exec "$pod" -- \
         pg_dump -U "$user" -d "$db" -Fc > "$archive" 2>/dev/null; then
      size="$(wc -c < "$archive" | tr -d ' ')"
      digest="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
      echo "  pvc $ns/$pvc -> $(basename "$archive")  ${size} bytes  [pg_dump, consistent snapshot]"
      manifest_entries+=("pvc:$ns/$pvc|$(basename "$archive")|$size|$digest")
    else
      echo "  FAILED pvc $ns/$pvc: no pod matching '$selector', or pg_dump failed" >&2
      rm -f "$archive"
      UNCOVERED+=("pvc $ns/$pvc (pg_dump failed)")
    fi
  done

  # Coverage, same three-way rule as volumes.
  for entry in "${PVC_SEEN[@]+"${PVC_SEEN[@]}"}"; do
    covered=0
    for v in "${PVC_BACKUP[@]+"${PVC_BACKUP[@]}"}"  ; do [ "$v" = "$entry" ] && covered=1; done
    for v in "${PVC_PG[@]+"${PVC_PG[@]}"}"          ; do [ "${v%%|*}|$(echo "$v" | cut -d'|' -f2)" = "$entry" ] && covered=1; done
    for v in "${PVC_EXCLUDED[@]+"${PVC_EXCLUDED[@]}"}"; do [ "${v%%|*}|$(echo "$v" | cut -d'|' -f2)" = "$entry" ] && covered=1; done
    [ "$covered" -eq 0 ] && UNCOVERED+=("pvc $entry (in the cluster, in no list)")
  done
else
  # The cluster did not answer. If it has EVER held a PVC, this run cannot
  # claim the platform is backed up: the data is still on disk, we simply
  # cannot see it. Passing here is how "the cluster was off" becomes "the
  # database was never backed up" six months later.
  if [ -s "$PVC_STATE_FILE" ]; then
    echo "  Kubernetes is unreachable, and $(wc -l < "$PVC_STATE_FILE" | tr -d ' ') PVC(s) were present at the last check." >&2
    UNCOVERED+=("kubernetes unreachable with known PVCs (see $PVC_STATE_FILE)")
  else
    # Last seen holding nothing, so the node volumes hold no PVC data and can
    # be excused. The assumption is stated rather than made silently: a PVC
    # created since the last successful run would not be caught here. The gate
    # that catches THAT is the next successful run, which is why this prints
    # every time instead of staying quiet.
    K8S_STATE="unreachable-known-empty"
    echo "  Kubernetes unreachable; the last successful check found no PVC, so no"
    echo "  PVC data is assumed to be at risk. A PVC created since then would not"
    echo "  be seen until the cluster answers again."
  fi
fi

# ORDER MATTERS: the PVC section must run BEFORE the manifest is written.
# The first version put it after, so pvc_*.tar.gz landed in the archive
# directory and never appeared in manifest.json -- an archive with no digest
# recorded, which the restore drill therefore never checks and a restore never
# knows about. Caught by the drill reporting "no PVC archive in this backup"
# while the file was sitting right there.
# The manifest is what makes a restore verifiable rather than hopeful: the
# digest recorded at backup time is compared at restore time, so silent
# corruption between the two is detected instead of being restored.
if [ "$CHECK_ONLY" -eq 0 ]; then
python3 - "$OUT_DIR/manifest.json" "$STAMP" "${manifest_entries[@]}" <<'PY'
import json, pathlib, sys
out, stamp, *entries = sys.argv[1:]
volumes = []
for entry in entries:
    name, archive, size, digest = entry.split("|")
    volumes.append({
        "volume": name,
        "archive": archive,
        "size_bytes": int(size),
        "sha256": digest,
    })
pathlib.Path(out).write_text(json.dumps({
    "created_at": stamp,
    "volumes": volumes,
    "excluded": {
        "observability_prometheus-data": "24h retention, regenerable by scraping",
        "observability_loki-data": "24h retention, regenerable telemetry",
    },
    "restore_requires": (
        "platform/vault/.init-output.json (unseal keys). Vault file storage "
        "is encrypted at rest; this archive cannot be opened without them, "
        "and they are deliberately not included here."
    ),
}, indent=2) + "\n")
PY
fi

# --- coverage: is anything stateful NOT accounted for? -------------------
#
# The volume list is hand-maintained, which means a new stateful service is
# protected only if somebody remembered to add it here. Nothing announced the
# omission -- the backup kept passing, and its manifest kept looking complete,
# because a list cannot report what is not in it.
#
# Found exactly that way: station2-twin brought the platform's first real
# database and its volume was covered by nothing. The backup did not fail; it
# succeeded at backing up the wrong set.
#
# So every named volume on this host must be in exactly one of three places:
# backed up, listed as PG (dumped), or explicitly excluded. Anything else is
# an unreviewed gap and makes this run non-zero.
ALL_VOLUMES="$(docker volume ls --format '{{.Name}}' 2>/dev/null)"

# Volumes mounted by k3d node containers. Read from docker rather than
# hardcoded: the names are anonymous hashes that change on every cluster
# rebuild, so a list would be stale the first time create_cluster.sh runs.
K3D_UNEXCUSED=0
K3D_VOLUMES="$(
  for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^k3d-' || true); do
    docker inspect "$c" \
      --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null
  done | sort -u
)"
for vol in $ALL_VOLUMES; do
  covered=0
  for v in "${VOLUMES[@]}"        ; do [ "$v" = "$vol" ] && covered=1; done
  for v in "${EXCLUDED_VOLUMES[@]}"; do [ "$v" = "$vol" ] && covered=1; done
  for spec in "${PG_SERVICES[@]}" ; do [ "${spec##*|}" = "$vol" ] && covered=1; done
  # Anonymous volumes are docker's own scratch (64-hex names), not state
  # anybody chose to keep -- UNLESS a k3d node mounts one, in which case it
  # holds /var/lib/rancher/k3s and therefore every PVC's data.
  #
  # That exception is the entire reason this rewrite happened. Without it,
  # moving postgres into the cluster puts 6.5M rows inside a volume this line
  # classifies as disposable, and the run still prints BACKUP PASS.
  #
  # A k3d node volume is excluded only when the PVC enumeration ACTUALLY RAN.
  # The exclusion's justification is "the data inside is covered per-PVC
  # above", so if we could not enumerate PVCs, the justification does not hold
  # and the volume is not excused.
  case "$vol" in
    [0-9a-f]*)
      if [ "${#vol}" -ge 64 ]; then
        if printf '%s\n' "$K3D_VOLUMES" | grep -qx "$vol"; then
          case "$K8S_STATE" in
            enumerated|empty|unreachable-known-empty) covered=1 ;;
            # Counted once, not thirteen times. These names are anonymous
            # hashes that change on every cluster rebuild, so listing them
            # tells a reader nothing they can act on -- and thirteen unusable
            # lines bury the one line that says what to do.
            *) covered=1; K3D_UNEXCUSED=$((K3D_UNEXCUSED + 1)) ;;
          esac
        else
          covered=1
        fi
      fi
      ;;
  esac
  [ "$covered" -eq 0 ] && UNCOVERED+=("$vol")
done

if [ "$K3D_UNEXCUSED" -gt 0 ]; then
  UNCOVERED+=("$K3D_UNEXCUSED k3d node volume(s) hold /var/lib/rancher/k3s (every PVC's data) and cannot be excused while Kubernetes is unreachable -- start the cluster, or accept that PVC data went unbacked")
fi

echo ""
if [ "${#UNCOVERED[@]}" -gt 0 ]; then
  echo "BACKUP INCOMPLETE -- ${#UNCOVERED[@]} volume(s) are covered by nothing:" >&2
  for v in "${UNCOVERED[@]}"; do echo "    $v" >&2; done
  echo "" >&2
  echo "The archives that WERE taken are valid and written to:" >&2
  echo "  $OUT_DIR" >&2
  echo "" >&2
  echo "But this run cannot claim the platform is backed up. In" >&2
  echo "platform/backup/backup.sh, put each item in exactly one list:" >&2
  echo "  docker volume -> VOLUMES / PG_SERVICES / EXCLUDED_VOLUMES" >&2
  echo "  pvc           -> PVC_BACKUP / PVC_PG / PVC_EXCLUDED" >&2
  echo "An exclusion needs a reason. 'We decided against it' and 'nobody" >&2
  echo "noticed it' must not look the same to the next reader." >&2
  exit 1
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  rmdir "$OUT_DIR" 2>/dev/null || true
  echo "COVERAGE PASS -- every volume and PVC is in exactly one list (nothing archived)"
  exit 0
fi

echo "BACKUP PASS -- every named volume on this host is accounted for"
echo "artifact=$OUT_DIR/manifest.json"
echo ""
echo "A backup that has never been restored is not a backup."
echo "Verify it: platform/backup/restore_drill.sh $OUT_DIR"

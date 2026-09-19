#!/usr/bin/env bash
# Resolve the pilot's database container by COMPOSE SERVICE, never by name.
#
# WHY THIS EXISTS (2026-09-20).
#
# Twenty-two places in this repo ran `docker exec station2-twin-db-1`. That
# string is not an identity: Compose builds it as <project>-<service>-<n>, and
# the project defaults to the directory the compose file sits in. So renaming a
# directory renamed every container, and twenty-two call sites broke with
# "No such container" -- an error that names the symptom and not the cause.
#
# The first response was to pin `name: station2-twin` in compose.yaml so the
# old container names survived the rename. That is the wrong fix, and it was
# rejected: it keeps a derived string as the interface and freezes a name to
# protect callers that should never have depended on it. The next person who
# renames anything meets the same wall, plus a pin nobody can explain.
#
# WHAT IS ACTUALLY STABLE. The compose FILE and the SERVICE name inside it --
# `db` -- are declared, not derived. This script resolves them to whatever
# container is currently serving, so the project name is free to follow the
# directory, which is what Compose does by default and what everyone expects.
#
# Usage:
#   pilot_db.sh container            # the running container id (empty if none)
#   pilot_db.sh name                 # its name, for messages and for docker cp
#   pilot_db.sh exec <cmd> [args…]   # run a command inside it
#   pilot_db.sh psql [psql args…]    # psql as the pilot user, -qtAX by default
#
# Env:
#   PILOT_COMPOSE  compose file to resolve against
#                  (default: pilots/station2-publichealth/compose.yaml)
#   PILOT_DB_SERVICE  service name inside it (default: db)
#   PGUSER / PGDATABASE  passed to psql (default: twin / twin)
#
# Exit codes:
#   0  resolved (and the command ran)
#   3  the database container is not running -- distinct from a psql failure,
#      because "the database is down" and "the query was wrong" need different
#      responses and the caller cannot tell them apart from rc=1.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
COMPOSE="${PILOT_COMPOSE:-$REPO_ROOT/pilots/station2-publichealth/compose.yaml}"
SERVICE="${PILOT_DB_SERVICE:-db}"

resolve() {  # prints the container id, empty when nothing is running
  docker compose -f "$COMPOSE" ps -q "$SERVICE" 2>/dev/null | head -1
}

case "${1:-container}" in
  container)
    CID="$(resolve)"
    [ -n "$CID" ] || { echo "no running '$SERVICE' container for $COMPOSE" >&2; exit 3; }
    printf '%s\n' "$CID"
    ;;
  name)
    CID="$(resolve)"
    [ -n "$CID" ] || { echo "no running '$SERVICE' container for $COMPOSE" >&2; exit 3; }
    docker inspect --format '{{.Name}}' "$CID" 2>/dev/null | sed 's|^/||'
    ;;
  exec)
    shift
    CID="$(resolve)"
    [ -n "$CID" ] || { echo "no running '$SERVICE' container for $COMPOSE" >&2; exit 3; }
    exec docker exec "$CID" "$@"
    ;;
  psql)
    shift
    CID="$(resolve)"
    [ -n "$CID" ] || { echo "no running '$SERVICE' container for $COMPOSE" >&2; exit 3; }
    exec docker exec "$CID" psql -U "${PGUSER:-twin}" -d "${PGDATABASE:-twin}" \
      -qtAX "$@"
    ;;
  *)
    echo "Usage: $0 {container|name|exec <cmd…>|psql [args…]}" >&2
    exit 2
    ;;
esac

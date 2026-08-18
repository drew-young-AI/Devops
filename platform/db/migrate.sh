#!/usr/bin/env bash
# Apply database migrations, in order, once, and refuse the dangerous ones.
#
# A migration runner is easy. The three things that actually cause outages are
# what this refuses to do.
#
# 1. RE-APPLYING A CHANGED MIGRATION.
#    Someone edits 002_foo.sql after it has already run somewhere. On a fresh
#    database the new text applies; on the existing one it never re-runs. The
#    two databases now differ, permanently, with no error anywhere. Every
#    applied migration is checksummed, and a checksum mismatch is a hard stop.
#
# 2. DESTRUCTIVE CHANGES DURING BLUE/GREEN.
#    Blue and green share one database. `ALTER TABLE ... DROP COLUMN` applied
#    while the old colour is still serving breaks the colour you were keeping
#    as your rollback path -- so the deploy is now irreversible at exactly the
#    moment you most need to reverse it. Destructive statements are refused
#    unless the file opts in with a CONTRACT-PHASE marker, which is a claim
#    that no live colour depends on the old shape.
#
# 3. PARTIAL APPLICATION.
#    A file with three statements where the second fails leaves the schema in
#    a state no migration describes. Each file runs inside ONE transaction, so
#    it applies completely or not at all.
#
# Usage:
#   platform/db/migrate.sh <pilot>            apply pending migrations
#   platform/db/migrate.sh <pilot> --status   what is applied vs pending
#   platform/db/migrate.sh <pilot> --dry-run  plan only, touch nothing
#
# Exit 0 applied or already current, 1 refused or failed, 2 usage.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PILOT="${1:-}"
MODE="${2:-apply}"
[ -n "$PILOT" ] || { echo "Usage: $0 <pilot> [--status|--dry-run]" >&2; exit 2; }

case "$MODE" in
  apply|--status|--dry-run) ;;
  *) echo "Unknown mode: $MODE" >&2; exit 2 ;;
esac

MIGRATIONS_DIR="$REPO_ROOT/pilots/$PILOT/migrations"
[ -d "$MIGRATIONS_DIR" ] || { echo "No migrations at $MIGRATIONS_DIR" >&2; exit 1; }

# Connection comes from the environment so the same runner works against a
# throwaway container in CI and a real database in production, and so that a
# credential is never written into this file or its arguments.
PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-15432}"
PGDATABASE="${PGDATABASE:-twin}"
PGUSER="${PGUSER:-twin}"
PGPASSWORD="${PGPASSWORD:-}"
PSQL_IMAGE="${PSQL_IMAGE:-postgres:16-alpine}"

# psql runs in a container: no local postgresql-client dependency, and the
# version is pinned rather than "whatever brew installed".
psql_q() {
  docker run --rm -i \
    -e PGPASSWORD="$PGPASSWORD" \
    --network "${DB_NETWORK:-host}" \
    "$PSQL_IMAGE" \
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" \
      -v ON_ERROR_STOP=1 -qtAX "$@"
}

if ! psql_q -c 'SELECT 1' >/dev/null 2>&1; then
  echo "Cannot reach postgres at $PGHOST:$PGPORT/$PGDATABASE as $PGUSER." >&2
  echo "Is the pilot's database running?  docker compose -f pilots/$PILOT/compose.yaml up -d db" >&2
  exit 1
fi

# The ledger. Checksums live here, which is what makes rule 1 enforceable.
psql_q -c "
CREATE TABLE IF NOT EXISTS schema_migrations (
    version     INTEGER     PRIMARY KEY,
    name        TEXT        NOT NULL,
    checksum    TEXT        NOT NULL,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);" >/dev/null || { echo "Could not create schema_migrations." >&2; exit 1; }

# Destructive DDL. Matched on the statement, not merely the keyword, so that a
# column called 'dropped_at' or a comment mentioning DROP does not trip it.
DESTRUCTIVE_RE='(DROP[[:space:]]+(TABLE|COLUMN|CONSTRAINT|INDEX|SCHEMA|DATABASE|TYPE)|TRUNCATE[[:space:]]|ALTER[[:space:]]+TABLE[[:space:]]+[a-zA-Z_.\"]+[[:space:]]+(RENAME|ALTER[[:space:]]+COLUMN[[:space:]]+[a-zA-Z_\"]+[[:space:]]+TYPE)|SET[[:space:]]+NOT[[:space:]]+NULL)'
CONTRACT_MARKER='CONTRACT-PHASE'

echo "=== migrations for $PILOT ($PGHOST:$PGPORT/$PGDATABASE) ==="

applied_count=0
pending=()

for file in $(find "$MIGRATIONS_DIR" -maxdepth 1 -name '[0-9]*.sql' | sort); do
  base="$(basename "$file")"
  version="$(echo "$base" | sed -E 's/^0*([0-9]+)_.*/\1/')"
  if ! [[ "$version" =~ ^[0-9]+$ ]]; then
    echo "REFUSED: $base does not start with a numeric version." >&2
    exit 1
  fi
  checksum="$(shasum -a 256 "$file" | awk '{print $1}')"

  recorded="$(psql_q -c "SELECT checksum FROM schema_migrations WHERE version = $version" | tr -d '[:space:]')"

  if [ -n "$recorded" ]; then
    if [ "$recorded" != "$checksum" ]; then
      cat >&2 <<EOF
REFUSED: $base was modified after it was applied.

  recorded  $recorded
  on disk   $checksum

An already-applied migration will never re-run, so this file's current
contents have NOT been applied to this database -- while a database created
from scratch today WOULD get them. The two schemas have silently diverged.

Do not "fix" this by editing the checksum. Write a NEW migration that makes
the change, and restore this file to what was actually applied.
EOF
      exit 1
    fi
    echo "  applied   $base (v$version)"
    applied_count=$((applied_count + 1))
    continue
  fi

  # Pending. Check it before offering to run it.
  body="$(grep -vE '^\s*--' "$file")"
  if echo "$body" | grep -qiE "$DESTRUCTIVE_RE"; then
    if ! grep -q "$CONTRACT_MARKER" "$file"; then
      offending="$(echo "$body" | grep -inE "$DESTRUCTIVE_RE" | head -3)"
      cat >&2 <<EOF

REFUSED: $base contains a destructive change and is not marked as a
contract phase.

$offending

Blue and green share this database. A destructive change applied while the
previous colour is still serving breaks the rollback target -- the deploy
becomes irreversible exactly when reversing it is the thing you need.

The expand/contract split:
  EXPAND    add nullable columns, add tables, add indexes. Old code keeps
            working. Safe to apply before a deploy.
  CONTRACT  drop, rename, retype, add NOT NULL. Only safe once NO live
            colour depends on the old shape.

If this really is a contract phase and the old colour is gone, say so in
the file:

  -- CONTRACT-PHASE: <why no live colour depends on the old shape>

EOF
      exit 1
    fi
    echo "  pending   $base (v$version)  [CONTRACT PHASE -- destructive, explicitly allowed]"
  else
    echo "  pending   $base (v$version)"
  fi
  pending+=("$file|$version|$base|$checksum")
done

if [ "$MODE" = "--status" ] || [ "$MODE" = "--dry-run" ]; then
  echo ""
  echo "  $applied_count applied, ${#pending[@]} pending"
  [ "$MODE" = "--dry-run" ] && echo "  (dry run -- nothing was applied)"
  exit 0
fi

if [ "${#pending[@]}" -eq 0 ]; then
  echo ""
  echo "Already current: $applied_count migration(s) applied, 0 pending."
  exit 0
fi

echo ""
echo "=== applying ${#pending[@]} migration(s) ==="

for entry in "${pending[@]}"; do
  IFS='|' read -r file version base checksum <<< "$entry"

  # ONE transaction per file: the migration body and its ledger row commit
  # together, so a crash between them cannot leave a migration applied but
  # unrecorded (which would make it run again on the next deploy).
  if ! {
        echo "BEGIN;"
        cat "$file"
        echo ""
        echo "INSERT INTO schema_migrations (version, name, checksum) VALUES ($version, '$base', '$checksum');"
        echo "COMMIT;"
      } | psql_q >/dev/null; then
    echo "  FAILED    $base -- rolled back, nothing applied from this file" >&2
    echo "" >&2
    echo "The schema is exactly as it was before this file started." >&2
    exit 1
  fi
  echo "  applied   $base (v$version)"
done

FINAL="$(psql_q -c 'SELECT COALESCE(MAX(version), 0) FROM schema_migrations' | tr -d '[:space:]')"
echo ""
echo "MIGRATION PASS -- schema now at version $FINAL"
echo ""
echo "The service refuses readiness unless its EXPECTED_SCHEMA_VERSION matches"
echo "this number, so a code/schema mismatch shows up as a deploy that never"
echo "takes traffic rather than as errors under load."

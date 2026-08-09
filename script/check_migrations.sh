#!/usr/bin/env bash
# Fail the build/deploy if ActiveRecord migrations contain duplicate version numbers.
#
# Rails raises ActiveRecord::DuplicateMigrationVersionError when two migration
# files share the same 14-digit version prefix, which aborts `bin/rails db:prepare`.
# If that surfaces during a production deploy it causes downtime, because the bad
# commit has already been pushed to `prod` by the time the server runs migrations.
#
# This check is purely file-based (no database connection) so it works in the
# Release workflow and CI — which have no DB available — and fails fast *before*
# the version bump / push to prod.
#
# Usage: script/check_migrations.sh [migrate_dir]   (default: db/migrate)
set -euo pipefail

migrate_dir="${1:-db/migrate}"

if [ ! -d "$migrate_dir" ]; then
  echo "check_migrations: directory not found: $migrate_dir" >&2
  exit 1
fi

# Leading 14-digit version prefix of every migration, sorted. basename(1) is used
# (not find -printf) so this works on both macOS (BSD find) and Linux (GNU find).
versions=$(find "$migrate_dir" -maxdepth 1 -type f -name '*.rb' -exec basename {} \; \
           | grep -Eo '^[0-9]{14}' | sort || true)

count=$(printf '%s\n' "$versions" | grep -c . || true)
if [ "$count" -eq 0 ]; then
  echo "check_migrations: no migrations in $migrate_dir (nothing to check)"
  exit 0
fi

dupes=$(printf '%s\n' "$versions" | uniq -d)
if [ -n "$dupes" ]; then
  echo "================================================================" >&2
  echo "ERROR: duplicate ActiveRecord migration version numbers detected:" >&2
  printf '  - %s\n' $dupes >&2
  echo >&2
  echo "Two migration files share the same 14-digit timestamp prefix, which" >&2
  echo "raises ActiveRecord::DuplicateMigrationVersionError during db:prepare" >&2
  echo "and will abort the production deploy. Rename one of the conflicting" >&2
  echo "files to a unique version prefix." >&2
  echo "================================================================" >&2
  exit 1
fi

echo "check_migrations: OK ($count migrations, no duplicate versions)"

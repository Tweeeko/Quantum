#!/usr/bin/env bash
# Apply all migrations to a fresh database on plain PostgreSQL (with the
# Supabase shim) and run the database test suite.
# Env: PGHOST, PGPORT, PGUSER (superuser). Usage: tests/db/run.sh
set -euo pipefail
cd "$(dirname "$0")"
DB="quantum_test_$$"
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -d "$DB")
createdb "$DB"
trap 'dropdb --if-exists "$DB" >/dev/null 2>&1 || true' EXIT
"${PSQL[@]}" -f supabase_shim.sql >/dev/null
for m in ../../supabase/migrations/*.sql; do
  echo "migrate: $(basename "$m")"
  "${PSQL[@]}" -f "$m" >/dev/null
done
"${PSQL[@]}" -f assertions.sql >/dev/null
"${PSQL[@]}" -f test_core.sql 2>&1 | sed 's/^psql:[^ ]* NOTICE:  /  /;s/^NOTICE:  /  /'

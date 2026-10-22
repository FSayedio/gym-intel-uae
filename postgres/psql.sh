#!/bin/sh
# Run inside the PostgreSQL container; never print the secret.
set -eu
PGPASSWORD="$(cat "${POSTGRES_PASSWORD_FILE:?POSTGRES_PASSWORD_FILE is required}")"
test -n "$PGPASSWORD"
export PGPASSWORD
exec psql -X -v ON_ERROR_STOP=1 \
  --username="${POSTGRES_USER:?POSTGRES_USER is required}" \
  --dbname="${POSTGRES_DB:?POSTGRES_DB is required}" "$@"

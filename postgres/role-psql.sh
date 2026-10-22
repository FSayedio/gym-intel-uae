#!/bin/sh
# Connect as an actual role for acceptance checks; credentials stay in-container.
set -eu
database_role="${1:?database role is required}"
shift
case "$database_role" in
  gym_intel_app) secret_file=/run/secrets/postgres_app_password ;;
  gym_intel_migrator) secret_file=/run/secrets/postgres_migrator_password ;;
  gym_intel_grafana) secret_file=/run/secrets/grafana_database_password ;;
  *) printf 'Unsupported verification role\n' >&2; exit 1 ;;
esac
PGPASSWORD="$(cat "$secret_file")"
test -n "$PGPASSWORD"
export PGPASSWORD
exec psql -X -v ON_ERROR_STOP=1 --host=127.0.0.1 \
  --username="$database_role" --dbname="${POSTGRES_DB:?POSTGRES_DB is required}" "$@"

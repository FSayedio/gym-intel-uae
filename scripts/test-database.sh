#!/bin/sh
# Existing tests include DDL and database creation. Owner credentials belong
# only in this short-lived test container, hardcoded to gym_intel_test.
set -eu
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
if [ "$#" -gt 1 ]; then
  echo "Usage: sh scripts/test-database.sh [--ci]" >&2
  exit 2
fi
case "${1:-}" in
  "") check_command='mix ecto.create && mix ecto.migrate && mix test --no-start' ;;
  --ci) check_command='sh scripts/ci-checks.sh' ;;
  *) echo "Usage: sh scripts/test-database.sh [--ci]" >&2; exit 2 ;;
esac
test -s .secrets/postgres_password
docker compose run --rm --no-deps \
  -e MIX_ENV=test -e DATABASE_NAME=gym_intel_test -e RUN_DB_TESTS=true \
  -e DATABASE_USER=gym_intel \
  -e DATABASE_PASSWORD_FILE=/run/secrets/test_owner_password \
  -v "$project_dir/.secrets/postgres_password:/run/secrets/test_owner_password:ro" \
  -v "$project_dir/.formatter.exs:/app/.formatter.exs:ro" \
  -v "$project_dir/scripts:/app/scripts:ro" \
  -v "$project_dir/test:/app/test:ro" \
  -v "$project_dir/grafana:/app/grafana:ro" \
  app sh -c "$check_command"

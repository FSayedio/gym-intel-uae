#!/bin/sh
# Mount the migration secret only in a short-lived migration container.
set -eu
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
test -s .secrets/postgres_migrator_password
docker compose run --rm --no-deps \
  -e DATABASE_USER=gym_intel_migrator \
  -e DATABASE_PASSWORD_FILE=/run/secrets/postgres_migrator_password \
  -v "$project_dir/.secrets/postgres_migrator_password:/run/secrets/postgres_migrator_password:ro" \
  app mix ecto.migrate
docker compose exec -T postgres sh /opt/gym-intel/configure-roles.sh

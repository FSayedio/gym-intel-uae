#!/bin/sh
# Shared CI checks. Only the isolated test database is permitted.
set -eu

if [ "${MIX_ENV:-}" != test ] || [ "${RUN_DB_TESTS:-}" != true ] ||
  [ "${DATABASE_NAME:-}" != gym_intel_test ]; then
  echo "CI checks require MIX_ENV=test, RUN_DB_TESTS=true and DATABASE_NAME=gym_intel_test" >&2
  exit 1
fi

if [ -z "${DATABASE_PASSWORD_FILE:-}" ] || [ ! -s "$DATABASE_PASSWORD_FILE" ]; then
  echo "CI checks require a nonempty test-only DATABASE_PASSWORD_FILE" >&2
  exit 1
fi

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

echo "Checking locked dependencies"
mix deps.get --check-locked
echo "Checking Elixir formatting"
mix format --check-formatted
echo "Compiling test application with warnings as errors"
mix compile --warnings-as-errors
echo "Creating and migrating the isolated test database"
mix ecto.create
mix ecto.migrate
echo "Running all tests, including PostgreSQL and dashboard SQL tests"
mix test --no-start

#!/bin/sh
# Validate rendered config only; never start/recreate any service.
set -eu
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
check_image="${CHECK_IMAGE:-gym-intel-checks:local}"

check_ports() {
  POSTGRES_HOST_PORT="$1" GRAFANA_HOST_PORT="$2" docker compose config --format json |
    docker run --rm -i --platform linux/arm64 \
      -e "EXPECTED_POSTGRES_HOST_PORT=$1" -e "EXPECTED_GRAFANA_HOST_PORT=$2" \
      "$check_image" elixir -pa '/app/_build/test/lib/*/ebin' scripts/check-compose.exs
}

echo 'Checking default published ports'
check_ports 5432 3000
echo 'Checking alternate published ports without changing container endpoints'
check_ports 15432 13000

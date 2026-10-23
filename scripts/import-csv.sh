#!/bin/sh
# Submit an immutable CSV snapshot using the runtime credential, never migrator.
set -eu
if [ "$#" -ne 1 ]; then
  echo 'Usage: sh scripts/import-csv.sh data/file.csv' >&2
  exit 2
fi
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
case "$1" in
  data/*) container_path="/app/$1" ;;
  *) echo 'CSV must be under the read-only data/ mount' >&2; exit 2 ;;
esac
case "$1" in
  *'/../'*|*'/..'|*'/./'*|*'/.'|*'//'*)
    echo 'Use a direct data/ path without traversal components' >&2; exit 2 ;;
esac
test -f "$1" || { echo 'CSV file does not exist' >&2; exit 1; }
docker compose run --rm --no-deps -e "IMPORT_CSV_PATH=$container_path" \
  app bin/gym_intel eval 'GymIntel.Release.enqueue()'

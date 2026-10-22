#!/bin/sh
# Provision the datasource from a mounted secret without logging its contents.
set -eu
GYM_INTEL_DATABASE_PASSWORD="$(cat /run/secrets/grafana_database_password)"
test -n "$GYM_INTEL_DATABASE_PASSWORD"
export GYM_INTEL_DATABASE_PASSWORD
exec /run.sh "$@"

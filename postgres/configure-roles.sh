#!/bin/sh
# Run in the PostgreSQL container after mounting the local role secrets.
set -eu
for secret_name in postgres_app_password postgres_migrator_password grafana_database_password; do
  test -s "/run/secrets/$secret_name"
done
sh /opt/gym-intel/psql.sh --file=/opt/gym-intel-priv/database_roles.sql
sh /opt/gym-intel/psql.sh --file=/opt/gym-intel-priv/grafana_reader.sql
for database_role in gym_intel_app gym_intel_migrator gym_intel_grafana; do
  case "$database_role" in
    gym_intel_app) secret_file=/run/secrets/postgres_app_password ;;
    gym_intel_migrator) secret_file=/run/secrets/postgres_migrator_password ;;
    gym_intel_grafana) secret_file=/run/secrets/grafana_database_password ;;
  esac
  { cat "$secret_file"; cat "$secret_file"; } |
    sh /opt/gym-intel/psql.sh --command="\\password $database_role"
done

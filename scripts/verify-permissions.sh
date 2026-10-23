#!/bin/sh
# Actual permission probes run inside transactions that always roll back.
set -eu
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

expect_denied() {
  role="$1"
  statement="$2"
  if output=$(docker compose exec -T postgres sh /opt/gym-intel/role-psql.sh "$role" \
    --set=VERBOSITY=verbose \
    --command="BEGIN; $statement; ROLLBACK;" 2>&1); then
    printf 'FAIL: %s unexpectedly permitted: %s\n' "$role" "$statement"
    exit 1
  else
    case "$output" in
      *'42501:'*) printf 'PASS: %s denied: %s\n' "$role" "$statement" ;;
      *) printf 'FAIL: unexpected error: %s\n' "$output"; exit 1 ;;
    esac
  fi
}

expect_denied gym_intel_app 'CREATE ROLE gym_intel_permission_probe'
expect_denied gym_intel_app 'CREATE TABLE public.gym_intel_permission_probe (id integer)'
expect_denied gym_intel_app 'DROP TABLE public.memberships'
expect_denied gym_intel_app 'DELETE FROM public.memberships WHERE false'
expect_denied gym_intel_app 'UPDATE public.memberships SET notes = notes WHERE false'
expect_denied gym_intel_app 'UPDATE public.membership_notes SET notes = notes WHERE false'
expect_denied gym_intel_app 'DELETE FROM public.membership_notes WHERE false'
expect_denied gym_intel_app "SELECT public.configure_observation_access('gym_intel_app'::name, NULL::name)"
expect_denied gym_intel_app 'UPDATE public.schema_migrations SET version = version WHERE false'
expect_denied gym_intel_app 'SET ROLE gym_intel_migrator'
expect_denied gym_intel_app 'SET ROLE gym_intel'
expect_denied gym_intel_app 'SELECT count(*) FROM pg_authid'
expect_denied gym_intel_grafana 'UPDATE public.memberships SET notes = notes WHERE false'
expect_denied gym_intel_grafana 'SELECT notes FROM public.memberships LIMIT 0'
expect_denied gym_intel_grafana 'SELECT notes FROM public.membership_notes LIMIT 0'
expect_denied gym_intel_grafana 'DELETE FROM public.dashboard_memberships WHERE false'
expect_denied gym_intel_grafana 'SELECT id FROM public.oban_jobs LIMIT 0'
expect_denied gym_intel_grafana 'SELECT content_sha256 FROM public.membership_imports LIMIT 0'
expect_denied gym_intel_grafana 'SET ROLE gym_intel_migrator'
expect_denied gym_intel_grafana 'SET ROLE gym_intel'

docker compose exec -T postgres sh /opt/gym-intel/role-psql.sh gym_intel_grafana \
  --command='SELECT count(*) AS public_observations FROM public.dashboard_memberships'
printf 'PASS: Grafana can read the public view, not raw observations/note history\n'

docker compose exec -T postgres sh /opt/gym-intel/role-psql.sh gym_intel_migrator --command='
BEGIN;
CREATE TABLE public.gym_intel_permission_probe (id integer);
ALTER TABLE public.gym_intel_permission_probe ADD COLUMN checked boolean;
DROP TABLE public.gym_intel_permission_probe;
ROLLBACK;'
printf 'PASS: migrator can change tables; probe rolled back\n'

docker compose exec -T app sh -ec '
  test ! -e /run/secrets/postgres_password
  test ! -e /run/secrets/postgres_migrator_password
  test -s /run/secrets/postgres_app_password'
printf 'PASS: running app has its own secret and no owner/migrator secret\n'

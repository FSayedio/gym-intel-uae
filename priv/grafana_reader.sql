-- Run through postgres/configure-roles.sh, before and after migrations.
-- Re-running grants is safe; no membership data is changed.
BEGIN;
DO $$
BEGIN
  IF current_database() <> 'gym_intel_dev' THEN
    RAISE EXCEPTION 'Run this setup only in gym_intel_dev';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'gym_intel_grafana') THEN
    CREATE ROLE gym_intel_grafana LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
  END IF;
END
$$;
ALTER ROLE gym_intel_grafana NOSUPERUSER NOCREATEDB NOCREATEROLE
  NOREPLICATION NOBYPASSRLS NOINHERIT;
GRANT CONNECT ON DATABASE gym_intel_dev TO gym_intel_grafana;
GRANT USAGE ON SCHEMA public TO gym_intel_grafana;
DO $$
BEGIN
  IF to_regclass('public.memberships') IS NOT NULL THEN
    GRANT SELECT ON public.memberships TO gym_intel_grafana;
  END IF;
END
$$;
COMMIT;

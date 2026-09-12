-- Run after migrations in gym_intel_dev. Local trust authentication only.
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
GRANT CONNECT ON DATABASE gym_intel_dev TO gym_intel_grafana;
GRANT USAGE ON SCHEMA public TO gym_intel_grafana;
GRANT SELECT ON public.memberships TO gym_intel_grafana;
COMMIT;

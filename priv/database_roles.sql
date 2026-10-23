-- Run only with the owner maintenance connection in gym_intel_dev.
-- Explicit grants keep the runtime role separate from schema ownership.
BEGIN;
SET LOCAL lock_timeout = '5s';
DO $$
DECLARE
  object record;
  grant_row record;
BEGIN
  IF current_database() <> 'gym_intel_dev' THEN
    RAISE EXCEPTION 'Run role setup only in gym_intel_dev';
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'gym_intel_migrator') THEN
    CREATE ROLE gym_intel_migrator LOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'gym_intel_app') THEN
    CREATE ROLE gym_intel_app LOGIN;
  END IF;
  ALTER ROLE gym_intel_migrator NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOREPLICATION NOBYPASSRLS NOINHERIT;
  ALTER ROLE gym_intel_app NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOREPLICATION NOBYPASSRLS NOINHERIT;

  ALTER DATABASE gym_intel_dev OWNER TO gym_intel_migrator;
  ALTER SCHEMA public OWNER TO gym_intel_migrator;
  REVOKE ALL ON DATABASE gym_intel_dev FROM PUBLIC;
  REVOKE CREATE ON SCHEMA public FROM PUBLIC;
  GRANT CONNECT ON DATABASE gym_intel_dev TO gym_intel_app;
  GRANT USAGE ON SCHEMA public TO gym_intel_app;

  -- Transfer only objects in this database's public schema, not shared objects
  -- or objects in other databases (unlike a blanket REASSIGN OWNED).
  FOR object IN
    SELECT c.relname FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
      AND c.relowner = (SELECT oid FROM pg_roles WHERE rolname = 'gym_intel')
  LOOP
    EXECUTE format('ALTER TABLE public.%I OWNER TO gym_intel_migrator', object.relname);
  END LOOP;
  FOR object IN
    SELECT t.typname FROM pg_type t
    JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typtype IN ('e', 'd')
      AND t.typowner = (SELECT oid FROM pg_roles WHERE rolname = 'gym_intel')
  LOOP
    EXECUTE format('ALTER TYPE public.%I OWNER TO gym_intel_migrator', object.typname);
  END LOOP;

  -- Keep the old image usable before the integrity migration. Afterward the
  -- shared permission function grants append-only observation/evidence access.
  FOR grant_row IN
    SELECT * FROM (VALUES
      ('memberships', CASE WHEN to_regclass('public.memberships_observation_key_index') IS NULL
        THEN 'SELECT, INSERT, UPDATE' ELSE 'SELECT, INSERT' END),
      ('membership_imports', 'SELECT, INSERT'),
      ('oban_jobs', 'SELECT, INSERT, UPDATE, DELETE'),
      ('oban_peers', 'SELECT, INSERT, UPDATE, DELETE'),
      ('schema_migrations', 'SELECT')
    ) AS grants(table_name, privileges)
  LOOP
    IF to_regclass(format('public.%I', grant_row.table_name)) IS NOT NULL THEN
      EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC', grant_row.table_name);
      EXECUTE format('REVOKE ALL ON TABLE public.%I FROM gym_intel_app', grant_row.table_name);
      EXECUTE format('GRANT %s ON TABLE public.%I TO gym_intel_app',
        grant_row.privileges, grant_row.table_name);
    END IF;
  END LOOP;
  FOR object IN
    SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'S'
      AND c.relname IN ('memberships_id_seq', 'oban_jobs_id_seq')
  LOOP
    EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE public.%I TO gym_intel_app', object.relname);
  END LOOP;
  IF to_regprocedure('public.configure_observation_access(name,name)') IS NOT NULL THEN
    PERFORM public.configure_observation_access('gym_intel_app'::name, NULL::name);
  END IF;
END
$$;
COMMIT;

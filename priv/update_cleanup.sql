-- Owner-invoked, session-local, transactional cleanup AFTER verified backup.
-- This does not grant DELETE/UPDATE on observations to the runtime or reader.
CREATE OR REPLACE FUNCTION pg_temp.cleanup_dashboard_update(
  expected_state text, expected_job bigint, expected_csv text
) RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog AS $$
DECLARE
  removed_notes bigint;
  removed_observations bigint;
  removed_jobs bigint;
BEGIN
  -- Bound contention; roll back everything if another writer intervenes.
  PERFORM set_config('lock_timeout', '5s', true);
  LOCK TABLE public.oban_jobs, public.membership_imports,
    public.memberships, public.membership_notes IN SHARE ROW EXCLUSIVE MODE;
  IF EXISTS (SELECT FROM public.oban_jobs
             WHERE state IN ('available', 'scheduled', 'executing', 'retryable')) THEN
    RAISE EXCEPTION 'Unfinished jobs exist; cleanup refused';
  END IF;
  IF expected_state IS NULL OR expected_state !~ '^[0-9a-f]{64}$'
     OR pg_temp.dashboard_update_state() <> expected_state THEN
    RAISE EXCEPTION 'Database changed since backup preparation; cleanup refused';
  END IF;
  IF NOT EXISTS (
    SELECT FROM public.oban_jobs j JOIN public.membership_imports i
      ON i.content_sha256 = expected_csv
    WHERE j.id = expected_job AND j.queue = 'imports' AND j.state = 'completed'
      AND j.worker = 'GymIntel.Workers.ImportMemberships'
      AND encode(sha256(convert_to(j.args->>'csv', 'UTF8')), 'hex') = expected_csv
  ) THEN
    RAISE EXCEPTION 'Missing matching completed job and import evidence';
  END IF;

  -- Keep EVERY observation on the newest date per offer, including conflicts
  -- and unknown prices. Never pick a cheaper row or revive an older price.
  DELETE FROM public.membership_notes n USING public.memberships old
  WHERE n.membership_id = old.id AND EXISTS (
    SELECT FROM public.memberships newer
    WHERE newer.brand_name = old.brand_name
      AND newer.branch_name IS NOT DISTINCT FROM old.branch_name
      AND newer.plan_name = old.plan_name AND newer.observed_on > old.observed_on
  );
  GET DIAGNOSTICS removed_notes = ROW_COUNT;
  DELETE FROM public.memberships old WHERE EXISTS (
    SELECT FROM public.memberships newer
    WHERE newer.brand_name = old.brand_name
      AND newer.branch_name IS NOT DISTINCT FROM old.branch_name
      AND newer.plan_name = old.plan_name AND newer.observed_on > old.observed_on
  );
  GET DIAGNOSTICS removed_observations = ROW_COUNT;

  -- Only terminal import jobs; two most recently FINISHED, not scheduled.
  -- Retryable is not terminal. Other queues and workers are never swept.
  DELETE FROM public.oban_jobs old
  WHERE old.queue = 'imports' AND old.worker = 'GymIntel.Workers.ImportMemberships'
    AND old.state IN ('completed', 'cancelled', 'discarded') AND old.id NOT IN (
      SELECT id FROM public.oban_jobs
      WHERE queue = 'imports' AND worker = 'GymIntel.Workers.ImportMemberships'
        AND state IN ('completed', 'cancelled', 'discarded')
      ORDER BY COALESCE(completed_at, cancelled_at, discarded_at, inserted_at) DESC, id DESC
      LIMIT 2
    );
  GET DIAGNOSTICS removed_jobs = ROW_COUNT;

  RETURN jsonb_build_object('superseded_observations_removed', removed_observations,
    'associated_notes_removed', removed_notes, 'finished_import_jobs_removed', removed_jobs);
END
$$;

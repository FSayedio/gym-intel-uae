-- Session-local helpers only: never install a privileged function or new grant.
-- Fingerprint protected state without printing CSV arguments or source notes.
CREATE OR REPLACE FUNCTION pg_temp.dashboard_update_state() RETURNS text
LANGUAGE sql SET search_path = pg_catalog SET TimeZone = 'UTC' AS $$
  -- Use the SAME complete-row hashing/order as recovery/snapshot.sql, allowing
  -- the guard to be tied to an existing v1 backup without changing its format.
  SELECT encode(sha256(convert_to(concat_ws(':',
    (SELECT encode(sha256(convert_to(COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), '[]'::jsonb)::text, 'UTF8')), 'hex') FROM public.memberships t),
    (SELECT encode(sha256(convert_to(COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), '[]'::jsonb)::text, 'UTF8')), 'hex') FROM public.membership_notes t),
    (SELECT encode(sha256(convert_to(COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), '[]'::jsonb)::text, 'UTF8')), 'hex') FROM public.membership_imports t),
    (SELECT encode(sha256(convert_to(COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), '[]'::jsonb)::text, 'UTF8')), 'hex') FROM public.oban_jobs t)
  ), 'UTF8')), 'hex')
$$;

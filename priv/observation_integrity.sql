-- Applied transactionally by the Ecto migration. The separators also let the
-- upgrade tests exercise this exact DDL in a disposable test schema.
CREATE FUNCTION public.membership_observation_key_v1(
  brand_name text, branch_name text, plan_name text, access_scope text,
  offer_type text, advertised_price_aed numeric, billing_period_months integer,
  minimum_commitment_months integer, joining_fee_aed numeric, source_url text,
  source_published_on date, observed_on date, payment_structure text,
  renewal_policy text, price_vat_status text, admin_fee_aed numeric
) RETURNS bytea
LANGUAGE sql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog
AS $$
  -- Only fixed types are serialized. Numeric scale is removed only in the key;
  -- original values are not rewritten. Epoch days avoid DateStyle/TimeZone.
  -- The array preserves field boundaries and distinguishes NULL from text/0.
  SELECT sha256(convert_to(jsonb_build_array(
    'membership-observation-v1'::text,
    brand_name, branch_name, plan_name, access_scope, offer_type,
    trim_scale(advertised_price_aed)::text, billing_period_months,
    minimum_commitment_months, trim_scale(joining_fee_aed)::text, source_url,
    source_published_on - DATE '2000-01-01', observed_on - DATE '2000-01-01',
    payment_structure, renewal_policy, price_vat_status,
    trim_scale(admin_fee_aed)::text
  )::text, 'UTF8'))
$$;

-- statement
CREATE FUNCTION public.membership_note_key_v1(note_text text) RETURNS bytea
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
SET search_path = pg_catalog
AS $$ SELECT sha256(convert_to(note_text, 'UTF8')) $$;

-- statement
ALTER TABLE public.memberships
  ADD COLUMN observation_key bytea GENERATED ALWAYS AS (
    public.membership_observation_key_v1(
      brand_name, branch_name, plan_name, access_scope, offer_type,
      advertised_price_aed, billing_period_months, minimum_commitment_months,
      joining_fee_aed, source_url, source_published_on, observed_on,
      payment_structure, renewal_policy, price_vat_status, admin_fee_aed
    )
  ) STORED NOT NULL,
  ADD COLUMN first_import_sha256 varchar(255)
    REFERENCES public.membership_imports(content_sha256) ON DELETE RESTRICT;

-- statement
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.memberships GROUP BY observation_key HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION USING ERRCODE = '23505',
      MESSAGE = 'Observation identity conflicts exist; migration stopped without deleting or consolidating records';
  END IF;
END
$$;

-- statement
CREATE UNIQUE INDEX memberships_observation_key_index
  ON public.memberships(observation_key);

-- statement
CREATE TABLE public.membership_notes (
  id bigserial PRIMARY KEY,
  membership_id bigint NOT NULL REFERENCES public.memberships(id) ON DELETE RESTRICT,
  notes text NOT NULL,
  note_key bytea GENERATED ALWAYS AS (public.membership_note_key_v1(notes)) STORED NOT NULL,
  recorded_at timestamp(6) without time zone NOT NULL,
  source_import_sha256 varchar(255)
    REFERENCES public.membership_imports(content_sha256) ON DELETE RESTRICT,
  CONSTRAINT membership_notes_identity UNIQUE (membership_id, note_key)
);

-- statement
CREATE INDEX membership_notes_source_import_index
  ON public.membership_notes(source_import_sha256);

-- statement
-- Original IDs, source fields, notes and timestamps remain untouched. We know
-- when the row was inserted, but cannot infer its original file fingerprint.
INSERT INTO public.membership_notes(membership_id, notes, recorded_at, source_import_sha256)
SELECT id, notes, inserted_at, NULL FROM public.memberships WHERE notes IS NOT NULL;

-- statement
CREATE FUNCTION public.capture_initial_membership_note() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  IF NEW.notes IS NOT NULL THEN
    INSERT INTO public.membership_notes(membership_id, notes, recorded_at, source_import_sha256)
    VALUES (NEW.id, NEW.notes, NEW.inserted_at, NEW.first_import_sha256);
  END IF;
  RETURN NEW;
END
$$;

-- statement
CREATE TRIGGER memberships_capture_initial_note
AFTER INSERT ON public.memberships
FOR EACH ROW EXECUTE FUNCTION public.capture_initial_membership_note();

-- statement
-- Deliberately omit notes, history, IDs, keys and import metadata. The view
-- owner's base-table access permits reader SELECT without exposing base rows.
CREATE VIEW public.dashboard_memberships AS
SELECT brand_name, branch_name, plan_name, access_scope, offer_type,
  advertised_price_aed, billing_period_months, minimum_commitment_months,
  joining_fee_aed, source_url, source_published_on, observed_on,
  payment_structure, renewal_policy, price_vat_status, admin_fee_aed
FROM public.memberships;

-- statement
-- One owner-invoked permission definition is reused by role setup and tests.
-- It is SECURITY INVOKER, never an escalation function for runtime callers.
CREATE FUNCTION public.configure_observation_access(runtime_role name, reader_role name)
RETURNS void LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
BEGIN
  IF runtime_role IS NOT NULL THEN
    EXECUTE format('GRANT USAGE ON SCHEMA public TO %I', runtime_role);
    EXECUTE format('REVOKE ALL ON public.memberships, public.membership_notes, public.membership_imports FROM %I', runtime_role);
    EXECUTE format('GRANT SELECT, INSERT ON public.memberships, public.membership_notes, public.membership_imports TO %I', runtime_role);
    EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE public.memberships_id_seq, public.membership_notes_id_seq TO %I', runtime_role);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.membership_observation_key_v1(text,text,text,text,text,numeric,integer,integer,numeric,text,date,date,text,text,text,numeric), public.membership_note_key_v1(text), public.capture_initial_membership_note() TO %I', runtime_role);
  END IF;
  IF reader_role IS NOT NULL THEN
    EXECUTE format('GRANT USAGE ON SCHEMA public TO %I', reader_role);
    EXECUTE format('REVOKE ALL ON public.memberships, public.membership_notes, public.membership_imports, public.dashboard_memberships FROM %I', reader_role);
    EXECUTE format('GRANT SELECT ON public.dashboard_memberships TO %I', reader_role);
  END IF;
END
$$;

-- statement
REVOKE ALL ON public.membership_notes, public.dashboard_memberships FROM PUBLIC;

-- statement
REVOKE ALL ON FUNCTION
  public.membership_observation_key_v1(text,text,text,text,text,numeric,integer,integer,numeric,text,date,date,text,text,text,numeric),
  public.membership_note_key_v1(text), public.capture_initial_membership_note(),
  public.configure_observation_access(name,name) FROM PUBLIC;

-- statement
-- Transition grant only: the old dashboard can keep reading memberships while
-- its query file is replaced. Role setup then revokes its base-table access.
DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'gym_intel_grafana') THEN
    GRANT SELECT ON public.dashboard_memberships TO gym_intel_grafana;
  END IF;
END
$$;

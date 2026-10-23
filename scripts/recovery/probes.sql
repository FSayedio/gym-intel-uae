-- All writes are to the isolated restored copy and roll back. Sequence advances
-- are intentionally confined to that throwaway instance, after baseline compare.
\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE
  probe_id bigint;
  probe_brand text := 'RECOVERY TEST ONLY ' || txid_current()::text;
BEGIN
  INSERT INTO public.memberships (
    brand_name, branch_name, plan_name, access_scope, offer_type,
    advertised_price_aed, billing_period_months, minimum_commitment_months,
    joining_fee_aed, source_url, observed_on, notes, inserted_at, updated_at
  ) VALUES (
    probe_brand, 'TEST BRANCH', 'TEST PLAN', 'single_branch', 'standard',
    199, 1, 0, 0, 'https://example.com/recovery-test', DATE '2000-01-01',
    'SYNTHETIC RESTORE CHECK ONLY', now(), now()
  ) RETURNING id INTO probe_id;
  IF (SELECT count(*) FROM public.membership_notes
      WHERE membership_id = probe_id AND notes = 'SYNTHETIC RESTORE CHECK ONLY') <> 1 THEN
    RAISE EXCEPTION 'Initial-note trigger did not survive restoration';
  END IF;
  BEGIN
    INSERT INTO public.memberships (
      brand_name, branch_name, plan_name, access_scope, offer_type,
      advertised_price_aed, billing_period_months, minimum_commitment_months,
      joining_fee_aed, source_url, observed_on, notes, inserted_at, updated_at
    ) VALUES (
      probe_brand, 'TEST BRANCH', 'TEST PLAN', 'single_branch', 'standard',
      199.00, 1, 0, 0, 'https://example.com/recovery-test', DATE '2000-01-01',
      'A DIFFERENT NOTE IS NOT A NEW OBSERVATION', now(), now()
    );
    RAISE EXCEPTION 'Observation uniqueness did not survive restoration';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
END $$;
ROLLBACK;

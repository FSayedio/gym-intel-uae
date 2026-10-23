-- Synthetic evidence only; this runs in the throwaway fixture database.
\set ON_ERROR_STOP on
INSERT INTO public.membership_imports(content_sha256, row_count, inserted_at)
VALUES (repeat('a', 64), 1, timestamp '2000-01-01');
INSERT INTO public.memberships (
  brand_name, branch_name, plan_name, access_scope, offer_type,
  advertised_price_aed, billing_period_months, minimum_commitment_months,
  joining_fee_aed, source_url, observed_on, notes, inserted_at, updated_at,
  first_import_sha256
) VALUES (
  'TEST ONLY BACKUP', 'TEST BRANCH', 'TEST PLAN', 'single_branch', 'standard',
  199, 1, 0, 0, 'https://example.com/backup-fixture', DATE '2000-01-01',
  'SYNTHETIC FIXTURE ONLY', timestamp '2000-01-01', timestamp '2000-01-01', repeat('a', 64)
);
INSERT INTO public.oban_jobs(state, queue, worker, args, attempt, max_attempts,
  attempted_at, completed_at)
VALUES ('completed', 'imports', 'TEST ONLY BACKUP',
  '{"csv":"SYNTHETIC FIXTURE CONTENT ONLY"}', 1, 3, now(), now());

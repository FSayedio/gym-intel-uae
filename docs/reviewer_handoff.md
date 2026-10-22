# Pricing MVP — reviewer handoff

Prepared 12 September 2026. This is a local, learning-first prototype, not a
production deployment or a comprehensive UAE gym ranking.

## Before, action, after

- **Before:** manually sourced CSV observations; no end-to-end display.
- **Action:** validate CSV records, queue an immutable CSV snapshot with Oban,
  save observations transactionally in PostgreSQL, and query them from Grafana.
- **After:** three Dubai branch offers appear in an advertised monthly-charge
  chart with a branch/plan/terms/source table. There is no scheduled fetching.
- **Evidence:** on 12 September, all three services were running, PostgreSQL was
  healthy, both dashboard SQL queries returned three rows through the reader
  account, and the full separate-database test suite reported **40 passed**.
  The learner confirmed the revised chart looked clean. No CI is configured.

## Review version and delivery status

Review branch `codex/grafana-memberships`, based on `ec9743a` (merged CSV
importer). The dashboard delivery commit includes provisioning, reader setup,
local development instructions, and this handoff. Identify the exact reviewed
revision with `git rev-parse HEAD` and include it in the review report.
Local commit, publishing the branch, and merging into main are separate steps;
this document does not claim publication or a merge. A reviewer must receive
this branch/revision, not assume GitHub main contains the dashboard.

## Run and reproduce

Use [Local development](local_development.md) for exact commands. In order:

1. Generate local secrets, build the app, start PostgreSQL, configure roles,
   and run `sh scripts/migrate.sh`, then start the full three-service stack.
2. Role setup grants the dedicated Grafana login SELECT on memberships.
   Run `sh scripts/verify-permissions.sh` for the role-isolation checks.
3. Queue `data/memberships.csv` using the documented enqueue command. Inspect
   Oban job state until completed; enqueue success alone is not import success.
4. Open <http://127.0.0.1:3000/d/gym-intel-offers> on the machine running Docker.
5. Run the full test command using **gym_intel_test**, not the development DB.

Expected initial observations: GymNation Downtown Dubai Core **209**, PureGym
Dubai Al Barsha CORE **199**, and The Warehouse Gym IBN Battuta Mall Light
Monthly **363**, in AED per month, observed 12 September 2026. Unknown fees and
commitments are not zero. These are recorded observations, not freshly rechecked
prices. Re-importing the identical file should not add more memberships.

The localhost URL is not a remotely shareable hosted dashboard. Reviewers need
repository access and their own running stack, or a screen-sharing session.
Do not delete existing Docker volumes to test fresh setup; use a separate,
isolated environment. Fresh-machine reproduction has not yet been verified.

## Code reading map

| Area | Files |
| --- | --- |
| Data meaning and provenance | `docs/data_contract.md`, `data/memberships.csv` |
| Validation and CSV decoding | `lib/gym_intel/membership.ex`, `membership_csv.ex` |
| Atomic import and deduplication | `lib/gym_intel/membership_importer.ex` |
| Queue and CSV snapshot | `lib/gym_intel/workers/import_memberships.ex` |
| Startup and database | `config/`, `lib/gym_intel/application.ex`, `repo.ex`, `priv/repo/migrations/` |
| Runtime packaging | `Dockerfile`, `compose.yaml`, `mix.exs`, `mix.lock` |
| Display and reader permissions | `grafana/`, `priv/grafana_reader.sql` |
| Repeatable checks | `test/`, commands in `docs/local_development.md` |

Paths abbreviated in the table share their row's stated directory.

## Highest-priority review questions

- Are the source observations faithfully transcribed and scoped to the named
  branches/plans? Confirm unresolved commitment, joining fee, tax, and offer terms.
- Do validation and migration constraints agree, including unknown versus zero?
- Are malformed files rejected without partial writes? Check atomicity, retries,
  identical-file detection, and equality across all 17 fields for row duplicates.
  The extensions accept the exact legacy 13- and 15-column snapshot
  formats as well as the current 17-column header; old missing classifications
  stay unknown. New classifications are nullable, allowlisted independently in
  Elixir and PostgreSQL, and matched by the filtered dashboard SQL. Review both
  legacy queued-job compatibility and differing/unknown/conflicting term cases.
- Are changed observations retained correctly? Notes/source changes are distinct
  observations, not semantic duplicates under the current rule.
- Does the dashboard avoid misleading comparisons? The chart selects the newest
  date with known monthly single-branch prices for every explicitly selected
  branch/plan, preserving the prior complete set during partial refreshes.
  The evidence history includes all dates, native payment periods and unknown
  prices. Original plan names remain traceability, not invented equivalent
  tiers. A separate chart requires matching access, known commitment, payment
  structure, renewal policy and membership-price VAT basis for at
  least two distinct brands on the overview date; it explicitly reports when
  evidence is insufficient. Fees, tax rates, cancellation notice and benefits may still differ.
- Can a reviewer reproduce setup, import, reader grants, and display independently?

## Limitations and remaining work

- Advertised charges are **not** equivalent benefits, total contract costs, or
  a cheapest-gym ranking. Branch and plan details remain essential evidence.
- Three Dubai branches are not UAE-wide coverage. Attendance, equipment,
  facilities, opening hours, and branch-footprint dashboards are not implemented.
- Grafana anonymous access is Viewer, with a local secret for administrator
  login. PostgreSQL requires SCRAM passwords for socket and network connections;
  Grafana receives a separate reader password. The running app uses a limited
  runtime account; migration credentials are mounted only for explicit tasks.
  The bootstrap owner remains a superuser in the PostgreSQL container; anyone
  controlling Docker or its private secret can administer the database.
  Keep this deployment local.
- CSV snapshots persist in job arguments; no periodic job pruning is configured.
  File size is limited to 1 MB and queue concurrency is one per app instance.
- Migration rollback, backup/restore, clean-machine setup, concurrent multi-app
  load, and automated browser-level visual regression remain unverified.
- Full tests passed with an upstream Mix xref deprecation warning; compilation
  succeeded. No claim of CI, load testing, or production readiness is made.
- The 22 October 2026 security-containment rebuild reported a Hex advisory for
  Decimal 3.1.1 (EEF-CVE-2026-97853). The build succeeded; advisory assessment
  and dependency remediation remain pending as separate follow-up work.

## Dashboard-correctness revision — 22 October 2026

- **Before:** global latest-date filtering could erase monthly comparisons,
  unknown-price records were hidden, and branded plan names did not explain
  equivalent or different terms.
- **Action:** retain the last complete selected monthly-price set, display all
  recorded evidence with normalized condition labels, and add a known-commitment
  filter plus an explicit two-distinct-brand gate. Keep original plan names;
  do not infer equivalent tiers from them.
- **After:** the historical overview remains available, while the filtered
  charge comparison is empty when its criteria are not supported. It is a
  comparison on access/billing/commitment only, not equivalent benefits or total
  costs. Current stored observations support no qualifying two-brand group.
- **Evidence:** the separate-database suite reports **71 passed**, including
  actual provisioned SQL for price-date preservation, readable conditions,
  unknowns, conflicting terms, commitment selection and comparison availability.
  Synthetic tests do not certify real offer terms. Runtime queries through the
  actual Grafana reader returned all four panel responses successfully: three
  overview prices, three history rows, an empty filtered result and its explicit
  availability message. Browser inspection confirmed readable original/normalized
  terms, the two commitment options, zero matches for No minimum commitment and
  one for 3 months, both without filtered bars. This was a manual visual check,
  not an automated visual-regression suite. Development data stayed at three
  observations with checksum `6137f9dbf625f612f60bc8c735a641e9`.

The read-only official-source audit is recorded in `docs/data_contract.md`.
It found different commitments, additional GymNation admin fees and unresolved
Warehouse access wording. Those findings have not been imported or backdated;
the development data remains three 12 September observations. At that checkpoint,
structured admin fees, tax treatment and broader benefit normalization remained
future work; the later revisions below describe the implemented extensions.
This section describes local work, not a commit, push, PR or merge confirmation.

### Feature 2 — consolidated scope and completion gates

Feature 2 is **dashboard correctness and evidence-based comparability**. Its
purpose is to help users compare documented gym offers without presenting
different or unsupported terms as equivalent. A correct empty state is a safety
result, not proof that a useful real-data comparison has been delivered.

- **Before:** the three historical prices could imply equivalent memberships;
  exact public prices from additional operators could be mistaken for approved
  comparable offers.
- **Action:** preserve complete historical price sets, retain original plan
  names, label documented conditions, enforce known matching terms, extend the
  source contract without guessing historical values, and audit the identified
  public-source pool against those rules.
- **After:** the overview and evidence history remain inspectable; the filtered
  chart refuses unsupported groups. The audit distinguishes published-price
  evidence, individually classifiable offers and approved multi-operator groups.
- **Evidence:** the last full separate-database suite reported **103 passed**
  at the VAT/admin-fee checkpoint below. The [13-operator source audit](data_contract.md#bounded-pool-audit-and-final-count--22-october-2026)
  records **10 operators with exact public price evidence, 3 without an applicable
  verified price on the checked routes, and 0 approved multi-operator strict
  cohorts**. GymNation and PureGym are clear classification candidates, but
  minimum terms of 12 and 0 months place them in different groups. These counts
  are a manual research tally, not imported records or new live SQL results.

#### Progress and remaining work

The checklist separates implementation evidence from delivery and data readiness.
Checked technical items were verified at the checkpoints documented below. The
initial checklist-only update did not rerun tests; the subsequent technical
review checkpoint records a fresh run. Neither step imported new offers.

- [x] Preserve the last complete selected monthly-price date during partial or
  incompatible refreshes; disclose that the overview is historical.
- [x] Keep original marketing names while displaying shared condition labels
  and all recorded source/terms evidence.
- [x] Require known matching access, monthly billing, minimum commitment,
  payment structure, renewal policy and membership-price VAT basis, with at least
  two distinct operators and explicit insufficient-evidence behavior.
- [x] Support the nullable payment/renewal and VAT/admin extensions through
  validation, additive migrations, legacy CSV/job compatibility and deduplication.
- [x] Verify the implemented behavior with the separate-database suite and
  recorded runtime, reader-permission and manual browser checks.
- [x] Complete the bounded 13-operator public-source eligibility audit and
  record exclusion reasons, conflicts and unverified fields.
- [ ] Establish a real comparison-ready group: at least two distinct operators
  with sufficiently verified evidence satisfying the same approved comparison
  rules. Collect fresh observations in a common cycle, import deliberately,
  update the explicit selected offer set and regression fixtures, then verify
  the displayed result against those sources. This gate is **not met**.
- [ ] Complete final review and delivery: review the full diff, rerun appropriate
  checks after any further code/data edits, then learner-controlled staging,
  local commit, push, PR/review/merge and local-main update. These remain distinct
  steps; no delivery operation is authorized by this checklist.

Feature 2 milestones: **6 of 8 complete**. This is a checklist count, not an
estimate of effort, remaining time or overall project completion. Technical work
is available for review locally; **the real-data comparison gate remains unmet**,
and this branch has not been committed, pushed or merged.

#### Constraints carried forward from the audit

- Do not promise ten comparable gyms: ten is a public-price research count.
  The dashboard still displays the original three historical operators; no audit
  findings were imported or backdated.
- An optional minimum-term threshold, such as at most one month, remains a
  proposal, not implemented behavior. Keeping all other current gates, the audit
  still approves no multi-operator group under that proposal. Broadening duration
  does not resolve ambiguous scope, VAT or renewal evidence.
- Do not quietly loosen matching rules, treat unknown fees as zero, infer
  equivalence from branded names, or treat equal billing periods as equal
  contracts. Comparison on these fields still does not establish equal benefits,
  cancellation terms or all-in costs.
- Continue with public sources only. Stop at personal-details, enquiry,
  consent or purchase boundaries; do not use outreach to obtain missing prices.
- If public evidence cannot support the comparison-ready group, report that
  limitation and obtain an explicit product-scope decision before changing the
  completion claim or the dashboard's question. Shipping the technical safeguards
  with this limitation is not the same as delivering a verified comparison.

## Payment and renewal revision — 22 October 2026

- **Before:** billing duration alone could not distinguish a purchased prepaid
  month from a monthly recurring subscription, and renewal lived only in notes.
- **Action:** add independent nullable `payment_structure` and `renewal_policy`
  fields, allowlists in Elixir/PostgreSQL, backward-compatible CSV reading,
  evidence columns and known-value Grafana selectors. No classifications were
  inferred from prices, plan names or billing periods.
- **After:** strict chart groups must match both new known classifications as
  well as access, billing and commitment. Unknown/conflicting evidence is
  excluded, not guessed. Original 13-column snapshots still execute, while new
  CSVs can use the exact 15-column header. Row deduplication compares all 15
  source fields; new evidence is retained without overwriting historical rows.
- **Evidence:** the separate test-database suite reports **89 passed**, including legacy jobs,
  new classifications, database allowlists, deduplication, independent filters,
  unknown/conflicting evidence and SQL quoting. The additive migration ran on
  development; all three original observations retained their existing values
  and have NULL in both new fields. A canonical checksum excluding the added
  fields was `3266eb3b07735aabef6841a96f496f5f` both before and after. Live browser
  inspection confirmed both selectors, both Unknown evidence columns and zero
  qualifying offers under recurring/automatic and prepaid/non-automatic choices.
  Grafana's memberships data source reported `Database Connection OK` and exactly
  three services remained running, with PostgreSQL healthy.

These changes remain local and unstaged on `codex/dashboard-correctness`.
The existing CSV is unchanged; no new source observations have been imported.
Tax, admin fees, cancellation notice and product/access benefits are not newly
normalized by these two fields. Broader source eligibility and chart selection
remain deliberate next steps, not automatic consequences of this migration.

## VAT and admin-fee revision — 22 October 2026

- **Before:** the contract could not distinguish a VAT-included quoted membership
  price from a VAT-excluded one, and separate onboarding admin charges lived only
  in notes. A missing joining/admin fee could be mistaken for free entry.
- **Action:** add independent nullable `price_vat_status` and `admin_fee_aed`
  fields, Elixir/PostgreSQL allowlists and nonnegative fee checks, backward-compatible
  13/15/17-column CSV reading, separate evidence columns and a VAT-basis selector.
  The flag covers the membership price only, not the tax treatment of other fees.
- **After:** filtered monthly groups require the same known VAT basis; unknown
  or conflicting evidence is excluded. The chart title shows the selected VAT
  basis. Excluded-VAT amounts stay pre-VAT, with no guessed rate or conversion.
  Joining/admin charges stay separate and are not added to the bars. No all-in,
  first-payment or complete mandatory-fee calculation is claimed.
- **Evidence:** **103 tests passed** in `gym_intel_test`, including legacy queued
  snapshots, VAT/admin validation and database constraints, 17-field deduplication,
  equal numbers with different VAT bases, unknown/conflicting tax evidence and
  safe SQL-string interpolation. All five development migration versions are
  present. The existing three observations retain their original values; the
  canonical checksum excluding the four added fields is unchanged at
  `3266eb3b07735aabef6841a96f496f5f`. New VAT/admin fields remain NULL for all
  three historical records. Browser inspection confirmed both VAT choices, the
  interpolated VAT-excluded title, Unknown VAT/admin evidence and zero qualifying
  offers. Grafana's memberships connection returned `Database Connection OK`;
  three services are running and PostgreSQL is healthy. Formatting and Git
  whitespace checks passed; the source CSV is unchanged. The role-permission
  regression script also passed: runtime DDL/deletes/role escalation and reader
  writes/job access remain denied; the migrator probe rolled back and privileged
  secrets remain absent from the running app.

The runtime-account `mix ecto.migrations` listing was denied because Ecto attempts
schema DDL. This was not fixed by expanding privileges: the documented verification
now uses read-only SELECT on `schema_migrations`. Actual migrations continue to
use the dedicated migrator task. No database was dropped or recreated.

These local changes are still unstaged on `codex/dashboard-correctness`, with no
commit, push, PR or merge for this branch. No new source observations were imported.
Other mandatory charges, per-fee tax treatment, notice rules and benefit/access
normalization remain separate work. Public-source candidates are not automatically
approved or selected for the dashboard by adding these fields.

## Feature 2 technical review checkpoint — 22 October 2026

- **Before:** the implementation and bounded source audit were recorded locally,
  but review needed current execution evidence rather than relying only on earlier
  passing results.
- **Action:** inspect the pending implementation, both new migrations and their
  tests; rebuild the app image; run the complete isolated-database suite; check
  changed-file formatting and role permissions; query Grafana's health endpoints
  and execute all four loaded dashboard SQL targets through its memberships data
  source. Do not import research findings or loosen matching rules.
- **After:** the implementation is technically verified for review. The
  insufficient-data result remains intentional and the real comparison-ready
  group is still unestablished. Feature 2 remains **6 of 8 milestones**, not complete.
- **Evidence:**
  - `docker compose build app` succeeded, reusing the cached compile layer that
    runs `mix compile --warnings-as-errors`.
  - `sh scripts/test-database.sh` reported **103 passed**, seed `342739`, using
    `gym_intel_test`. Its test helper refuses any other database. Upstream Mix
    xref deprecation warnings appeared during dependency compilation; tests
    still passed. This is not a new dependency-advisory assessment.
  - `mix format --check-formatted` passed for every changed/new Elixir source,
    migration and test file. A broader check including historical migrations
    **failed** on the unchanged `20260912000100_create_memberships.exs`. That
    pre-existing file was left untouched; repository-wide formatting is not
    claimed to pass.
  - `sh scripts/verify-permissions.sh` passed all runtime/reader denial checks,
    the migrator's rolled-back probe and privileged-secret absence checks.
  - Grafana `/api/health` returned `database: ok`. The memberships data-source
    health endpoint separately returned `Database Connection OK`.
  - Executing the four loaded provisioned targets via Grafana `/api/ds/query`
    returned successful responses: overview **3** rows (209/199/363, all observed
    `2026-09-12`), evidence **3** rows, filtered chart **0** rows, and status
    **Not enough comparable offers — 0 gyms match; at least 2 required**. This
    exercised the default single-branch/zero-minimum/recurring/automatic/
    VAT-included selection. Other combinations are covered by the isolated SQL
    regression tests, not newly claimed live source observations.
  - Development memberships remained **3** rows. A checksum of all stored
    membership columns, ordered by ID, stayed
    `d42250384f950b38075b03468fca7162` before and after verification. This is a
    different checksum definition from the earlier original-source-fields-only
    check; compare like definitions, not the two hashes to each other.
  - SHA-256 checks for the two changed application source files and two new
    migration files matched between the workspace and running app container.
  - Exactly three services remained running, PostgreSQL healthy. The source CSV
    was unchanged and `git diff --check` passed.

No fresh automated browser-level visual test, migration rollback, backup/restore,
clean-machine reproduction, load test or CI run was performed. The pre-existing
README also still describes the app as unbuilt; that introductory documentation
needs a separate accuracy cleanup and is not evidence of current runtime state.
These results do not close the public-source data gate. All Feature 2 changes
remain unstaged on `codex/dashboard-correctness`; nothing was committed, pushed,
opened as a PR or merged in this review checkpoint.

## Requested reviewer output

Return findings ranked by severity, with file/line evidence, a reproducible
example, expected versus actual behavior, and a suggested minimal correction.
Separate correctness/security blockers from optional polish. Report commands
actually run and any checks not performed. Do not merge as part of the review.

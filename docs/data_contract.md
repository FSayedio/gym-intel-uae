# Membership CSV data contract

## Purpose

`data/memberships.csv` records published UAE gym membership offers for comparison. Each row is one plan offer observed on one date, with a primary source and any supporting sources identified in notes. This CSV does not store branch footprint, opening hours, equipment, or facilities.

## Columns

| Column | Rule |
| --- | --- |
| `brand_name` | Required. Use the operator's published brand name. |
| `branch_name` | Required when `access_scope` is `single_branch`; otherwise leave blank unless the source names one applicable branch. |
| `plan_name` | Required. Use the source's published plan name. |
| `access_scope` | Required. Use `single_branch`, `multiple_named_branches`, or `all_uae_branches`. |
| `offer_type` | Use `standard` or `promotional` only when the source makes the distinction. Otherwise leave blank. |
| `advertised_price_aed` | Exact published price in AED for the identified plan and access scope. Use a number without the currency symbol or thousands separators. Never turn a starting price, range, or estimate into an exact amount. Leave blank when unpublished. |
| `billing_period_months` | Number of months covered by the advertised price: `1` monthly, `4` four-month upfront, or `12` annual. Required when a price is present. |
| `minimum_commitment_months` | Minimum contractual duration. Use `0` only when the source explicitly states there is no minimum commitment. Leave blank when unknown. |
| `joining_fee_aed` | Published joining fee in AED. Use `0` only when the source explicitly states there is no fee. Leave blank when unknown. |
| `source_url` | Required. Link to the primary official offer page. Identify any supplementary official URLs and the facts they support in notes. |
| `source_published_on` | Source publication date in `YYYY-MM-DD`, when displayed. Otherwise leave blank. |
| `observed_on` | Required. Date the source was checked, in `YYYY-MM-DD`. |
| `notes` | Optional. Record material conditions, exclusions, or ambiguities without guessing. |

## Missing information

- A blank cell means the source does not provide the value or the field does not apply.
- Numeric zero is a documented value, not a substitute for missing information.
- Do not infer a price, fee, commitment, or plan scope from another plan or branch.
- Keep a row when a source publishes a commitment but withholds the price; the missing price remains blank.

## Comparison rules

- For the first price comparison, include only exact published plan prices with verified branch/access scope and billing period. Exclude unresolved starting prices, ranges, estimates, and unclear plan associations from the import CSV until verified.
- Do not remove qualifiers such as "from" to make a price pass numeric validation. Source review is a manual prerequisite; the importer cannot recover wording omitted by the collector.
- A documented commitment-only row may still be stored with a blank price, but must not appear as a zero-price offer or in price rankings.
- Compare plans only within the same `access_scope` and disclose whether an offer is standard or promotional.
- Calculate `monthly_equivalent_price_aed` only when both `advertised_price_aed` and `billing_period_months` are present:

  `monthly_equivalent_price_aed = advertised_price_aed / billing_period_months`

- Compare observations from the same collection cycle and display `observed_on` so viewers can judge freshness.
- Do not calculate a total contract cost while any required fee or commitment value is unknown.
- Keep source wording in `notes` when a plan does not fit the controlled values cleanly.

## Validation for the first iteration

- The CSV header must match this contract exactly.
- Every row must include `brand_name`, `plan_name`, `access_scope`, `source_url`, and `observed_on`.
- A row must include at least one of `advertised_price_aed` or `minimum_commitment_months`.
- Monetary values are AED and non-negative.
- Billing periods are positive whole numbers of months; zero cannot describe a price's billing period.
- Minimum commitments are non-negative whole numbers of months; zero means the source explicitly states no minimum commitment.
- Dates use `YYYY-MM-DD`.

## Duplicate observations during import

- An identical file is skipped using its content fingerprint.
- For different files, an observation is skipped only when all 13 parsed source fields match an existing membership. This also catches repeated rows within a file.
- Parsed numeric equivalents such as `100` and `100.00` match. Unknown values remain distinct from zero.
- Different dates, prices, scope, notes, or other source fields are retained as separate observations. This is not fuzzy matching or automatic correction of older observations.
- Each import reports inserted and skipped row counts. The file-tracking row count describes input rows, including skipped duplicates.
- For the small MVP, imports serialize membership writes within a transaction while checking and inserting. This can delay other writes; it is not a high-volume design or a database-wide uniqueness rule for code that bypasses the importer.
- Existing duplicates are not deleted by this import rule.

## Official-source spot check — 12 September 2026

The initial CSV contains three manually checked offers below. They are advertised observations, not purchase quotes or verified all-in costs. All three have single-branch access and monthly billing; differing or unknown commitments, fees, tax treatment, and offer type must remain visible in any comparison. A strict comparison requiring known matching terms may exclude these rows.

- [GymNation Downtown Dubai](https://gymnation.com/en-ae/gymsnearme/downtown-dubai/) listed Core at AED 209/month with single-gym access. Its [UAE FAQ](https://gymnation.com/en-ae/gymnationfaqs/) described Core as a 12-month agreement paid monthly. Billing and commitment are distinct; confirm the supporting terms apply to the specific offer before collecting it. The branch page did not establish a joining-fee amount.
- [PureGym Al Barsha join selector](https://puregym-arabia.exerp.site/join/plan?center=8002), reached from the official branch page by selecting Dubai Al Barsha, displayed CORE at AED 199/month plus AED 89 joining fee, excluding two-gym access. This is the collected offer, not the different starting price on the landing page. General membership messaging says no commitment, but branch-specific applicability is unconfirmed, so the commitment field stays blank.
- [Warehouse join selector](https://whgym.com/join), after selecting Light, displayed a Monthly plan at AED 363/month for IBN Battuta Mall only, with a stated 3-month commitment. Its cancellation wording separately describes 2 months plus 1 month's notice; this is noted rather than interpreted. The collected amount is not the Al Quoz starting price or the rounded monthly equivalent of an annual plan. Joining fee remains unknown.

These pages were checked on the date above; their publication dates were not established. A check date is not a source publication date. Prices and terms may change.

# Membership CSV data contract

## Purpose

`data/memberships.csv` records published UAE gym membership offers for comparison. Each row is one plan offer observed from one source on one date. This CSV does not store branch footprint, opening hours, equipment, or facilities.

## Columns

| Column | Rule |
| --- | --- |
| `brand_name` | Required. Use the operator's published brand name. |
| `branch_name` | Required when `access_scope` is `single_branch`; otherwise leave blank unless the source names one applicable branch. |
| `plan_name` | Required. Use the source's published plan name. |
| `access_scope` | Required. Use `single_branch`, `multiple_named_branches`, or `all_uae_branches`. |
| `offer_type` | Use `standard` or `promotional` only when the source makes the distinction. Otherwise leave blank. |
| `advertised_price_aed` | Published price in AED. Use a number without the currency symbol or thousands separators. Leave blank when unpublished. |
| `billing_period_months` | Number of months covered by the advertised price: `1` monthly, `4` four-month upfront, or `12` annual. Required when a price is present. |
| `minimum_commitment_months` | Minimum contractual duration. Use `0` only when the source explicitly states there is no minimum commitment. Leave blank when unknown. |
| `joining_fee_aed` | Published joining fee in AED. Use `0` only when the source explicitly states there is no fee. Leave blank when unknown. |
| `source_url` | Required. Link to the exact official page supporting the row. |
| `source_published_on` | Source publication date in `YYYY-MM-DD`, when displayed. Otherwise leave blank. |
| `observed_on` | Required. Date the source was checked, in `YYYY-MM-DD`. |
| `notes` | Optional. Record material conditions, exclusions, or ambiguities without guessing. |

## Missing information

- A blank cell means the source does not provide the value or the field does not apply.
- Numeric zero is a documented value, not a substitute for missing information.
- Do not infer a price, fee, commitment, or plan scope from another plan or branch.
- Keep a row when a source publishes a commitment but withholds the price; the missing price remains blank.

## Comparison rules

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
- Month counts are non-negative whole numbers.
- Dates use `YYYY-MM-DD`.

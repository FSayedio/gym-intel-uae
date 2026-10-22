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
| `payment_structure` | `prepaid_term` for a purchased fixed access term paid upfront; `recurring` for scheduled repeated membership payments. Record only supported source wording; billing length alone establishes neither. Blank means unknown. |
| `renewal_policy` | `automatic` when the source states the membership/term renews automatically; `non_automatic` when expiry/renewal wording explicitly establishes no automatic renewal. Blank means unknown. Independent of payment structure. |
| `price_vat_status` | `included` or `excluded`, only when established for this advertised membership price. Blank means unknown; this does not establish a tax rate or the tax treatment of separate fees. |
| `admin_fee_aed` | Exact published one-time onboarding/admin charge, separate from the joining fee. Use `0` only when the source explicitly states no such charge; blank means unknown. Do not place recurring, optional or other charge types here. |

New CSVs use these 17 columns in the listed order: the original 13, followed by
`payment_structure`, `renewal_policy`, `price_vat_status`, `admin_fee_aed`.
The exact original 13-column and payment-era 15-column headers remain accepted
for historical files and already-queued Oban snapshots. Their missing fields
become NULL, not guessed defaults. Reordered, partial or other headers are rejected.

### Payment and renewal classification

These answer different questions: how is the access term paid, and does it renew
without a new action? A prepaid annual term may renew automatically, so never
infer one classification from the other. Likewise, recurring payments may be
instalments within a fixed contract; they do not prove zero commitment or rolling
cancellation rights. Keep minimum commitment and cancellation wording separate.

Before: Prime's one-month prepaid offer and 1Rebel's monthly recurring offer
share `billing_period_months = 1`. After: fresh, supported observations can carry
different payment/renewal classifications rather than being silently grouped.
This is a source-collection example, not a backfill or new imported gym record.

Missing or contradictory classification evidence excludes an offer from the
filtered comparison, but remains visible as evidence. The application validates
the codes, PostgreSQL also constrains them, and Grafana requires known matching
codes. No layer can determine these facts from omitted source wording.

### VAT basis and separate mandatory charges

The VAT flag applies to the advertised membership price only. It is not a
universal statement about the operator or the tax treatment of joining/admin
fees. No rate is assumed and no tax-inclusive price is automatically calculated.
Unsupported tax wording remains in notes with the structured value unknown.

Before: two quoted AED 200 monthly prices could be grouped even though one
includes VAT and the other excludes it. After: the filtered chart requires the
selected known VAT basis; unknown or conflicting tax evidence cannot qualify.
The excluded-VAT group compares pre-VAT advertised charges, not amounts payable.
The historical overview retains unaltered source amounts with an explicit
mixed/unknown-tax warning, rather than pretending those amounts are normalized.

Keep joining and one-time admin charges separate. A source stating no joining
fee proves `joining_fee_aed = 0`, not `admin_fee_aed = 0`. For example, a quoted
joining fee of 199 plus admin fee of 30 is two source facts, not a joining fee
of 229. A missing admin fee stays NULL. No totals or first-payment calculations
are implemented: other mandatory charges, their timing and their own tax bases
may still be unknown. Optional add-ons must not become mandatory admin fees.

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

## Current chart selection and plan normalization

The monthly chart has an explicit selected set of branch/plan identities:

- GymNation / Downtown Dubai / Core
- PureGym / Dubai Al Barsha / CORE
- The Warehouse Gym / IBN Battuta Mall / Light Monthly

The SQL in `grafana/dashboards/memberships.json` defines that set. It does not
automatically expand when a new gym, branch, or plan is imported. Change the
selection deliberately and update its regression fixtures when changing scope.

A complete chart date has a single known advertised price for every selected
offer, with single-branch access and monthly billing. Identical prices supported
by multiple rows produce one bar; conflicting prices make that offer/date
ineligible. The chart selects the newest complete date, so a newer annual plan,
unselected plan, partial refresh, or unknown price cannot erase an older complete
comparison. With no complete date, it returns no comparison. The query returns
the selected date as `Observed`; these observations are not a live price feed.

This is a date-based completeness rule for the existing MVP, not the future
collection-cycle model. Same-day refreshes cannot yet be identified as separate
cycles. Completeness concerns the advertised charge only; it does not establish
equivalent facilities, commitments, fees, or total costs.

### Normalize documented conditions, not marketing names

Keep `plan_name` exactly as published. `Core`, `CORE`, and `Light Monthly` are
source identifiers, not cross-operator tiers. Never rename them all `Basic` or
assume matching words imply matching benefits. Existing typed fields are the
shared vocabulary; Grafana's SQL provides readable labels without changing
stored facts:

| Stored field/value | Display meaning |
| --- | --- |
| `single_branch` | Single branch |
| `multiple_named_branches` | Specified branches |
| `all_uae_branches` | All operator UAE branches |
| `billing_period_months = 1` | Payment covers 1 month |
| `minimum_commitment_months = 0` | No minimum commitment, only when sourced |
| Missing commitment | Unknown, never equivalent to zero |

The dashboard separates these questions:

1. **Offer overview:** historical advertised monthly charges for the selected
   set on its last complete date, alphabetical rather than a value ranking.
   Gym names are short labels; when a selection contains multiple offers for
   one brand, branch and original plan disambiguate its bars.
2. **Filtered monthly-charge comparison:** uses that same overview date and
   requires matching access, monthly billing, and the selected **known** minimum
   commitment, payment structure, renewal policy and price VAT status for at least two distinct
   gym brands. Unknown or conflicting evidence in any of those dimensions
   excludes an offer. Matching terms never
   imply equivalent fees, tax rates, promotions, facilities, or benefits.
   This is not a fully like-for-like membership or all-in-cost comparison.
3. **Evidence history:** all recorded observations, including unknown prices,
   non-monthly offers and older dates. Original names, readable terms, native
   payment period, sources and notes remain visible. Chart filters do not hide
   this history. An annual price is not labelled `AED/month`.

The current access selection is fixed to Single branch, consistent with the
existing explicit offer set; commitment, payment, renewal and price VAT basis have selectors. Payment,
renewal and VAT selectors contain only the supported known codes, with no combined
All/Unknown choice. Commitment options include
No minimum commitment plus actual known durations from the selected records.
No `All` or `Unknown` option merges incompatible durations. Fewer than two
qualifying brands produces **Not enough comparable offers** and no filtered
bars. A newer partial collection still does not replace the overview date;
the filtered chart does not silently find a different date to fill itself.

Before: branded names and three prices could suggest equivalent memberships.
After: original names remain evidence, shared conditions are explicit, and a
filtered charge comparison appears only when its narrower criteria are met.
Manual official-source verification remains necessary: numeric validation and
SQL cannot discover omitted wording or certify that a recorded scope is true.

No all-in-cost calculation is implemented. The current model has separate
joining/admin fee fields and a VAT flag for the membership price only. This is
not complete mandatory-fee coverage or a tax model for every charge. Extending
that coverage requires a deliberate model/import change, not folding other fees
into existing fields or silently treating missing fees as zero. The filtered
monthly-charge chart does not add upfront fees, and fee equality/completeness
is not one of its qualification claims.

## Validation for the first iteration

- The CSV header must exactly match the current 17-column contract, the payment-era 15-column contract, or the original 13-column contract; do not mix their row widths.
- Every row must include `brand_name`, `plan_name`, `access_scope`, `source_url`, and `observed_on`.
- A row must include at least one of `advertised_price_aed` or `minimum_commitment_months`.
- Monetary values are AED and non-negative.
- Billing periods are positive whole numbers of months; zero cannot describe a price's billing period.
- Minimum commitments are non-negative whole numbers of months; zero means the source explicitly states no minimum commitment.
- Dates use `YYYY-MM-DD`.
- Payment structure and renewal policy accept only their documented codes or blank; there are no defaults, source inference or historical backfills.
- Membership-price VAT status accepts only `included`, `excluded` or blank. Admin fees must be non-negative exact numeric values or blank. Neither field supplies an implicit tax rate or an inferred zero.

## Duplicate observations during import

- An identical file is skipped using its content fingerprint.
- For different files, an observation is skipped only when all 17 parsed source fields match an existing membership. This also catches repeated rows within a file. Legacy missing fields match new blank fields; adding or changing a supported payment, renewal, VAT or admin-fee fact creates a distinct observation rather than overwriting history.
- Parsed numeric equivalents such as `100` and `100.00` match. Unknown values remain distinct from zero.
- Different dates, prices, scope, notes, or other source fields are retained as separate observations. This is not fuzzy matching or automatic correction of older observations.
- Each import reports inserted and skipped row counts. The file-tracking row count describes input rows, including skipped duplicates.
- For the small MVP, imports serialize membership writes within a transaction while checking and inserting. This can delay other writes; it is not a high-volume design or a database-wide uniqueness rule for code that bypasses the importer.
- Existing duplicates are not deleted by this import rule.

## Official-source spot check — 12 September 2026

The initial CSV contains three manually checked offers below. They are advertised observations, not purchase quotes or verified all-in costs. All three were recorded as single-branch access and monthly billing; differing or unknown commitments, fees, tax treatment, and offer type must remain visible in any comparison. These historical classifications are not newly certified by the dashboard; see the later audit and unresolved Warehouse access wording below.

- [GymNation Downtown Dubai](https://gymnation.com/en-ae/gymsnearme/downtown-dubai/) listed Core at AED 209/month with single-gym access. Its [UAE FAQ](https://gymnation.com/en-ae/gymnationfaqs/) described Core as a 12-month agreement paid monthly. Billing and commitment are distinct; confirm the supporting terms apply to the specific offer before collecting it. The branch page did not establish a joining-fee amount.
- [PureGym Al Barsha join selector](https://puregym-arabia.exerp.site/join/plan?center=8002), reached from the official branch page by selecting Dubai Al Barsha, displayed CORE at AED 199/month plus AED 89 joining fee, excluding two-gym access. This is the collected offer, not the different starting price on the landing page. General membership messaging says no commitment, but branch-specific applicability is unconfirmed, so the commitment field stays blank.
- [Warehouse join selector](https://whgym.com/join), after selecting Light, displayed a Monthly plan at AED 363/month for IBN Battuta Mall only, with a stated 3-month commitment. Its cancellation wording separately describes 2 months plus 1 month's notice; this is noted rather than interpreted. The collected amount is not the Al Quoz starting price or the rounded monthly equivalent of an annual plan. Joining fee remains unknown.

These pages were checked on the date above; their publication dates were not established. A check date is not a source publication date. Prices and terms may change.

## Comparability source audit — 22 October 2026

Read-only research, **not imported observations**. The CSV and development
database remain the 12 September records. Later evidence must not be backdated
or silently applied to older records. No personal information, purchase or
contract acceptance was submitted during these checks.

- **GymNation Downtown / Core:** the [branch page](https://gymnation.com/en-ae/gymsnearme/downtown-dubai/)
  advertises AED 209/month and single-gym access. The linked [joining flow](https://gymnation.com/en-ae/gymsnearme/gymmembership/?city=Dubai&location=Downtown+Dubai&membership=GymNation+Core+Membership),
  with Downtown and Core selected, explicitly states a 12-month minimum and
  VAT-inclusive prices. Optional body scans (AED 30) and water (AED 21) were
  preselected. Removing both produced a recurring AED 209 and AED 438 due today:
  AED 209 first month, AED 199 joining and AED 30 admin. This is an observed
  pre-payment summary, not a completed purchase quote. The separate admin fee
  exposes a gap in the existing fee model. [Operator terms](https://gymnation.com/en-ae/terms-conditions/)
  also describe tax inclusion and cancellation notice; commitment and notice
  are not interchangeable.
- **PureGym Dubai Al Barsha / CORE:** the [official joining selector](https://puregym-arabia.exerp.site/join/plan?center=8002)
  shows AED 199/month plus AED 89 joining, with two-gym access excluded. Selecting
  CORE and continuing to the member-details page confirms the branch, plan and
  amounts without supplying personal data. The [branch page](https://uae.puregymarabia.com/gyms/dubai-al-barsha)
  advertises no contract but contains conflicting price/fee copy; prefer the
  selected joining summary for amounts. [Monthly CORE membership messaging](https://uae.puregymarabia.com/membership-options)
  says no commitment. [UAE terms](https://uae.puregymarabia.com/terms-conditions)
  describe monthly cancellation at least two days before the next deduction
  and VAT included in membership fees. Do not infer every optional/conditional
  fee or the tax treatment of every charge from that membership-fee statement.
- **Warehouse / Light Monthly:** selecting Light then Monthly in the
  [joining flow](https://whgym.com/join) confirms AED 363/month and a stated
  3-month commitment. The details step selects IBN Battuta Mall. However,
  the Light card's description names IBN Battuta while its access list also
  mentions Dubai Silicon Oasis. Preferred home branch is not proof of exclusive
  access. Access scope needs clarification; do not silently certify the old
  `single_branch` classification or replace it with a guessed multi-branch set.
  Joining/admin fees and tax treatment were not established before the
  personal-details/payment boundary. No missing fee is recorded as zero.

Conclusion: the three selected plans do not establish one matching-commitment
group, and all-in costs are not uniformly verified. The current database has
unknown commitments for GymNation and PureGym and 3 months for Warehouse, so
the filtered chart must remain empty for both available commitment selections.
The overview and evidence history remain inspectable with explicit limitations.

### Public-source expansion eligibility matrix — 22 October 2026

This is a research decision record, **not five approved comparable memberships**.
No outreach, enquiry submissions, purchases or imports were performed. Prices
below were observed on public operator pages during this audit; observation does
not establish a publication date or guarantee availability. Do not rewrite the
12 September observations with these later findings.

| Additional operator / offer | Exact published amount | Established evidence | Eligibility decision / unresolved evidence |
| --- | --- | --- | --- |
| Prime Fitness / DIP / 1 Month DIP | AED 420 for one month | The [DIP page](https://www.primefitnessdxb.ae/european-mall-dip) identifies the branch, full gym access, no joining fee and VAT inclusion. The [gym policy](https://www.primefitnessdxb.ae/gym-policy) requires advance payment, describes renewal before expiry and states no refunds. | Strong candidate for a branch-associated, prepaid one-month offer. Record the paid term and renewal wording; do not relabel this as a zero-commitment rolling subscription or assume all possible fees are covered. |
| 1Rebel / DIFC / Gym Only Unlimited | AED 590 per month | Selecting Gym Only Memberships on the [buy page](https://www.1rebel.ae/en-ae/buy?secondaryTab=a64f44c8844e) displays the exact monthly price. [Terms](https://www.1rebel.ae/en-ae/terms-conditions) describe open gym, a one-month minimum, automatic monthly renewal and 30 days' cancellation notice. | Candidate for a rolling one-month-minimum offer, not zero commitment. Joining/admin fees are not established. The published VAT-inclusion and DIFC-only wording itself is in editorial brackets, and another clause has an unfinished placeholder. These are source-quality caveats affecting comparison fields, not merely unrelated clauses; do not certify settled VAT/scope evidence from this wording alone. |
| SK Fitness / Monthly Membership | AED 1,000 per month | The [plans page](https://www.skfitnessdubai.com/pricing-plans/plans) lists monthly payment, month-by-month commitment, open gym and unlimited classes; its footer identifies Dubai Production City. | Price evidence candidate. Confirm applicable access scope and detailed contract/cancellation conditions before a strict cohort; tax and joining fees remain unknown. Do not substitute the cheaper classes-only Queens plan. |
| La Maison de la Masse / Open gym / Monthly | AED 1,500 per month | The [pricing page](https://lamaisondelamasse.com/pricing/) explicitly states no commitment. The [gym page](https://lamaisondelamasse.com/private-gym-dubai/) ties unlimited open-gym access to Al Quoz and a 30-member cap. | Candidate for monthly open-gym access with explicitly no minimum commitment. VAT, joining fees, cancellation details and current capacity availability remain unverified; not approved for a VAT-consistent or all-in-cost comparison. |
| Binous Gym / One month | AED 1,800 for one month | The [operator site](https://binousgym.com/) lists the exact one-month amount and Al Quoz address, separately from personal-training prices. | Price evidence candidate only. Renewal, minimum contractual duration, tax and joining/admin fees remain unresolved. A one-month price alone does not prove zero minimum commitment. |

#### Which comparison does this support?

- **Public offer evidence:** the five operators above expand the research pool
  beyond the initial three. Exact prices do not by themselves certify complete
  terms, uniform availability or equivalent products.
- **Prepaid versus rolling:** Prime DIP and 1Rebel provide a concrete example:
  AED 420 covers one prepaid month; AED 590 is a recurring monthly charge with
  a stated one-month minimum and cancellation notice. These amounts can support
  an explicitly labelled charge overview with the different conditions beside
  them, not a claim that their contracts or benefits are equivalent.
- **No-minimum-commitment cohort:** PureGym's [monthly CORE FAQ](https://uae.puregymarabia.com/help-contact/our-memberships)
  and La Maison's monthly offer explicitly describe no commitment. This is a
  possible narrower research cohort, not an approved all-in comparison: La
  Maison's tax/fee treatment is unresolved, and PureGym's FAQ cancellation notice
  conflicts with the shorter notice in its general terms. Preserve both sources.
- **Total cost:** no expanded cross-operator cohort is approved. Unknown fees
  and tax treatment must not become zero or be hidden by monthly normalization.

The other researched operators are not silently approved: Metrofitt's published
prices still need a verified Home/Passport and branch mapping; Fitness First,
UFC Gym UAE and Wellfit remain without an exact applicable membership price on
the checked public routes. GymNation's later Core terms and Warehouse's Light
access ambiguity remain as documented above. Public class memberships such as
Boxica are a separate product category, not substitutes for open-gym access.

#### Implementation boundary before expanding the dashboard

The initial audit exposed missing structured distinctions. The extensions add
payment structure, renewal policy, membership-price VAT status and one-time admin
fees, retaining the exact 13- and 15-column snapshot formats. They do not populate
new gym observations or change the selected chart set. Cancellation notice,
per-fee tax treatment, other mandatory charges and classes-only versus open-gym
access still lack structured fields. Notes preserve that evidence but do not
make those remaining distinctions enforceable by SQL.

Before treating the wider pool as a stricter comparison, define those comparison
properties and their unknown/conflict behavior, then deliberately extend the
contract, validation, database and dashboard queries with regression tests. Only
after that gate should newly checked observations be collected/imported in a
fresh cycle and selected for the chart. The existing explicit three-offer SQL
does not automatically include any operator in this matrix.

### Post-extension classification checkpoint — 22 October 2026

This pass rechecked public offer selectors and supporting policies after adding
the structured payment/renewal and VAT/admin-fee fields. It changes research
documentation only: **no new CSV rows, imports or dashboard selections**. No
outreach, personal details, signup, purchase or acceptance of terms was performed.
Amounts are observations on this date, not guarantees of future availability.

| Offer checked | Advertised amount / billing period | Minimum commitment evidence | Payment / renewal classification | Membership VAT / fees | Strict comparison decision |
| --- | --- | --- | --- | --- | --- |
| PureGym / Dubai Al Barsha / CORE monthly | AED 199 / 1 month, confirmed in the [selected joining summary](https://puregym-arabia.exerp.site/join/details?center=8002&plan=6) | `0`: the [monthly-membership FAQ](https://uae.puregymarabia.com/help-contact/our-memberships) explicitly says no commitment. | `recurring` / `automatic`, explicitly described in the FAQ. | Membership VAT `included` in the [UAE terms](https://uae.puregymarabia.com/terms-conditions); joining AED 89 in the selected summary; separate onboarding admin amount unknown. | Candidate for the no-minimum, single-gym monthly cohort. The FAQ's 10-working-day cancellation notice conflicts with the general terms' two-day wording; retain that conflict, not a guessed notice. |
| 1Rebel / DIFC / Gym Only monthly | AED 590 / 1 month in the [Gym Only selector](https://www.1rebel.ae/en-ae/buy?secondaryTab=a64f44c8844e) | `1`: the [monthly terms](https://www.1rebel.ae/en-ae/terms-conditions) explicitly state a one-month minimum. | `recurring` / `automatic`, explicitly stated for monthly memberships. | VAT inclusion is a published claim, but literally bracketed; joining/admin amounts unknown. | Hold for settled VAT/scope evidence: the DIFC-only word is also bracketed. Even if those claims are accepted after review, minimum `1` does not exactly match PureGym's `0`. Thirty days' cancellation notice is a separate condition. |
| Prime Fitness / DIP / 1 Month DIP | AED 420 / 1 month on the [DIP page](https://www.primefitnessdxb.ae/european-mall-dip) | One fixed prepaid month. Mapping this to minimum `1` is an interpretation of the paid, non-refundable term, not an explicit minimum-commitment statement. | `prepaid_term`; `non_automatic` is an interpretation of the [policy](https://www.primefitnessdxb.ae/gym-policy) requiring advance payment and renewal before expiry, with access ending on expiry. | VAT `included`; joining `0` explicitly advertised; separate onboarding admin amount unknown. | Branch-associated prepaid candidate, not a recurring subscription. Do not certify exclusive branch access or the interpreted minimum/renewal codes without completing that classification review. It cannot be grouped with the two recurring offers simply because all prices cover one month. |

PureGym's selected CORE summary excludes the two-gym benefit shown for PLUS.
An unspecified admin fee remains unknown even when a joining fee covers initial
administration or a page says no joining fee. No total-cost calculation follows
from these membership-price and joining-fee observations.

**Result:** no two-operator group was approved under all current exact-match
rules in this pass. This is not a claim that no such offers exist across the UAE.
In particular, recording all three billing periods as one month would not make
their commitment, payment structure, renewal or evidence quality identical.
Keep the raw facts: never change `0` to `1`, infer an unknown as zero, or accept
ambiguous scope/VAT wording just to populate the filtered chart.

#### Additional public lead: FIT.

The [official memberships page](https://getfit.ae/memberships/) embeds a public
Glofox selector. The observed selector distinguished AED 339 monthly instalments
for an annual auto-renewing membership, AED 449 monthly cancel-anytime auto
renewal, and AED 549 for a one-month membership. These are different products;
the one-month validity label alone does not prove non-automatic renewal. Rates
for other branches and older promotions on the surrounding page must not be
substituted for the selected product.

The [terms](https://getfit.ae/terms-conditions/) state VAT-inclusive published
charges and a 12-month minimum for annual instalments. Their AED 200 admin
charge concerns failed payments: **it is not the one-time onboarding admin fee
in this contract**. Joining amount, exclusive-versus-network access and the
applicable cancellation wording remain unresolved for a strict cohort. The
membership page also displayed unrelated gambling links in its footer, a
source-quality warning rather than proof of compromise. Do not follow those
links or certify this source as safe. FIT. remains a held research lead, not an
approved membership observation or a verified match for GymNation.

#### Product decision still required — not implemented

An optional **minimum term at most one month** mode would ask a different
question from the existing **exact minimum term** mode. It could retain both
explicit `0` and `1` values as candidates, with their actual durations visible,
while retaining the other known access/payment/renewal/VAT gates. PureGym and
1Rebel illustrate that distinction, but 1Rebel's source-quality hold must still
be resolved before approving that pair. Such a mode does not establish identical
contracts or benefits, known total costs, or the ability to exit within one month:
cancellation notice may cause another payment to become due.

Keep exact matching unchanged unless this separate mode is explicitly approved.
The next implementation/import must not silently weaken the current comparison
claim or treat a threshold filter as a remedy for unresolved source evidence.

### Bounded pool audit and final count — 22 October 2026

Question: how many of the identified operators can actually be added to a
multi-operator filtered comparison under the present rules? This checkpoint
combines the public checks above with follow-up checks of the remaining price,
policy and signup boundaries. The denominator is the **13 named operators below**,
not every gym in the UAE. Multiple branches or plans of one operator do not count
as additional operators. No outreach or personal information was submitted, and
no terms were accepted, purchases completed, CSV observations imported, or chart
rules/selections changed.

| Operator | Exact public price evidence in this audit | Eligibility under the current strict rules |
| --- | --- | --- |
| GymNation | [Downtown Core](https://gymnation.com/en-ae/gymsnearme/downtown-dubai/): AED 209/month. | Sufficient evidence for the known single-gym, monthly recurring, automatic-renewal, VAT-included, 12-month-minimum candidate. [Terms](https://gymnation.com/en-ae/terms-conditions/) support Core's 12-month duration and recurring/tax treatment. No second approved operator matches all these dimensions in this pool. |
| PureGym | [Al Barsha CORE selector](https://puregym-arabia.exerp.site/join/plan?center=8002): AED 199/month, AED 89 joining. | Sufficient evidence for the known single-gym, monthly recurring, automatic-renewal, VAT-included, zero-minimum candidate, subject to the recorded cancellation-notice conflict. No second approved operator matches all these dimensions in this pool. |
| Warehouse Gym | [Light monthly selector](https://whgym.com/join): AED 363/month, three-month minimum. | Hold: the Light access wording conflicts, and membership VAT/renewal evidence remains unresolved. The linked [website terms](https://whgym.com/terms-and-conditions) and [FAQ](https://whgym.com/faqs) do not settle those fields. Do not certify the historical single-branch classification. |
| Prime Fitness | [DIP one-month offer](https://www.primefitnessdxb.ae/european-mall-dip): AED 420 for one prepaid month. | Separate prepaid lead; exclusive access and interpretation of minimum/renewal still need the classification review described above. Not equivalent to a recurring monthly subscription. |
| 1Rebel | [DIFC Gym Only monthly](https://www.1rebel.ae/en-ae/buy?secondaryTab=a64f44c8844e): AED 590/month. | Hold: the published VAT and exclusive-access wording is editorially bracketed. Its explicit one-month minimum must not be replaced with zero. |
| SK Fitness | [Monthly Membership](https://www.skfitnessdubai.com/pricing-plans/plans): AED 1,000/month before VAT; public checkout shows AED 50 VAT and AED 1,050 due each month. | Evidence improved: checkout explicitly confirms automatic renewal. The plan's month-by-month wording and Production City facility association still do not independently certify all exact minimum/exclusive-access fields. The AED 1,000 amount has VAT status `excluded`, not `included`. No automatic tax conversion or CSV change was made. |
| La Maison de la Masse | [Open-gym monthly price](https://lamaisondelamasse.com/pricing/): AED 1,500/month, explicit no commitment. | Hold: membership VAT and renewal treatment unresolved. The expanded currency FAQ confirms AED, not VAT inclusion. A possible zero-minimum match is not yet a qualified match. |
| Binous Gym | [Published membership table](https://binousgym.com/terms-conditions/): AED 1,800 for one month. | Hold: the public terms page does not establish applicable VAT, renewal or an explicit minimum commitment. One-month validity is insufficient to infer these. |
| FIT. | [Official embedded selector](https://getfit.ae/memberships/): AED 339 monthly for annual instalments; AED 449 monthly cancel-anytime auto-renewing; AED 549 one-month validity. | Hold: exact branch/access mapping and relevant minimum/renewal interpretation remain unresolved, with the source-quality warning above. The 12-instalment option is not a verified strict match for GymNation merely because both run for a year. |
| Metrofitt | [Membership-page response](https://metrofitt.com/membership/): AED 499 for one month upfront, plus VAT. | Hold: the browser-rendered page did not show the same pricing cards; the linked public [joining route](https://metrofittonline.sentinelscope.com/) requests personal details before progressing. Home/Passport and branch mapping are not verified. Retain the price evidence discrepancy, not an assumed branch quote or renewal classification. |
| Fitness First UAE | No applicable exact price verified. | The [joining route](https://uae.fitnessfirstme.com/join) loads a contact-details and mandatory-consent step before club/plan selection. Stop there; do not submit details to obtain prices. Generic terms or membership-benefit lists do not supply a selected price. |
| UFC Gym UAE | No applicable exact price verified. | The public [Business Bay promotion](https://ufcgym.me/experience/business-bay) requests contact details and says the team will confirm the rate. Neither that promotion nor the checked membership enquiry route supplies a usable exact price. No enquiry was sent. |
| Wellfit | No applicable exact membership price verified. | The [Meydan memberships page](https://wellfit.me/en/meydan-memberships/) lists plans, upfront durations and Passport access, but no prices. [Personal-training package prices](https://wellfit.me/en/packages/) are not gym-membership prices. No visit/contact form was submitted. |

#### Follow-up evidence: SK Fitness tax and renewal

From the public Monthly Membership card, the plan-customization page warns that
taxes and fees may be added. Selecting the current date, then continuing without
entering any customer information, exposes an order summary: AED 1,000 subtotal,
AED 50 VAT, AED 1,050 monthly total, and automatic renewal until cancellation.
The visible customer-details fields stayed empty. The checkout's Plan Policy
and Terms panels concern liability/participation; they do not resolve the
remaining contract/access questions. Checkout identifiers are session-specific;
the repeatable public starting point is the plans-page link above.

This is a directly observed tax breakdown, not a guessed five-percent rate.
The AED 1,050 displayed monthly total is not evidence of every possible joining
or other fee being zero, and is not an all-in-cost result. A later collection
could deliberately record a clearly sourced VAT-inclusive monthly amount, but
this audit has neither changed the advertised-price representation nor imported
such a new observation.

#### Count and decision

- **13 operators assessed** within this named pool.
- **10 operators have exact public price evidence**, counting Metrofitt's
  retrieved-page evidence with its rendering/mapping discrepancy. This is a
  research count, not ten import-approved offers or ten comparable memberships.
- **3 operators lack an applicable exact public membership price on the routes
  checked:** Fitness First, UFC Gym and Wellfit. This does not prove no such
  price exists anywhere on their sites.
- **2 clear strict-classification candidates:** GymNation Core and PureGym CORE.
  They belong to different minimum-term groups (`12` versus `0`), not one cohort.
- **0 approved multi-operator strict cohorts** (a cohort needs at least two
  distinct operators). Consequently **0 operators currently form a qualifying
  two-or-more-operator filtered comparison from this audit**. This is not the
  same claim as having zero known prices or zero usable individual facts.
- **0 approved multi-operator cohorts under the proposed at-most-one-month
  variant**, retaining all other current gates. PureGym remains eligible;
  1Rebel's source-quality hold and SK's unresolved classification are not cured
  by broadening the duration rule. The variant is not implemented.
- The dashboard still contains the **3 historical operators**. This research
  does not certify those three as a fresh strict comparison or add seven gyms.

Stop this bounded exercise here rather than promising a larger qualifying
number or repeatedly adding filters. The public-price evidence pool is larger,
but a non-empty strict comparison is **not yet established**. A future product
decision about a clearly labelled offer/terms explorer is separate from claiming
that these prices represent comparable contracts. Do not weaken unknown, scope,
tax or commitment rules silently, and do not use outreach to close these gaps.

This result is part of [Feature 2's consolidated completion gates](reviewer_handoff.md#feature-2--consolidated-scope-and-completion-gates),
not a separate completed data-expansion feature. The technical safeguards and
bounded audit are recorded as complete milestones; a verified real-data group
and branch delivery remain outstanding. No change to the exact-match contract
or approval of a threshold mode follows from documenting this result.

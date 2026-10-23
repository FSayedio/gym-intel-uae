# Current reviewer handoff

## Kubernetes migration checkpoint — 23 October 2026

Start with [the migration change table and operator guide](kubernetes.md).
This PR migrates the existing data and dashboard to a local ARM64 Kind cluster,
preserving scoped roles, manual updates and rolling-two lifecycle. No new gym
records or dashboard calculations are introduced. The older evidence below is
historical; use this PR's CI and migration verification for the new deployment.

The source and restored target initially matched exactly, including rows,
schema, roles, sequences and jobs. Both protected-state hashes were
`59eea542a190807266b64bd05f17bac481425f3ef13ed926c70b32df6efc3f60`.
The Kubernetes dashboard probe returned four offers and the actual permission
checks passed. Compose containers/volumes are retained stopped as a rollback
copy; Kubernetes is the active stack at port 3001. The final PR records the full
test/acceptance results. Nothing here claims a cloud or highly available system.

Updated 23 October 2026. Review this page first; the
[historical checkpoints](reviewer_history.md) preserve earlier evidence and
superseded designs, not current operating instructions.

The foundation/reliability milestone is delivered through
[PR #15](https://github.com/FSayedio/gym-intel-uae/pull/15), merge `e7dfb28`, with
green PR/post-merge CI and synchronized local main. The following Feature 6/7
sections retain dated evidence. Current recovery tooling and its exact limits
are documented in [Database recovery](database_recovery.md); its own PR delivery
must be checked separately.

## Recovery verification checkpoint — 23 October 2026

The recovery feature's final local suite passed **135 tests** (seed `639705`)
and the synthetic full-database rehearsal passed. A real private development
backup was restored into isolation and rechecked after publication; original
membership/note/import checksums, six observations/four brands and volume identity
were unchanged. All three development services were up afterward. No real
historical backup was pruned; retention was tested with synthetic bundles.
See [Database recovery](database_recovery.md) for commands, failure tests,
isolation and limits. These local results do not replace this change's hosted CI
or authorize a restore over live data. No data/migration/dashboard change is made.

## Outcome and scope

Help a person make their own gym choice using objective, source-backed facts.
The delivered slice is a local **advertised monthly-charge offer explorer**,
not a best-gym ranking, equivalent-membership comparison or total-cost calculator.

```text
Manually verified CSV -> Elixir validation -> durable Oban job
                    -> transactional importer -> PostgreSQL
                    -> restricted public view -> Grafana
```

Exactly three long-running ARM64 application services: app, PostgreSQL and
Grafana. The current deployment is Kubernetes; the following dated Feature 6/7
evidence describes the earlier Compose implementation. Short-lived operator/test
containers are separate from those services.
There is no automatic fetching, import schedule, scraping, custom web app or API.
The Kubernetes migration checkpoint above supersedes the earlier deployment boundary.

## Delivery and evidence baseline

At baseline `03cf1df`, Features 1–6 of the seven-feature foundation/reliability
milestone are merged. Feature 7 is this documentation cleanup; verify its own
PR/CI/merge and local synchronization rather than inferring delivery from prose.
The [roadmap](roadmap.md) includes a status-query command and deferred findings.
Seven features do **not** mean the entire project is complete.

- Feature 6: [PR #14](https://github.com/FSayedio/gym-intel-uae/pull/14), merged as
  `03cf1df47c3d3a02a9fd64eaf22e90a82ca26de9`.
- Latest Feature 6 PR revision: `688fab5126e7ea1598c1413437449e6b95641d4d`.
  [PR CI succeeded](https://github.com/FSayedio/gym-intel-uae/actions/runs/39918378815).
  The earlier base-image mismatch failure was fixed, not waived.
- [Post-merge CI succeeded](https://github.com/FSayedio/gym-intel-uae/actions/runs/39918887601)
  for merge `03cf1df`. The source suite reported **121 passed**; the separate
  final-image smoke check applied six migrations, processed two real synthetic
  jobs into one observation/note/file marker, and verified non-root execution,
  invalid-input/missing-secret rejection, graceful shutdown and scoped cleanup.
- Feature 7 read-only local baseline: three services running, PostgreSQL healthy,
  six applied migrations, six observations across four brands, two file markers.
  Local main was synchronized to `03cf1df` before creating the documentation
  branch. This is existing-data evidence, not a new import or fresh source audit.

Evidence belongs to the stated revision and environment. The Feature 6 results
are not a substitute for checking the latest Feature 7 PR. No independent human
approval, fresh-machine setup, restore drill or production readiness is claimed.

### Feature 7 documentation verification — 23 October 2026

- Local Markdown links/anchors and shell-block syntax were checked; the archived
  handoff body was compared with the previous Git version and preserved exactly.
  The six documented migration versions match the migration files and live DB.
- Read-only commands confirmed both Grafana health responses, existing completed
  import jobs, no pending imports, and the October file's three-record marker.
  Loaded graph/table targets structurally match the checked-in targets; their
  datasource queries each returned four offers without internal note/key fields.
  This was query verification, not a fresh browser/visual regression check.
- Canonical full-row checksums of observations, note versions and import markers
  still match the Feature 6 baseline. Six observations/four brands remain.
  No CSV was submitted, migration applied or service recreated for this check.
- Only Markdown changed. The source/runtime suites were not rerun for these
  prose edits; the 121-test result above is the observed Feature 6 baseline.
  Hosted verification of the resulting documentation PR remains a separate step.

## Reproduce and operate

Start with the [operator runbook](operator_runbook.md). It links the detailed
[setup and credential reference](local_development.md), shows expected outputs,
and separates queued jobs, committed data and displayed offers.

With only the two checked-in snapshots imported, expect six stored observations
and four displayed offers:

| Brand | Branch | Displayed monthly charge (AED) | Recorded on |
| --- | --- | ---: | --- |
| GymNation | Downtown Dubai | 209 | 2026-10-22 |
| La Maison de la Masse | Al Quoz 2 | 1,500 | 2026-10-22 |
| PureGym | Dubai Al Barsha | 199 | 2026-10-22 |
| The Warehouse Gym | IBN Battuta Mall | 363 | 2026-09-12 |

These are recorded examples, not live quotes. Warehouse's historical access
scope remains unresolved and is visibly disclosed. Commitments, fees, payment,
renewal and VAT differ or remain unknown. Source links/dates are available from
the bars and linked gym names. Refreshing Grafana does not collect or import data.

The current layout is one vertical graph with a right-hand gym legend, a compact
five-column conditions table and an evidence warning. There are no filters or
separate overview/history panels. Both queries select the same offers. Latest
observations are considered per brand/branch/original-plan identity; a newer
unknown or incompatible observation suppresses that offer, not the other gyms,
and does not fall back to its older eligible price. Historical source records
remain stored, even when they are not eligible for this display.

The localhost dashboard is not remotely hosted. Reviewers need private-repository
access and their own ARM64 Docker environment, or a screen-sharing session.
Do not delete existing volumes to simulate a fresh setup.

## Component and code map

| Component | What it does | Starting file |
| --- | --- | --- |
| CSV contract | Defines facts, scope, allowed values and unknowns | [Data contract](data_contract.md) |
| CSV reader | Bounded UTF-8 reading, headers, labelled records | [membership_csv.ex](../lib/gym_intel/membership_csv.ex) |
| Ecto changeset | Converts and validates a proposed record; does not save it | [membership.ex](../lib/gym_intel/membership.ex) |
| Oban worker | Stores CSV contents in a durable job; runs one import per configured queue instance, up to three attempts for unexpected failures | [import_memberships.ex](../lib/gym_intel/workers/import_memberships.ex) |
| Importer | Commits file marker, observations and note versions together | [membership_importer.ex](../lib/gym_intel/membership_importer.ex) |
| Ecto / Postgrex | Repository/query/transaction layer and PostgreSQL connector | [repo.ex](../lib/gym_intel/repo.ex), [runtime.exs](../config/runtime.exs) |
| PostgreSQL integrity | Generated uniqueness, append-only note history and public view | [Observation integrity](observation_integrity.md) |
| Runtime release | Explicit migrate/enqueue helpers, separate from worker startup | [release.ex](../lib/gym_intel/release.ex), [Dockerfile](../Dockerfile) |
| Grafana | Read-only queries over `dashboard_memberships` | [Dashboard JSON](../grafana/dashboards/memberships.json) |
| Verification | Isolated source tests and independent final-runtime checks | [CI guide](ci.md), [test directory](../test/) |

File fingerprints deduplicate identical bytes; observation keys deduplicate
the 16 typed non-note fields across different files. Note-only corrections append
internal versions. Unknown differs from zero. A changed price/date/source creates
another observation. Fingerprints do not authenticate a source or prove accuracy.

## Review checklist

- [ ] Record the exact reviewed revision and latest CI result; do not reuse an
  older green revision as approval. Review failures and skipped checks too.
- [ ] Follow the runbook and report steps actually executed versus only read.
  Check six migrations and job/data evidence, not just container startup.
- [ ] Confirm the contract against official branch/plan evidence. This handoff
  does not re-certify October/September facts as current or UAE-wide coverage.
- [ ] Confirm malformed input and invalid rows cannot partially import; inspect
  transaction, retry, overlap, collision and note-history tests.
- [ ] Verify the graph/table selection agrees, latest incompatible evidence does
  not silently fall back, and unknown never becomes a zero fee or commitment.
- [ ] Check real role boundaries: runtime cannot edit/delete observations or
  change schema; reader sees only the public view; migrator/owner credentials
  are absent from the running app. Docker's owner remains privileged.
- [ ] Read the [open-work register](roadmap.md#deferred-review-findings-and-operational-gaps).
  Green CI is not proof of backup recovery, source truth or dependency safety.

Return severity-ranked findings with file/line evidence, before/after examples,
expected versus actual results, commands run and checks not performed. Separate
blockers from optional improvements. Do not merge as part of the review.

## Limits that must remain visible

The recovery feature adds on-demand private PostgreSQL backups, isolated restore
verification and two-copy retention. The [update lifecycle](update_lifecycle.md)
connects import verification, backups, current-only observations and two finished
import-job retention. Review its failure boundaries separately. It does not deliver off-device recovery,
an automatic schedule, restore over development, or Grafana/credential recovery.
Age-based/general job pruning, abrupt-interruption recovery drills, multi-app load assessment,
fully independent clean-machine reproduction and automated browser regression
remain open. The runtime smoke test is not all of those; only PostgreSQL currently
has a Compose healthcheck.

The previously reported Decimal 3.1.1 advisory
`EEF-CVE-2026-97853 / GHSA-6c27-994x-c52f` remains unresolved; upstream Ecto xref
deprecation warnings have also been observed. This PR does not reassess or upgrade
dependencies. Builder/runtime bases are pinned, but not every downloaded package.

CSV contents persist in Oban arguments without scheduled pruning; never submit
secrets. Grafana anonymous access is Viewer, not Admin. Password files are local
Compose mounts, not encrypted secret management. Merge governance is manual,
not an enforced protected-branch rule. Keep the stack local.

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
  identical-file detection, and equality across all 13 fields for row duplicates.
- Are changed observations retained correctly? Notes/source changes are distinct
  observations, not semantic duplicates under the current rule.
- Does the dashboard avoid misleading comparisons? It uses the latest global
  observation date, single-branch access, monthly billing, and known prices.
  An incomplete latest collection can hide older gyms. Multiple eligible offers
  for one brand would repeat the shortened gym label; review before expanding data.
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
  load, and automated dashboard regression checks remain unverified.
- Full tests passed with an upstream Mix xref deprecation warning; compilation
  succeeded. No claim of CI, load testing, or production readiness is made.
- The 22 October 2026 security-containment rebuild reported a Hex advisory for
  Decimal 3.1.1 (EEF-CVE-2026-97853). The build succeeded; advisory assessment
  and dependency remediation remain pending as separate follow-up work.

## Requested reviewer output

Return findings ranked by severity, with file/line evidence, a reproducible
example, expected versus actual behavior, and a suggested minimal correction.
Separate correctness/security blockers from optional polish. Report commands
actually run and any checks not performed. Do not merge as part of the review.

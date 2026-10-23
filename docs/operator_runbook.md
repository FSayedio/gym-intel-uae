# Operator runbook

For the local ARM64 Docker Compose stack. Run commands from the repository root
with Docker Desktop running. This is the current everyday guide; use
[Local development](local_development.md) for configuration details and the
[reviewer handoff](reviewer_handoff.md) for revision-specific evidence.

The pipeline is manual CSV -> Elixir/Oban -> PostgreSQL -> Grafana.
Compose starts services; it does not import CSVs or apply migrations automatically.
Stop on a failed command. Do not proceed through later steps to hide an error.

## 1. Prepare a new checkout, or resume an existing stack

For first setup, follow [local secrets](local_development.md#local-secrets-and-grafana-administrator-login)
to generate the five private files. Never print or commit them. Existing secret
files are preserved; replacing a file does not automatically rotate a database
account or a Grafana administrator password. Choose optional host ports via a
private `.env` based on [`.env.example`](../.env.example) before startup.

Keep project name `gym-intel-uae`. Changing project name can select other empty
volumes; an apparently empty database is not permission to delete/reinitialize it.

For a new stack or the current already-upgraded schema:

```bash
docker compose build app
docker compose up -d --wait postgres
docker compose exec -T postgres sh /opt/gym-intel/configure-roles.sh
sh scripts/migrate.sh
docker compose up -d --wait
```

Before: local secrets exist; services may not be running. After: the release is
built, database roles/grants configured, pending migrations applied explicitly,
and three services started. `Applied migrations: 0` is normal if already current.
This is a sequence, not a single paste-and-ignore-errors operation. Stop if role
configuration or migrations fail; do not start a mismatched app after failure.

This is **not** a universal older-version upgrade recipe. For an existing
pre-integrity schema or changed PostgreSQL mounts, see
[maintenance boundaries](#6-maintenance-boundaries) first. The old trust-auth
password transition is historical, not a normal setup step.

## 2. Check services, schema and connections

```bash
docker compose ps
docker compose exec -T postgres sh /opt/gym-intel/role-psql.sh gym_intel_app -c 'SELECT version FROM public.schema_migrations ORDER BY version;'
grafana_address="$(docker compose port grafana 3000)"
curl --fail --silent --show-error "http://$grafana_address/api/health"
curl --fail --silent --show-error "http://$grafana_address/api/datasources/uid/gym-intel-memberships/health"
```

Expected:

- Exactly app, postgres and grafana running; postgres is healthy. App/Grafana
  being `Up` alone does not prove successful jobs or correct charts.
- Six migration versions: `20260912000100`, `20260912000200`, `20260912000300`,
  `20261022000100`, `20261022000200`, `20261023000100`.
- `/api/health` reports Grafana's own database `ok`.
- The separate datasource endpoint reports `OK` / `Database Connection OK`.
  This proves its connection, not the correctness or freshness of every offer.

`docker compose port` discovers the actual mapped address, including `.env`
overrides. Do not substitute the PostgreSQL host port for internal `postgres:5432`.
The runtime image intentionally lacks Mix; do not run `app mix ecto.migrations`
or grant schema privileges merely to make that old command work.

## 3. Submit a verified CSV snapshot

For normal updates, use the [one-command lifecycle](update_lifecycle.md):

```bash
sh scripts/update-dashboard.sh data/memberships-2026-10-22.csv
```

Supply your newly verified input, not repeated checked-in examples. This waits for
the exact committed import, creates/restores a verified backup, keeps two copies,
then transactionally removes superseded observation dates and old finished import
jobs (keep two). Unfinished jobs block the run. Grafana rereads PostgreSQL every
30 seconds while open; it does not fetch websites. Read the final phase/status:
an import may succeed even when backup or cleanup fails. Old job IDs can expire;
the small fingerprint markers remain. Pulling this code does not run cleanup.

The commands below are the **low-level submit-only diagnostic path** and describe
counts before lifecycle cleanup, not the normal update workflow.

For the checked-in example data, run each command separately and verify the job
before submitting the next. These commands **write** job/data state; do not run
them merely to inspect a stack that is already populated.

```bash
sh scripts/import-csv.sh data/memberships.csv
sh scripts/import-csv.sh data/memberships-2026-10-22.csv
```

Before: the file is a local manually sourced observation snapshot. Action: the
helper validates its bounded UTF-8 contents and submits those exact bytes.
After: `Queued import job <id>; check job state for completion.` This reports
submission, not delivery. Note the returned ID for the next step. Invalid input
exits nonzero without a queued job; do not extract a number from ambiguous text
such as `from 199` just to make it pass.

Only existing paths under `data/` are accepted. CSVs are limited to 1,000,000 bytes
and the [data contract](data_contract.md) governs facts, sources and unknowns.
Each queue instance runs one import at a time; it is not an hourly fetcher.
Unexpected exceptions can retry up to three total attempts. Known invalid input
is rejected before enqueue or cancelled by the worker. CSV contents persist in
job arguments; never include secrets or private customer information.

## 4. Distinguish queued, completed and committed

First inspect the [private saved lifecycle reports](update_status.md), without
rerunning an import:

```bash
sh scripts/update-status.sh
```

This is read-only evidence, not a live health check or automatic repair. It shows
confirmed/not-attempted/unknown outcomes and keeps two finished summaries. A
missing report or expired job ID is not proof that an import never ran. When a
stage is unknown, use the safe job/fingerprint queries below before retrying.

List recent import jobs without exposing CSV arguments or raw error payloads:

```bash
docker compose exec -T postgres sh /opt/gym-intel/psql.sh -c "SELECT id, state, attempt, max_attempts, completed_at, cardinality(errors) AS recorded_errors FROM public.oban_jobs WHERE queue = 'imports' ORDER BY id DESC LIMIT 5;"
```

Find the exact ID returned by the helper. `available`/`scheduled`/`executing`/
`retryable` are not completion. `cancelled` or `discarded` requires investigation.
A `completed` job means the worker reported success, which can include an empty
CSV or an already-imported snapshot. Error history can remain after a successful
retry; do not confuse a nonzero history count with the job's current state.

For a nonempty file, compute its raw-byte fingerprint and look for the committed
file marker (this example checks the October snapshot):

```bash
snapshot_sha="$(openssl dgst -sha256 -r data/memberships-2026-10-22.csv | awk '{print $1}')"
docker compose exec -T postgres sh /opt/gym-intel/psql.sh -c "SELECT row_count, inserted_at FROM public.membership_imports WHERE content_sha256 = '$snapshot_sha';"
docker compose exec -T postgres sh /opt/gym-intel/psql.sh -c "SELECT (SELECT count(*) FROM public.memberships) AS observations, (SELECT count(DISTINCT brand_name) FROM public.memberships) AS brands, (SELECT count(*) FROM public.membership_imports) AS imported_snapshots;"
```

Expected for **only these two checked-in nonempty snapshots**: a marker for each
file with `row_count = 3`, six observations, four brands and two markers. Later
legitimate imports can change these totals; do not delete rows to force a match.
The marker's `row_count` counts validated input records, not newly inserted rows.
Matching rows can be skipped, and a note-only change can add a note version.
Worker result counts are not stored as an Oban receipt report.

The importer commits observations, note versions and marker in one transaction.
An identical file can create another successful job but not another marker or
extra observations. Header-only CSVs complete without a marker. A marker proves
that snapshot's transaction committed—not that the official facts are true or
that no later observations exist. Use source checks, expected facts and the
dashboard selection together; do not equate a job status with data accuracy.

## 5. View the result and run verification

Get the local dashboard URL without assuming the default host port:

```bash
grafana_address="$(docker compose port grafana 3000)"
printf 'http://%s/d/gym-intel-offers\n' "$grafana_address"
```

Open the printed URL and refresh Grafana. The current layout has one vertical
graph, a right-hand gym legend, five-column conditions table and evidence warning,
with no filters. With both snapshots imported, expect four offers: GymNation 209,
La Maison de la Masse 1,500, PureGym 199, Warehouse 363 AED/month. Six historical
observations do not mean six bars. Newer unknown/incompatible evidence can
suppress its offer; it must not silently fall back to an older price.

Unknown fees/terms stay unknown, not zero. Recorded dates differ and Warehouse's
historical access scope is unresolved. These are advertised charges, not equal
contracts, live prices or total costs. See the [contract](data_contract.md).

For verification after a reviewed change:

```bash
sh scripts/test-database.sh --ci
sh scripts/verify-compose.sh
sh scripts/verify-release.sh
sh scripts/verify-recovery.sh
sh scripts/verify-readiness.sh
sh scripts/verify-permissions.sh
git diff --check
```

Build the current runtime with `docker compose build app` first if code changed.
The test wrapper builds the separate checks image. These are not all read-only:
source tests write only `gym_intel_test`; release verification creates and removes
its own generated database/roles/container; permission probes use transactional
test objects in development and roll them back. No development CSV is imported.
The recovery rehearsal creates its own synthetic PostgreSQL/app fixture and
isolated restore container, without development volumes or secrets.
The readiness rehearsal starts its own bounded PostgreSQL instance and generated
worker, measures 1,000-row/replay/overlap imports, and kills only that test worker
behind a deterministic transaction gate. Its explicit exact-job recovery is not
automatic production orphan rescue. See [measurement and interruption limits](ci.md#bounded-setup-workload-and-interruption-rehearsal).
See [test isolation](local_development.md#repeatable-tests) and [CI](ci.md).

Expected: passing tests/checks and successful scoped cleanup; `git diff --check`
prints nothing and exits zero for tracked changes. It does not check an untracked
file until staged. Stop on failures; do not reset a volume or loosen grants.
Green tests do not certify source accuracy, backups or an advisory-free build.

## 6. Maintenance boundaries

Before a data-affecting upgrade, establish the exact revision, pending migrations,
target database, backup and recovery plan. Imports must be quiescent, including
other submitters—not just an apparently idle container. Read queue state first:

```bash
docker compose exec -T postgres sh /opt/gym-intel/psql.sh -c "SELECT state, count(*) FROM public.oban_jobs WHERE queue = 'imports' AND state IN ('available', 'scheduled', 'executing', 'retryable') GROUP BY state ORDER BY state;"
```

Any returned count means unfinished work: stop and agree how to handle it.
Zero rows is only a point-in-time observation, not a lock against new submissions.
Once submission is controlled and no work is pending, `docker compose stop app`
stops the worker while leaving PostgreSQL/Grafana running. Graceful shutdown is
not proof of recovery from power loss. Do not cancel/delete jobs just to clear
this gate. Restart the worker only after the approved migration/grant checks.

The recorded Feature 5/6 upgrades included private backups, archive-list checks,
volume identity and original-data checksums. They did **not** verify a restore.
For the current on-demand backup and isolated restore workflow, use
[Database recovery](database_recovery.md). It provides a verified local copy and
two-copy retention, not an automatic schedule or restore-to-live operation.
The optional `--with-dashboard` rehearsal also reconstructs a fresh Grafana from
Git against the restored database with new credentials, without activating it.
Use the [incident procedure](database_recovery.md#incident-procedure-preserve-restore-verify-explicitly-cut-over)
for recovery-point, credential-loss and persistent-target/cutover decisions.
If live recovery is required, preserve evidence and obtain an explicitly reviewed
target/recovery plan; do not overwrite development from an old recipe. A checked
archive in `/tmp` is not durable disaster recovery, and a local copy is not
protection against losing the laptop/drive.

Integrity migration `down` refuses to discard note history. Do not force it or
start an old importer against the newer append-only grants. Prefer a reviewed
forward fix. See [integrity upgrade notes](observation_integrity.md#coordinated-upgrade-of-a-running-older-dashboard).

PostgreSQL currently uses read-only directory mounts for tracked helpers/SQL;
do not repeatedly recreate every container for the historical stale-file issue.
Individual credential and Grafana startup-script mounts still need care if files
are replaced. Diagnose the affected service and agree a targeted recreation,
preserving named volumes. No recreation is a substitute for rebuilding changed
application code or applying pending migrations.

## 7. Diagnose without destroying evidence

| Symptom | Safe first check | Boundary |
| --- | --- | --- |
| Docker/connection unavailable | Open Docker Desktop, then `docker compose ps` | Do not reinstall/reset Docker or delete volumes. |
| Host port already used | Review `.env`; discover mappings with `docker compose port` | Change only approved host ports; internal database stays `postgres:5432`. |
| Authentication denied | Check the expected secret file exists privately and the role matches | Do not print passwords, switch to trust, or give the app owner credentials. |
| Migration/grant failure | Record failing step, schema versions and reviewed revision | Stop startup; preserve data; no automatic rollback/reset. |
| Job incomplete or cancelled | Check exact job ID/state/attempt/error count | Raw errors/logs can contain input; inspect privately and redact before sharing. |
| Job complete but no extra rows | Check empty input, file marker and duplicate observations | Completion may mean already imported; do not remove fingerprints to force inserts. |
| Missing bars | Check current rows, latest evidence and datasource health | Exclusion may be correct; do not revive older prices or treat unknowns as zero. |
| Data suddenly appears empty | Check project name and existing volume identity | Do not initialize a new volume or delete old data as a workaround. |
| Temporary verification cleanup fails | Identify the exact generated resource from the failed run | Never substitute broad database, role or volume deletion. |

Avoid posting `docker inspect` environment output, raw job arguments, private
error payloads, dumps or secret files. Share narrow, redacted evidence instead.

## 8. Stop normally

```bash
docker compose stop
```

Containers stop; named volumes retain PostgreSQL facts and Grafana settings.
To resume an unchanged stack, `docker compose up -d --wait`, then repeat Step 2.
`docker compose down` also removes containers/network but retains named volumes;
neither is a backup. Never add `-v` or delete volumes as routine cleanup.

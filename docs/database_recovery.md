# Local PostgreSQL backup and restore verification

## Outcome, scope and components

Before: the database lived in its Docker volume; earlier upgrade archives were
only list-checked. After: an on-demand command captures a private logical backup,
restores it into isolation, verifies it, and keeps the latest two verified copies.
This is a local recovery rehearsal—not a restore-to-live command, off-device
disaster recovery, continuous archiving or a production backup service.

| Component | Responsibility |
| --- | --- |
| [backup-database.sh](../scripts/backup-database.sh) | Validate the source, refuse unfinished jobs, pause/resume the existing app, capture, verify, publish and apply retention |
| PostgreSQL `pg_dump` | Whole single-database custom-format archive: schema, rows, sequences, object ownership and grants |
| [snapshot.sql](../scripts/recovery/snapshot.sql) | Deterministic private comparison: full-row hashes, schema/grants, migrations and sequence states |
| [verify-database-backup.sh](../scripts/verify-database-backup.sh) | Isolated restore, full comparison, real permission denials and transactional identity/note probes |
| Optional `--with-dashboard` and [dashboard_probe.exs](../scripts/recovery/dashboard_probe.exs) | Fresh Grafana from Git against restored data, real panel queries and fresh admin login; never a live cutover |
| [common.sh](../scripts/recovery/common.sh) | Managed-path/privacy/checksum checks and fail-closed two-copy retention |
| [verify-recovery.sh](../scripts/verify-recovery.sh) | Disposable synthetic source/restore integration test; never development data |

The archive covers memberships, internal note history, file markers, migration
versions, Oban jobs/peers and their schema dependencies. Oban arguments/errors can
contain entire submitted CSVs and private input: do not print, commit, upload or
attach archives/logs as CI artifacts. Snapshot reports contain hashes rather
than table contents, but are private too.

Database-global role definitions/passwords, secret files, Grafana's separate
volume and Git checkout are **not** included. The isolated verifier recreates
the four supported role identities with distinct throwaway passwords; it does
not copy live credentials. Custom memberships/role settings or additional user
schemas require an explicitly reviewed extension, not a silent partial-success
claim. Existing-volume credential recovery and whole-machine recovery remain
separate work. The replacement rehearsal uses new credentials; a data archive
is not a password-recovery mechanism.

## Create and verify a backup

Normal data updates now invoke this through the explicit
[update lifecycle](update_lifecycle.md), followed by guarded current-data/job
cleanup. Standalone capture below remains supported and does not delete live
observations/jobs itself. Both paths share the two-verified-copy limit. Do not
run standalone capture/verification or low-level imports concurrently with updates.

Run from the repository root with Docker Desktop and the current stack available.
OpenSSL is required on the host (also used by the existing secret-generation
instructions). No new global tool install or permanent Docker service is needed.

```bash
sh scripts/backup-database.sh
```

Default location:

```text
/Users/farhansayed/Library/Application Support/Gym Intel UAE/backups
```

The default is derived from the invoking user's home directory. Root/bundle
directories must be owned by that user with mode 700, and persistent files mode
600. Archives are **not separately encrypted**. This restricts other local users;
it does not protect against the user's own account, Docker administrators or
drive loss. Nothing is automatically uploaded. A deliberately chosen alternate
absolute private directory may be supplied with `--directory`; a temporary path
is not durable storage, and broad/repository/traversal paths are refused.

The command performs these steps, stopping on failure:

1. Validate a managed private backup directory and acquire an exclusive capture
   lock. The lock records PID/start time. A stale lock is reported, not removed
   automatically. Do not run standalone verification concurrently with capture.
2. Resolve the existing source PostgreSQL/app containers and check project/database
   identities. The normal source is `gym-intel-uae` / `gym_intel_dev`, not an
   arbitrary connection string. Test-only routing requires a uniquely labelled
   disposable fixture project and never targets the real development project.
3. Refuse available/scheduled/executing/retryable jobs. Do not submit jobs, apply
   migrations or run other writes during capture. The gate is not a global
   maintenance lock against another privileged operator.
4. Briefly stop only the existing app if running; PostgreSQL and Grafana stay up.
   Capture a baseline, archive and second baseline. Source drift fails capture.
   Snapshot checks also refuse unfinished jobs at that checkpoint.
5. Restart the original app and confirm database connections before the longer
   restore check. An originally stopped app stays stopped. Failure/signal cleanup
   attempts to resume an app stopped by this run; restart errors are reported.
6. Restore into a new, network-disabled PostgreSQL container with temporary data
   in tmpfs. No live volume, live secret, worker, host port or Docker socket is
   mounted. It uses the locally available exact source PostgreSQL image ID.
7. Compare every captured table's full-row hash/count, logical schema definitions,
   ownership/grants, role attributes, migration rows and sequence positions.
   A narrow normalization recognizes PostgreSQL's equivalent ASCII allowlist
   array-cast rewrite; changed literals/operators remain differences. Column order
   is logical, not the physical numbers of previously dropped columns.
8. Probe actual restored role connections: forbidden runtime/reader operations
   fail with permission errors; reader view access and migrator DDL work. Insert/
   duplicate/initial-note probes run only in the restored copy and roll back.
   No worker starts, so restored jobs cannot execute.
9. Remove the exact labelled temporary container and generated credentials. Only
   after verification and cleanup succeed, write the verification marker and
   publish a timestamped `backup-...` directory. Then apply two-copy retention.

Expected final output includes:

```text
PASS: complete restored baseline, actual role denials, identity/initial-note probes; no worker started
PASS: verified database backup: .../backups/backup-<UTC timestamp>-<suffix>
Retention: latest two verified backups; local-only, not separately encrypted.
```

Check the command's final exit status, not a partial PASS line before a later
cleanup/retention error. A reported restart/cleanup failure needs investigation.
Do not kill the command mid-capture, reset a volume, or assume SIGKILL/host failure
will run shell cleanup.

## Recheck a saved copy

Use the **exact absolute bundle path printed by the successful command** as the
single argument to `sh scripts/verify-database-backup.sh`. This does not pause the
live app, modify live data or prune copies. It restores only into a new sandbox.
Checksums catch accidental changes; the private marker is not a cryptographic
signature or a guarantee against someone who can rewrite the backup and metadata.
Only verify trusted backups from this managed workflow: restore executes SQL.

Each bundle contains `database.dump`, `baseline.json`, format/image information,
SHA-256 files, private capture/restore logs and a matching `verified` marker.
The exact source image must still exist locally; missing/incompatible images
fail rather than silently switching PostgreSQL versions. Image delivery after
cache/machine loss is not solved by this local-only feature.

## Rehearse the replacement dashboard

The optional mode restores a trusted bundle into a **fresh disposable target**,
then starts fresh Grafana with our Git-provisioned dashboard/datasource and new
admin/reader credentials:

```bash
sh scripts/verify-database-backup.sh /absolute/path/to/backup-directory --with-dashboard
```

Supply an actual managed bundle path, not that placeholder. The default verifier
remains network-disabled. This mode instead creates a labelled, internal-only
Docker network with no host ports or live volume/secret mounts. Grafana uses tmpfs
rather than its existing volume. PostgreSQL, Grafana and checks images must
already be present locally and ARM64-compatible; no image is silently pulled.
PostgreSQL must match the backup's recorded exact image ID.

After the original baseline/permission checks, the probe verifies:

- A healthy datasource authenticated as the restricted `gym_intel_grafana` reader.
- Git-matching dashboard identity and both panels' exact query configuration.
  Chart/conditions must return the same ordered offer names and numeric chart
  prices. An empty eligible set is valid for a generic backup. The synthetic
  rehearsal separately requires its exact one-offer/199 fixture, preventing an
  empty result from falsely passing that test.
- A freshly generated credential authenticates as the administrator.
- No runtime/worker connection and unchanged captured PostgreSQL state after the
  HTTP queries. No restored jobs execute.

Full baseline comparisons run before the transactional identity/duplicate insert
probes: rolling back those inserts removes their rows but does not undo ID-sequence
advances. The initial rehearsal caught the wrong ordering; the full comparison
was retained and the probes moved afterward, with an ordering regression test.

Only generated containers/network/credentials are removed, with identity labels
checked first. A cleanup failure can follow an earlier PASS: require the final
zero exit. Logs stay private in `restore.log`; the archive, retained copies and
verification marker are unchanged. Do not run concurrently with another recovery
or update command. This proves API/data flow, not pixel-perfect browser rendering.
Neither replacement is retained or activated; no new permanent service is added.

## Incident procedure: preserve, restore, verify, explicitly cut over

This is an operator procedure, not a restore-over-live one-liner. The verifier
destroys its temporary replacement; an actual incident needs a separately
approved **persistent** target and cutover.

1. **Freeze and identify.** Record the project, source revision, failing service,
   volume/container identities and trusted backup. Stop submissions and inspect
   unfinished jobs. Stop only the worker under an agreed maintenance window.
   Preserve the original target, secrets, evidence and both verified copies.
2. **Select the recovery point.** Review capture time, known input markers and job
   state privately. A backup cannot recover later writes. Preserve fingerprint
   markers; do not force old-file imports or start a restored worker to inspect it.
3. **Prove the copy first.** Run the optional rehearsal above. Resolve missing
   images, changed checksums/schema/permissions and missing Git configuration;
   do not weaken authentication or waive failures.
4. **Prepare a distinct empty persistent target.** Approve its exact volume,
   container/database names and matching image/revision before creating it.
   Recreate the four supported role identities with distinct new secret-file
   passwords. The tested `bootstrap.sql`/restore sequence establishes the order:
   roles and empty database, complete archive restore with ownership/grants via
   `pg_restore --exit-on-error --single-transaction`, then full baseline and
   permission checks. Do not use `--clean`, drop the old database, or apply initial
   migrations over the restored schema.
5. **Reconstruct and validate Grafana.** Use the tracked provisioning/dashboard,
   fresh Grafana volume and matching new reader/admin secrets. Check datasource,
   actual panel queries and administrator login. Ad-hoc users, preferences,
   sessions and untracked UI changes are deliberately not recovered.
6. **Authorize cutover separately.** Confirm the recovery point/data loss, matching
   app/config revision, no other writers, credential mounts and destination.
   Only then switch clients to the verified persistent target. Review restored
   job states before enabling the worker; HTTP health is not import completion.
   Inspect the dashboard manually. Keep the original target until recovery is
   accepted and its disposal is separately approved.

The replacement rehearsal is implemented/tested; actual live cutover, a persistent
replacement deployment and physical-host failure have not been performed here.
Do not assume a generic command selects a new target rather than the live one.

### Credential loss is not volume loss

| Incident | Response | Boundary |
| --- | --- | --- |
| Non-owner password lost, owner available | Reviewed role reset through the owner, matching private-file update and targeted client recreation, following local development guidance. | A file replacement alone does not reset a stored password. |
| Owner credential lost, old volume remains | Recover the credential privately; otherwise use a trusted backup and separate fresh target. Preserve the old volume. | No trust-auth bypass or volume reset. |
| PostgreSQL volume lost, backup remains | Restore captured schema/data/grants with new role credentials. | Original passwords and writes after capture are not in the archive. |
| Grafana volume/admin credential lost | Reconstruct Git-managed state in a fresh target with new credentials. Retaining an existing volume needs a separate reviewed admin reset. | Changing its password-file setting does not reset an initialized account. UI-only state is not backed up. |
| Laptop and local backup drive lost | Recover from an independently retained copy, if any. | Azure/off-device backup was explicitly deferred; a lost only copy is unrecoverable here. |

Keep credential recovery material privately outside Git/transcripts. No credential
export, password-manager account, scheduler, notification or off-device service
is configured by this work. Existing health checks remain operator-triggered.

## Retention and failure behaviour

- Keep the latest **two verified backups**, not two days. Captures are explicit
  (standalone or during updates); protection is as recent as the last success.
- Backup #3 must restore successfully before the oldest verified copy is removed.
  Validate all candidates first. Unexpected files, symlinks, insecure permissions,
  mismatched checksums or verification markers stop retention before deletion.
  A backwards timestamp/order also stops deletion rather than pruning the copy
  just created; resolve the clock/order issue without changing global settings here.
- No recursive sweep of the backup root or user-provided directories occurs.
  Retention deletes only allowlisted files in validated managed backup bundles.
- Failed attempts remain private `.pending-...` directories for diagnosis and
  do not count as good backups. They are not automatically pruned and can consume
  space. Inspect the precise failed run before agreeing scoped cleanup.
- Verification failure keeps earlier good copies. If retention fails after a new
  good copy is published, extra copies can remain; do not mistake the nonzero
  command status for permission to remove unrelated files.
- The restore sandbox is limited to 512 MiB tmpfs and 768 MiB container memory.
  Oversized archives, disk/memory pressure, unsupported schema/roles and Docker
  failures must fail, not reset data. This is not a throughput/capacity guarantee.

After capture, original facts, notes, file markers and volume identity must remain
unchanged. Oban peer/lifecycle metadata can legitimately change when the app
stops/restarts; compare the restored copy to its **captured** baseline, not a
later running database's heartbeat. Grafana remains a query-only reader.

There is no automatic live restore, destructive rollback, existing-volume password
bypass, off-device copy, scheduler, PITR or Grafana-volume backup. Grafana can be
reconstructed as above; a real incident still needs an approved persistent target
and cutover plan before replacing data.

## Repeatable verification

```bash
sh scripts/test-database.sh --ci
sh scripts/verify-recovery.sh
```

The first command uses only `gym_intel_test`. Fast tests cover filesystem/privacy,
corruption, retention, unfinished-job refusal and restart-on-failure; a database
regression checks narrow cast normalization preserves changed semantics.
The second command creates a synthetic PostgreSQL/app fixture with no host port
or development volume, executes the actual capture/restore entrypoints, and
rejects corrupt archives both before use and after a recomputed checksum. A
deliberately weakened fixture runtime role must also fail verification while the
previous good backup survives. Synthetic containers are removed; failed fixture
logs may remain privately for diagnosis. No synthetic fixtures are real gym facts.

GitHub CI invokes that same separate recovery rehearsal after its source and
runtime checks. It uses disposable credentials/data and does not access this
laptop, its `.secrets/`, private backup directory or development volumes. A green
run is not a claim of full disaster recovery, source truth or advisory remediation.

References: PostgreSQL 18 [pg_dump](https://www.postgresql.org/docs/18/app-pgdump.html)
and [pg_restore](https://www.postgresql.org/docs/18/app-pgrestore.html).

## Recorded local evidence — 23 October 2026

- The final shared source/DB suite passed **135 tests**, seed `639705`.
- The synthetic end-to-end recovery rehearsal passed, including a valid restore,
  both corrupt-archive cases, weaker-role rejection, app resume and preservation
  of the prior good backup. Unit tests separately exercise three-to-two
  retention, tampering, unknown files/symlinks, private modes, stale locks,
  backwards timestamps, unfinished jobs, capture/restart failures and an initially
  stopped app. The SQL regression preserves differing constraint semantics.
- The first real on-demand backup was successfully restored and verified into
  isolation; the published copy then passed an independent recheck. One actual
  verified backup was created—not seven copies. Retention's eight-to-seven case
  used synthetic bundles, not deletion of real historical archives.
- Canonical checksums of every original membership, note version and file marker
  matched before/after. Six observations/four brands remained and the named
  PostgreSQL volume was identical. Exactly three development services were up
  afterward; only the app was briefly stopped. Grafana and its datasource health
  were OK. No restore container remained.
- An initial test-path failure and equivalent-CHECK-cast mismatch were diagnosed
  and corrected, not waived. The cast correction has a dedicated regression.
  Existing dependency/test warnings and the Decimal advisory are not remediated.

These are local checks, not a claim that a later PR/merge passed hosted CI. Check
the associated recovery PR's exact revision before review/merge.

## Operational-readiness recovery checkpoint — 23 October 2026

- Expanded source/database suite: **174 passed**, seed `333177`, including six
  dashboard-probe tests and the sequence-sensitive ordering regression.
- The synthetic backup reconstructs fresh Grafana from Git against restored
  PostgreSQL: both real panel queries return the one expected 199 offer, reader
  connectivity works, and a fresh administrator credential authenticates. An
  intentional expected price of 198 is rejected, not reported as recovery success.
- Full captured data/schema/grants/sequences are compared before and after the
  HTTP reads. Identity/duplicate insert probes run afterward because their rolled-
  back inserts legitimately advance sequences in the disposable copy.
- These are local, uncommitted working-branch results, not hosted CI or an actual
  live cutover. No real backups, passwords, dashboard data or volumes were used
  by the new synthetic reconstruction check. Off-device recovery remains deferred.

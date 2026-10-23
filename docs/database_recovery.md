# Local PostgreSQL backup and restore verification

## Outcome, scope and components

Before: the database lived in its Docker volume; earlier upgrade archives were
only list-checked. After: an on-demand command captures a private logical backup,
restores it into isolation, verifies it, and keeps the latest seven verified copies.
This is a local recovery rehearsal—not a restore-to-live command, off-device
disaster recovery, continuous archiving or a production backup service.

| Component | Responsibility |
| --- | --- |
| [backup-database.sh](../scripts/backup-database.sh) | Validate the source, refuse unfinished jobs, pause/resume the existing app, capture, verify, publish and apply retention |
| PostgreSQL `pg_dump` | Whole single-database custom-format archive: schema, rows, sequences, object ownership and grants |
| [snapshot.sql](../scripts/recovery/snapshot.sql) | Deterministic private comparison: full-row hashes, schema/grants, migrations and sequence states |
| [verify-database-backup.sh](../scripts/verify-database-backup.sh) | Isolated restore, full comparison, real permission denials and transactional identity/note probes |
| [common.sh](../scripts/recovery/common.sh) | Managed-path/privacy/checksum checks and fail-closed seven-copy retention |
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
claim. Recovering actual credentials and a whole machine remains separate work.

## Create and verify a backup

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
   publish a timestamped `backup-...` directory. Then apply seven-copy retention.

Expected final output includes:

```text
PASS: complete restored baseline, actual role denials, identity/initial-note probes; no worker started
PASS: verified database backup: .../backups/backup-<UTC timestamp>-<suffix>
Retention: latest seven verified backups; local-only, not separately encrypted.
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

## Retention and failure behaviour

- Keep the latest **seven verified backups**, not seven days. Run frequency is
  manual; data protection is only as recent as the last successful capture.
- Backup #8 must restore successfully before the oldest verified copy is removed.
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

There is no automatic restore into development, destructive rollback, credential
recovery, off-device copy, scheduler, PITR or Grafana backup here. A real incident
still needs an explicitly reviewed target/recovery plan before replacing data.

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
  of the prior good backup. Unit tests separately exercise eight-to-seven
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

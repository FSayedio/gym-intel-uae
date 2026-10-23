# One-command dashboard update and rolling-two retention

For the active Kubernetes deployment use
`sh scripts/k8s.sh update data/memberships.csv`. The lifecycle below is shared;
that entrypoint selects Kubernetes transport and its separate private backup/
report directory. Bare Compose commands operate on the retained Compose copy,
not the live Kubernetes data. See [the Kubernetes guide](kubernetes.md).

## Outcome and entrypoint

The product shows current recorded offers, not a price-history product.
Before: import submission, job verification, backups and cleanup were separate.
After: an explicit operator command connects them:

```bash
sh scripts/update-dashboard.sh data/memberships-2026-10-22.csv
```

Supply your newly verified CSV; the checked-in example is not an instruction to
repeatedly import old offers. Docker Desktop, the current runtime image, configured
roles/migrations, the three-service stack and host OpenSSL must already be ready.
Rebuild the app runtime after pulling this release-code change. The command does
not silently build/recreate it or fetch any gym websites.

An optional `--directory /absolute/private/path` selects a managed backup root
under the [existing recovery restrictions](database_recovery.md). The default is
the private `Library/Application Support/Gym Intel UAE/backups` folder.

## Agreed policies

| Component | After a successful lifecycle run |
| --- | --- |
| Gym observations | Keep every row on the newest date per brand/branch/original plan; delete older dated rows and their attached notes |
| Latest conflicting/unknown evidence | Preserve it; do not choose a convenient price or fall back to an older compatible one |
| Offers omitted from the CSV | Leave their latest known facts alone; omission is not evidence of withdrawal |
| Verified backups | Keep two; verify backup 3 by isolated restore before removing backup 1 |
| Finished import jobs | Keep the two most recently finished records, across completed/cancelled/discarded states, for the import worker only |
| Waiting/running/retryable jobs | Never prune; unfinished work blocks the lifecycle |
| Other workers/queues | Never sweep them |
| Fingerprint markers | Keep small SHA/count/time receipts to prevent old files resurrecting purged observations; they contain no CSV or prices |
| Notes for retained observations | Preserve source integrity/provenance; this feature does not rewrite their note versions |
| Code changes | Git/PR history is the code changelog, not a gym-price-history feature |

Two means backup captures/finished records, not two distinct files or days. A
duplicate CSV can produce a new successful job and backup, but not duplicate or
resurrected facts. Standalone backups share the same two-copy limit.

## Sequence and evidence

Example: successive dated prices are 199, 219, then 229. After update 3 completes,
the current database retains only the newest date for that offer, plus two
verified backups and two finished import-job records.

1. Validate the direct `data/` path/private root and acquire a cooperative update
   lock. Existing/stale update or backup locks and unfinished jobs stop the run.
2. A short-lived release process reads a bounded nonempty CSV, queues its exact
   contents, and waits up to five minutes for that job. It has no worker/plugin/
   peer. Require `completed` plus matching committed fingerprint/input-row count.
3. End the operator process before backup. Record a private SHA of observations,
   notes, import markers and jobs; never print their actual contents.
4. Execute the real [backup/restore verification](database_recovery.md). Briefly
   pause/resume only the app, verify the full restored baseline and real role
   restrictions, publish the good copy and retain the latest two. PostgreSQL and
   Grafana stay running.
5. Validate the exact published-backup receipt/checksums and match its four complete
   protected-table hashes to the prepared state. In one owner transaction,
   acquire bounded table locks, refuse unfinished jobs or changed protected state,
   require the exact completed job/CSV evidence, then delete superseded rows/their
   notes and excess terminal import jobs. Any SQL failure rolls back DB cleanup.
6. Print deletion counts and final success. Grafana rereads its existing read-only
   queries every 30 seconds while open; manual refresh also works. No panel layout,
   price calculation or source collection changes.

Expected output includes a verified job ID/fingerprint, restore verification,
cleanup counts, then `PASS: import committed, backup restored and verified`.
An intermediate PASS line is not overall success; check the final exit status.
The overall PASS now follows housekeeping and private report finalization. Read
[saved update status](update_status.md) with `sh scripts/update-status.sh` after
closing the terminal. It retains two finished summaries and protects active work;
unknown outcomes remain unknown rather than being labelled rolled back.

## Failure, privacy and concurrency boundaries

- Invalid/empty input: no job, backup or cleanup. Timeout: no backup/cleanup, but
  the job may still run. Inspect safe job state before retrying; timeout is not
  cancellation and a failed command does not undo an already committed import.
- Failed backup/restore: old verified backups and live observations/jobs remain.
  The reported phase is `backup-verification`. Retry identical bytes after fixing
  the cause; dedupe prevents reinsertion and a good backup permits cleanup.
- A concurrent protected-data write causes DB cleanup refusal. A verified backup
  may already have been published and backup retention applied; SQL rollback does
  not undo those separate filesystem actions.
- Do not run low-level imports, migrations, grant changes or privileged manual
  writes concurrently. Locks coordinate these operator commands, not arbitrary
  clients. State fingerprints/transaction locks guard deletion; this is not a
  multi-operator/distributed maintenance system or a throughput guarantee.
- Runtime/Grafana still cannot delete observations. Session-local owner helpers
  install no permanent function, migration or broader privilege.
- Terminal cleanup removes CSV arguments/error payloads and may expire cancelled/
  discarded diagnostics. Inspect failures before a successful update. Old job IDs
  may disappear; fingerprint receipts are durable import evidence, not full jobs.
- Retained full backups can still contain older prices/jobs/CSV/error contents.
  Live cleanup is not immediate erasure from backups, Git, original input or logs.
  Source CSVs tracked in Git keep their normal Git history; no history rewrite.
- Tiny fingerprint receipts and note provenance for retained facts are integrity
  metadata, not a historical-price dataset. Failed private `.pending-...` backups
  remain diagnostic attempts, not verified copies; existing recovery rules apply.
- Fatal host/Docker/SIGKILL failures can leave locks or a paused app. Traps are
  best-effort. No scheduled fetching/backups, off-device protection, restore-over-
  live procedure, separate encryption or monitoring is supplied by this feature.
- Latest recorded is not a live quote. Withdrawn/renamed-plan inference, freshness
  expiry, automatic sources and marketing-tier equivalence remain out of scope.

## Verification and rollout

Database tests cover current-date selection, conflicts/unknowns, note dependencies,
active jobs, changed-state refusal, terminal-time ordering and replay after purge.
Shell tests cover ordering and import/backup/cleanup failures and stale locks.
The real synthetic recovery rehearsal performs three packaged worker updates,
restores each backup, checks rolling-two retention, forces failed verification and
retries the identical CSV. It uses isolated services, never the real development
records/archives. Existing role-denial tests remain in force.

The low-level `import-csv.sh` is still a submit-only diagnostic tool. Use the
lifecycle command for normal updates. Merging/pulling this PR does not run data
cleanup: rebuild/recreate the app when ready, then deliberately submit verified
input. Existing development records remain until that explicit action.

# Observation identity and internal note history

## Outcome and example

Before: duplicate checking lived in the importer, required a whole-table write
lock, and treated a note correction as another membership observation.

Action: PostgreSQL generates an identity key, enforces uniqueness, and stores
internal note versions separately. The importer uses conflict-aware inserts in
one transaction, without the explicit table lock.

After: importing the same facts with `Towel inlcuded` then `Towel included`
keeps one observation ID and two internal note versions. The second new file
returns `%{inserted: 0, skipped: 1, notes_added: 1}`. Importing that exact file
again returns `:already_imported`. Changing a price, observation date, source
URL or another identity field creates a distinct observation instead.

The public graph and five-column terms table retain their selection and prices.
Raw free-text notes are no longer returned in Inspect data or accessible to the
Grafana database account. Existing structured terms and the explicit historical
Warehouse warning remain visible. This does not newly certify source accuracy,
current prices, equivalent benefits or complete cancellation conditions.

## Which component does what?

| Component | Responsibility |
| --- | --- |
| `Membership` | Original 17 CSV fields; exposes the 16 non-note identity fields. Generated keys and provenance are internal, not CSV inputs. |
| `MembershipImporter` | Validates, claims the raw file fingerprint, inserts or matches observations, adds note versions, and returns counts. |
| PostgreSQL generated columns / unique indexes | Compute and enforce observation/note identity, including writers outside the importer. |
| Initial-note trigger | Captures a new observation's non-null initial note, including direct SQL inserts. |
| Ecto transaction / Postgrex | Run the steps over the database connection. A failure rolls back that file's observations, notes and marker together. |
| Oban | Persists and executes the worker with its existing retry policy. Counts are not persisted as an Oban result report. |
| `dashboard_memberships` | Public projection of the 16 source fields, excluding notes, keys and import metadata. |
| Role setup | Runtime SELECT/INSERT on facts/history/markers; reader SELECT on the public view only; schema changes remain migrator work. |

## Two kinds of fingerprint

- File fingerprint: SHA-256 of raw CSV bytes, in `membership_imports`. BOM,
  line endings or reordering can change it without changing an observation.
- Observation key: database-generated SHA-256 of a versioned JSON array of the
  16 typed fields. Field boundaries and nulls are explicit; decimal scale is
  removed only in the key, and dates use epoch days, not session date formatting.
  `199` and `199.00` match; unknown and zero do not. No fuzzy text normalization,
  source canonicalization or inferred marketing tiers are introduced.
- Note key: SHA-256 of exact note text, unique within its observation. Repeated
  text adds no version; blank input does not erase history. A later reappearance
  of identical text is not recorded as another event in this text-version model.

On conflict, the importer checks actual typed fields or exact note text too.
A simulated hash collision must return an error, not silently skip different
facts. Keys are not proof that a source is authentic or that facts are true.
The unique index itself is a hash-identity boundary; privileged direct writers
are not given the importer's additional collision verification.

`first_import_sha256` and `membership_notes.source_import_sha256` link new
evidence to a committed file marker. They do not preserve every repeated
occurrence. Pre-upgrade provenance remains NULL rather than guessed. Original
`memberships.notes` stays the initial text; use `membership_notes` for versions.
Recorded timestamps describe collection into this database, not source dates.

## Migration and existing data

`20261023000100_enforce_observation_integrity.exs` executes the shared DDL in
`priv/observation_integrity.sql` transactionally. Upgrade tests run that exact
DDL against old-shaped tables, not a separately reimplemented migration.

Original IDs, all source fields (including notes), and timestamps remain intact.
Existing notes are copied to history. If two existing rows have the same new
identity, the migration stops and its schema changes roll back; it does not
silently choose a row or delete evidence. Investigate with a reviewed plan.

Automatic `down` deliberately raises rather than dropping note history. A failed
`up` still rolls back normally. For a deployed problem, pause imports and design
a forward fix; restoring a database backup is a separate, explicitly reviewed
recovery operation, not an automatic step. Do not start old importer code after
the new append-only grants: it still expects UPDATE permission for its lock.

### Coordinated upgrade of a running older dashboard

1. Build and pass isolated tests. Confirm no pending/executing imports. Create a
   private logical backup; verify its archive, and capture original-field checksums.
2. Stop only the app. Keep PostgreSQL and Grafana running. Apply the migration
   with the migrator credential in a short-lived container, before refreshing
   grants. Its transition grant permits both old and new dashboard queries.
3. Verify original fields/IDs/timestamps and file markers are unchanged, keys are
   unique, and old non-null notes were copied exactly.
4. Install the new dashboard JSON and verify Grafana has loaded both queries
   against `dashboard_memberships`, with no raw notes in either result.
5. Run role setup to revoke reader access to base tables and runtime UPDATE.
   Start the rebuilt app and run actual authenticated permission probes.
6. Verify expected graph values, queries, source links, terms and row counts.
   Rerun the standard isolated CI checks before staging/review.

For a new stack, the normal build → PostgreSQL → configure roles →
`scripts/migrate.sh` → full stack sequence remains valid. That migration wrapper
also refreshes grants after applying migrations. The special ordering above
avoids breaking an already-running dashboard during the transition.

## Evidence and limits

Tests cover all 16 identity fields, numeric equivalence, unknown vs zero, session
date settings, direct SQL duplicate/key-override rejection, initial notes,
note-only changes, repeated notes, collision failures, whole-file rollback,
preserved old rows, migration collision rollback, role grants/denials, and
unchanged public query selection. Concurrency tests hold a transaction open and
observe the second connection waiting; another unrelated writer must finish
before the held transaction is released. They use independent connections and
scoped cleanup only in `gym_intel_test`.

Unique-index locking still exists; removing the table-wide lock is not a claim
of lock-free or unlimited-throughput imports. One Oban import runs at a time per
configured queue instance. Unexpected database errors can still retry. Owners,
migrators and anyone controlling Docker remain privileged. SQL callers bypassing
the changeset can still bypass application-only validation. No backups service,
job receipts UI, secret pruning, new observations or dependency upgrades are
included in this feature.

Design references: PostgreSQL 18 documentation for
[generated columns](https://www.postgresql.org/docs/18/ddl-generated-columns.html),
[conflict-aware inserts](https://www.postgresql.org/docs/18/sql-insert.html), and
[view privileges](https://www.postgresql.org/docs/18/sql-createview.html).

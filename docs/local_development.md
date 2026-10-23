# Local development

The MVP foundation runs exactly three Docker services:

- `app`: an Elixir application that connects through Ecto and starts Oban.
- `postgres`: the local database for membership data and Oban jobs.
- `grafana`: the local dashboard service.

All three images support the Mac's ARM64 architecture. PostgreSQL and Grafana bind only to `127.0.0.1`, so they are not exposed to the local network. Grafana permits anonymous Viewer access and requires an administrator login for administration. PostgreSQL requires SCRAM passwords for socket and network connections. The running app uses a limited account; migrations run separately with their own credentials.

## Runtime image and optional host ports

The default app image is a packaged Elixir release, `gym-intel-runtime:local`,
running as UID/GID `10001`. It bundles the Erlang runtime and required libraries,
but not the Mix/Hex/Rebar build tools or full application source tree. Migrations
and their SQL resources remain packaged under the application's `priv` directory.
The digest-pinned matching Alpine 3.24.3 runtime is built separately from the
tool-filled `checks` target. Local app images are built locally, not pulled from or published to a
registry. Changing code requires rebuilding; there is no live source-code mount.
App shutdown allows 20 seconds to cover Oban's 15-second grace period. Erlang
distribution is disabled; operators use short-lived `eval` helpers, not remote
RPC. The image has an unprivileged user and root-owned application files, but is
not a fully read-only filesystem or a security boundary against Docker's owner.

By default nothing about your dashboard address changes. Optional host settings:

```text
POSTGRES_HOST_PORT=5432
GRAFANA_HOST_PORT=3000
```

Use a private ignored `.env` based on `.env.example`, or set the values for a
command. For example, `GRAFANA_HOST_PORT=3001 docker compose up -d grafana` opens
Grafana at `http://127.0.0.1:3001`. This recreates that service when its port
changes, not its data volume. Use the same setting consistently for later
Compose commands. Both bindings stay on `127.0.0.1`; container connections remain
`postgres:5432`, not the host port. These settings avoid address/port conflicts;
they do not provide redundant services or failover.

Keep the default project name `gym-intel-uae` for the existing stack. Compose's
project-name overrides select different project-scoped networks/volumes, which
can make existing data appear absent. Do not rename the project or remove volumes
as a workaround. This feature supports ARM64 Docker hosts only; an x86 build,
native macOS release or full independent-machine setup is not claimed verified.

PostgreSQL configuration/scripts are mounted as the read-only `postgres/`
directory at `/opt/gym-intel`; SQL resources use read-only `priv/` at
`/opt/gym-intel-priv`. Authentication rules are read from
`/opt/gym-intel/pg_hba.conf`. This replaces individual tracked-file binds: during
the local upgrade, a Git file replacement left two old binds pointing at deleted
files, causing grant refresh to fail even though host files existed. Directory
mounts resolve the current files by pathname. This does not change the named
database volume or solve arbitrary secret-file rotation; credentials remain
separate file mounts and may require recreation when replaced.

An existing stack needs one PostgreSQL-container recreation to apply those mount
changes. Confirm no pending jobs, pause the app, take a private database backup,
and record data checksums/volume identity first. Then run:

```bash
docker compose up -d --no-deps --force-recreate --wait postgres
sh scripts/migrate.sh
docker compose up -d --no-deps app
sh scripts/verify-permissions.sh
```

Verify the same `gym-intel-uae_postgres_data` volume and unchanged original rows
afterward. Do not use `down -v`, delete/reinitialize a volume, or silently change
the project name. A backup archive-list check is not a full restore drill.

## Local secrets and Grafana administrator login

Before starting the stack, generate a local password. These commands preserve
an existing secret and do not print its contents:

```bash
umask 077
mkdir -p .secrets
chmod 700 .secrets
for secret_name in grafana_admin_password postgres_password grafana_database_password postgres_app_password postgres_migrator_password; do
  if [ ! -e ".secrets/$secret_name" ]; then
    openssl rand -hex -out ".secrets/$secret_name" 32
  fi
  test -s ".secrets/$secret_name" || exit 1
  chmod 644 ".secrets/$secret_name"
done
```

The directory is accessible only to your host user. The file is readable by
Grafana's container user through its secret mount. `.secrets/` is excluded from
Git and the application image build. Compose file secrets are local files,
not encrypted storage or a secret-management service.

Grafana reads `/run/secrets/grafana_admin_password` when initializing a new
database. Existing Grafana volumes retain the previous administrator password.
After starting Grafana, apply the secret to the existing account with:

```bash
docker compose exec -T grafana sh -c 'grafana cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini --configOverrides cfg:default.paths.data=/var/lib/grafana admin reset-admin-password --password-from-stdin < /run/secrets/grafana_admin_password'
```

Expected: `Admin password changed successfully`. Sign in at
<http://127.0.0.1:3000/login> as `admin`, using the password from your local
secret file. Inspect that file privately; never paste its contents into logs,
issues, or PRs. If you change the password through Grafana, update the local
secret to match before applying it again.

## PostgreSQL passwords

Each account has a distinct secret file, excluded from Git:

| Account | Secret file under `.secrets/` | Purpose |
| --- | --- | --- |
| `gym_intel` | `postgres_password` | Bootstrap owner and maintenance; PostgreSQL container only |
| `gym_intel_migrator` | `postgres_migrator_password` | Schema ownership and explicit migration tasks |
| `gym_intel_app` | `postgres_app_password` | Running app, imports, and Oban |
| `gym_intel_grafana` | `grafana_database_password` | SELECT on public dashboard view only |

Elixir reads `DATABASE_PASSWORD_FILE` at startup. The running app receives only
its runtime secret. `scripts/migrate.sh` mounts the migrator secret into a
short-lived container; it is absent from the running app. Grafana receives only
the reader secret and its separate UI administrator secret.

The mounted `postgres/pg_hba.conf` enforces SCRAM for both socket and network
connections, including existing volumes. `POSTGRES_PASSWORD_FILE` sets the
initial owner password only when the PostgreSQL data directory is empty.
Changing that setting does not reset an existing account's password.

For an existing trust-authenticated volume, set the account passwords before
recreating the services with the new connection rules. Preserve existing data
and take a database backup first. With the old trust rules still running:

```bash
for database_role in gym_intel gym_intel_grafana; do
  case "$database_role" in
    gym_intel) secret_file=.secrets/postgres_password ;;
    gym_intel_grafana) secret_file=.secrets/grafana_database_password ;;
  esac
  { cat "$secret_file"; cat "$secret_file"; } |
    docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 \
      -U gym_intel -d gym_intel_dev -c "\\password $database_role" || exit 1
done
```

Both legacy roles must already exist for that upgrade command. Then follow
the startup sequence below to apply SCRAM rules and the new role separation.
For a new volume, skip that legacy password-reset command and use the normal
startup sequence. Once SCRAM is active, run
maintenance queries with the helper that reads the owner password privately:

```bash
docker compose exec -T postgres sh /opt/gym-intel/psql.sh -c 'SELECT current_user;'
```

Expected: `gym_intel`. A direct `psql --no-password` connection with no supplied
credentials must fail. Never set `PGPASSWORD` to a literal password in a command
or print the environment. Keep the secret files in sync with any password changes.

## Start and verify

```bash
docker compose build app
docker compose up -d --wait postgres
docker compose exec -T postgres sh /opt/gym-intel/configure-roles.sh
sh scripts/migrate.sh
docker compose up -d --wait
docker compose ps
docker compose exec -T postgres sh /opt/gym-intel/role-psql.sh gym_intel_app -c 'SELECT version FROM public.schema_migrations ORDER BY version;'
curl http://127.0.0.1:3000/api/health
```

Run this after generating all five secret files above. The role setup creates
the accounts, transfers existing development tables to the migrator, and applies
explicit runtime grants. It is safe to rerun with the same secret files. It is
guarded to `gym_intel_dev`, so it does not transfer ownership of test databases.

`scripts/migrate.sh` now invokes `bin/gym_intel eval 'GymIntel.Release.migrate()'`
in a short-lived runtime container, then refreshes grants. It prints the number
of newly applied migrations (zero means none pending). It does not create the
database and is not run automatically on app startup. Failures exit nonzero;
fix the cause rather than resetting data. Runtime migrations use Ecto's packaged
migration files without requiring Mix. Existing one-off `app mix ...` commands
no longer work in the runtime image; use the operator helpers or checks target.

The running app never applies migrations on boot. `scripts/migrate.sh` runs
pending migrations as `gym_intel_migrator` and reapplies grants afterwards.
Ecto records versions already applied, so rerunning is safe. Use this same
command after rebuilding an image that adds migrations, before restarting the
app. Add explicit grants to `priv/database_roles.sql` when adding new tables.

Expected evidence:

- `docker compose ps` lists exactly three running services.
- The read-only migration query lists versions `20260912000100`, `20260912000200`, `20260912000300`, `20261022000100`, and `20261022000200`; the corresponding files are the three original migrations, payment/renewal and VAT/admin extensions.
- Grafana's health endpoint reports that its database is OK.

Open Grafana at <http://127.0.0.1:3000>.

Use the read-only version query above for runtime verification. `mix ecto.migrations`
also attempts migration-table DDL and is denied by the restricted runtime account;
do not grant schema CREATE permission just to make that listing command succeed.
Migration execution belongs in `scripts/migrate.sh` with the migrator credential.

If a container reports that a mounted helper is missing after a Git checkout
or pull, refresh the file mounts by recreating the containers:

```bash
docker compose up -d --force-recreate --wait
```

This preserves named volumes. During the dashboard-correctness work, configured
helper mounts became unavailable after checkout; recreation restored them and
the authenticated database health check. Application-code or migration changes
still require the build and migration steps above.

## Connect Grafana to memberships

The startup sequence above configures the reader. To reapply its grants and
password and reload the provisioned data source later:

```bash
docker compose exec -T postgres sh /opt/gym-intel/configure-roles.sh
docker compose up -d --force-recreate grafana
curl --fail http://127.0.0.1:3000/api/datasources/uid/gym-intel-memberships/health
```

Expected: the health response reports a successful database connection. This is
different from `/api/health`, which checks Grafana itself, not our memberships
connection. In Grafana, Connections > Data sources lists Gym Intel Memberships.

The YAML uses `postgres:5432` because Grafana connects across the Compose network,
not through the host port. The dedicated `gym_intel_grafana` login is granted only
SELECT on `dashboard_memberships`, not the underlying memberships, internal notes,
import fingerprints or Oban job contents. The setup
script also sets the reader's SCRAM password from its mounted secret. Anonymous
visitors cannot create data sources. Administrators can configure connections,
but PostgreSQL requires a valid password for the requested database role.
After recreating a database volume, follow the full startup sequence.

## Verify role permissions

```bash
sh scripts/verify-permissions.sh
```

Expected: every forbidden action reports PASS, and the migrator can change a
temporary probe table in a transaction that rolls back. The script connects as
the actual role over SCRAM; it does not impersonate roles through a superuser
session. It also verifies that owner/migrator secret files are absent from the
running app.

Runtime grants are deliberately explicit: SELECT/INSERT on memberships, internal
note versions and import fingerprints; SELECT/INSERT/UPDATE/DELETE on Oban jobs
and peers; SELECT on migration versions; and access to the required sequences.
Database uniqueness replaces the importer's former whole-table lock, so runtime
UPDATE on memberships is no longer needed or granted. Runtime cannot update or
delete observations/note versions, change tables, create
roles, modify migration versions, or assume the owner/migrator identity.

The bootstrap owner remains a superuser in the PostgreSQL container for local
maintenance. Anyone controlling Docker or reading the private owner secret can
administer the database; these roles are not a boundary against the machine's
owner. Grafana's reader cannot read the base memberships/notes tables, write
the public view, or read import/Oban payloads.

## Membership dashboard

Open <http://127.0.0.1:3000/d/gym-intel-offers>. The dashboard JSON and provider
YAML live under `grafana/`; Compose mounts them read-only. Edit these files in
Git rather than saving dashboard changes through the UI. Grafana polls dashboard
files every 30 seconds. This does not fetch new gym facts or automatically import
CSV changes. Use the dashboard Refresh button after an import.

The current dashboard is one vertical bar chart, a compact conditions table
directly below it, and a short visible evidence warning. There are no filter
variables. Gym names are shown in a right-hand colour-coded legend rather
than below the bars. A Rows to fields transformation turns offer rows into named
series while preserving source/date/terms as labels; Concatenate fields adds a
visually blank category from a display-only query (`chr(8203)`, a zero-width
text marker). This avoids Grafana substituting a missing-value message or
coercing whitespace to 0. It does not create or import data.
With both `data/memberships.csv` and
`data/memberships-2026-10-22.csv` imported, expect four bars: GymNation 209,
La Maison de la Masse 1,500, PureGym 199 and Warehouse 363 AED/month.
Warehouse's September check date is retained in metadata, not its legend name; its audited access scope
remains unresolved. Other displayed records are dated 22 October. None is a
live quote or an equivalent-benefits / total-cost comparison.

Each brand/branch/original-plan identity uses its latest recorded observation.
There is no fixed three-gym selection. A newer unknown price, non-monthly
billing, incompatible access or conflicting terms suppresses that offer rather
than substituting an older price. Duplicate corroborating evidence yields one
bar. Dates can differ and remain available from the bars' source details.

The five table columns are Gym, Branch, Minimum commitment, Joining / admin
fees, and Payment / renewal / VAT. Each combined cell labels its individual
facts; joining and admin fees are never merged into one amount. Unknown stays
Unknown, distinct from a documented zero. Membership VAT does not establish
the tax treatment of fees. For example, GymNation's 209 bar has a 12-month
minimum, AED 199 joining and AED 30 admin; PureGym's 199 bar has no minimum,
AED 89 joining and an unknown admin fee. The bars are not payable totals.

The table repeats the graph's exact selection CTEs, eligibility and ordering;
tests guard against drift for latest, unknown, conflicting and duplicate records.
It is not the old all-history evidence table. Click a bar or a linked gym name
for its official source and check date. Original-plan and primary-source metadata
remain in Inspect data; internal free-text notes and note history do not. The
reader cannot access them through SQL either. Stored evidence remains internal.
Bars and table remain alphabetical,
not a cheapest or best-gym ranking. The visible warning discloses differing dates
and terms and Warehouse's unresolved historical access scope.

The observation-integrity update requires its migration, role refresh and app
rebuild. For an existing running dashboard, follow the coordinated upgrade in
[Observation integrity](observation_integrity.md) before changing its queries.
Current CSVs still use the 17-column contract; historical 13-/15-column snapshots
remain accepted. Source-verification requirements are unchanged.
See `docs/data_contract.md` for the current graph rules and source limitations.

## Queue a membership CSV

Input rules are described in [Input and CSV hardening](data_contract.md#input-and-csv-hardening).
The enqueue function now reads at most 1,000,001 bytes and rejects oversized,
invalid-encoding or invalid-row input before creating a job. It preserves the
original accepted bytes in the snapshot. The worker validates again when it
runs; jobs manually inserted through Oban or queued under older rules may be
cancelled if their snapshot fails today's validation rules.

For example, `199.50` is accepted as a price, but `199.999` and `2e2` return a
record/field error rather than being rounded or reinterpreted. A leading UTF-8
BOM and completely empty trailing records are accepted; missing columns and
blank records between offers are still errors. Observation dates use the UAE
day (UTC+4), and a known source publication date must not follow observation.

The project `data` directory is mounted read-only at `/app/data`. Collect and
verify official source facts manually before adding rows; there is no scraper,
gym API integration, or automatic schedule. The original CSV contains three
observations from 12 September 2026; the separate dated October CSV adds three
fresh observations, including one new brand. See `docs/data_contract.md`
and each row's notes for unresolved terms; these are not verified all-in costs.

After rebuilding the app with the command above, enqueue the file:

```bash
sh scripts/import-csv.sh data/memberships.csv
```

Expected: `Queued import job <id>; check job state for completion.` The wrapper
accepts one existing path under `data/`, rejects traversal components, and passes
the container path as an environment value rather than interpolating it into
Elixir code. Invalid/unreadable input exits nonzero without logging raw CSV/job
arguments. Detailed validation rules remain in the data contract/tests. The
submitting process has no queues; the running app executes the job. The job
stores the UTF-8 file contents, limited to 1,000,000 bytes, rather than a mutable
file path. These contents remain in Oban's job record; do not submit secrets.
One import executes at a time per app instance. Unexpected failures have up to
three total attempts. Invalid input at enqueue returns an error without a job;
invalid snapshots already in the queue are cancelled by the worker. No periodic
pruning is configured.

Inspect job state (enqueueing is not proof of completion):

```bash
docker compose exec -T postgres sh /opt/gym-intel/psql.sh -c \
  "SELECT id, state, queue, attempt, completed_at, errors FROM oban_jobs ORDER BY id DESC LIMIT 5;"
```

A header-only file completes without adding memberships. Valid nonempty imports
save atomically. Identical files are skipped; matching observations in different
files are skipped using the rules in `docs/data_contract.md`. A changed observation
is retained, not used to overwrite history. Worker return counts are not persisted
as an Oban result report.

## Repeatable tests

Tests use `compose.checks.yaml`, an ephemeral override of the same `app` service,
not a fourth permanent service. It selects the separate `gym-intel-checks:local`
image containing Mix, source and tests. The runtime image cannot run Mix tests.
For in-memory tests without starting the app (database tests excluded):

```bash
docker compose -f compose.yaml -f compose.checks.yaml build app
docker compose -f compose.yaml -f compose.checks.yaml run --rm --no-deps \
  -v "$PWD/test:/app/test" app mix test --no-start
```

Run the full suite against the separate test database, never development data:

```bash
sh scripts/test-database.sh
```

That script mounts owner credentials only in a temporary test container because
the existing suite creates its database and changes constraints. It hardcodes
`gym_intel_test`; development ownership and runtime grants are not changed.
It builds the checks target from the current checkout before running it, rather
than accidentally testing an older runtime image.
Database tests refuse any other database name. Synthetic rows and test jobs use
sandbox transactions and are rolled back after each test. The concurrency tests
need independent committed connections; they use uniquely named synthetic rows
and explicit scoped cleanup, still only in `gym_intel_test`. The test database and
its migrated tables remain for later runs. Tests cover validation, CSV parsing,
atomic saves, duplicate handling, enqueueing, and worker execution through Oban's
test helper. Dashboard regression tests execute the actual graph/table SQL loaded
from the read-only mounted dashboard JSON. They verify latest-observation
selection, conflicting terms, unknown-versus-zero handling, and graph/table
agreement. Their synthetic observations are confined to sandbox transactions in
the test database. A live queue smoke check is separate from those tests.

## Automatic PR checks

See [CI and manual review governance](ci.md) for the workflow, its isolated
PostgreSQL test service, shared check script, and actual completion criteria.
The workflow validates default/alternate Compose ports, builds both ARM64 image
targets, checks formatting/compilation, applies fresh migrations, runs all tests,
and independently verifies live jobs using the final runtime image. It does not
connect to this laptop or import development data. It uses the account's Actions
minutes; no upgrade or spending-setting change is made.

`sh scripts/test-database.sh --ci` builds the checks image and runs the shared
locked-dependency / formatting / compile / migration / test checks locally against
`gym_intel_test`. The no-argument test command remains available. Local tests may
reuse the test database; GitHub's job applies migrations to a fresh database.

## Verify the finished runtime package

After starting PostgreSQL and building both images:

```bash
docker compose build app
sh scripts/test-database.sh --ci
sh scripts/verify-compose.sh
sh scripts/verify-release.sh
```

`verify-compose.sh` renders and checks both port configurations without changing
running services. `verify-release.sh` uses the final runtime image, not the
checks image, for all application operations. It creates a uniquely named
`gym_intel_release_test_<run>` database and separate temporary migrator/runtime
accounts on the existing PostgreSQL server. It refuses to reuse development as
its test database; names are generated internally. Only the short-lived psql
client receives owner credentials; runtime workers receive only their temporary
runtime credential. It checks non-root execution, no Mix CLI, missing-secret
failure, all packaged migrations (including external SQL), invalid-input
rejection, real supervised Oban execution, duplicate-file handling, exact
synthetic facts and graceful shutdown. The fixture is not official gym data.

Expected: two completed jobs, one observation, one note and one fingerprint,
followed by a PASS line and successful cleanup. The test removes only its own
temporary worker/database/accounts/files; this is not recoverable test evidence
storage. Development rows and named volumes are never reset or deleted. A
failed check exits nonzero. If cleanup fails, investigate the reported resource
instead of issuing a broad database/volume deletion. Normal three-service setup
remains unchanged after the check.

For CI, `RELEASE_IMAGE` selects the built runtime tag;
`RELEASE_TEST_OWNER_PASSWORD_FILE`, `RELEASE_TEST_NETWORK=host` and
`RELEASE_TEST_HOST=127.0.0.1` point only at the disposable CI PostgreSQL service.
Local defaults use the current Compose PostgreSQL network and private owner
password file. A host Docker operator remains privileged; this is not production
deployment, a universal portability guarantee or a backup/restore test.

Our merge rule is manual: inspect a successful check for the latest reviewed
commit before merging. The private repository does not have an enforced required
check or required-review rule configured. A green older commit, missing run,
cancelled job or skipped check is not a substitute. The assistant never merges.

## Stop

```bash
docker compose down
```

This stops the containers but preserves the named PostgreSQL and Grafana volumes.
The first advertised-charge dashboard is available; broader comparison views
and reproducibility checks remain unfinished.
Source verification remains partial: unknown fees, commitments, tax treatment,
and offer type must not be presented as confirmed values.

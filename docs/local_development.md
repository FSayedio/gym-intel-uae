# Local development

The MVP foundation runs exactly three Docker services:

- `app`: an Elixir application that connects through Ecto and starts Oban.
- `postgres`: the local database for membership data and Oban jobs.
- `grafana`: the local dashboard service.

All three images support the Mac's ARM64 architecture. PostgreSQL and Grafana bind only to `127.0.0.1`, so they are not exposed to the local network. Grafana permits anonymous Viewer access and requires an administrator login for administration. PostgreSQL requires SCRAM passwords for socket and network connections. The running app uses a limited account; migrations run separately with their own credentials.

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
docker compose exec -T app mix run --no-start -e '
Application.put_env(:gym_intel, Oban,
  repo: GymIntel.Repo, queues: false, plugins: false)
{:ok, _} = Application.ensure_all_started(:gym_intel)
{:ok, job} = GymIntel.Workers.ImportMemberships.enqueue_file("/app/data/memberships.csv")
IO.puts("Queued job #{job.id}")
'
```

The submitting process has no queues; the running app executes the job. The job
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

Rebuild the image after code or dependency edits. Run in-memory tests without
starting the application (database-tagged tests are excluded):

```bash
docker compose run --rm --no-deps -e MIX_ENV=test \
  -v "$PWD/test:/app/test" app mix test --no-start
```

Run the full suite against the separate test database, never development data:

```bash
sh scripts/test-database.sh
```

That script mounts owner credentials only in a temporary test container because
the existing suite creates its database and changes constraints. It hardcodes
`gym_intel_test`; development ownership and runtime grants are not changed.
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
The workflow validates Compose, builds the ARM64 app image, checks formatting and
compilation, applies fresh migrations, and runs all tests on GitHub. It does not
connect to this laptop or import development data. It uses the account's Actions
minutes; no upgrade or spending-setting change is made.

After rebuilding the app image, `sh scripts/test-database.sh --ci` runs the shared
locked-dependency / formatting / compile / migration / test checks locally against
`gym_intel_test`. The no-argument test command remains available. Local tests may
reuse the test database; GitHub's job applies migrations to a fresh database.

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

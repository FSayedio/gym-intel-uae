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
| `gym_intel_grafana` | `grafana_database_password` | SELECT on memberships |

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
SELECT on memberships, not write access or access to Oban job contents. The setup
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

Runtime grants are deliberately explicit: SELECT/INSERT/UPDATE on memberships;
SELECT/INSERT on import fingerprints; SELECT/INSERT/UPDATE/DELETE on Oban jobs
and peers; SELECT on migration versions; and access to the required sequences.
UPDATE on memberships currently permits the importer's SHARE ROW EXCLUSIVE
table lock. Remove that extra grant when the planned database uniqueness change
replaces the lock. Runtime cannot delete memberships, change tables, create
roles, modify migration versions, or assume the owner/migrator identity.

The bootstrap owner remains a superuser in the PostgreSQL container for local
maintenance. Anyone controlling Docker or reading the private owner secret can
administer the database; these roles are not a boundary against the machine's
owner. Grafana's reader cannot write memberships or read import/Oban payloads.

## Membership dashboard

Open <http://127.0.0.1:3000/d/gym-intel-offers>. The dashboard JSON and provider
YAML live under `grafana/`; Compose mounts them read-only. Edit these files in
Git rather than saving dashboard changes through the UI. Grafana polls dashboard
files every 30 seconds. This does not fetch new gym facts or automatically import
CSV changes. Use the dashboard Refresh button after an import.

Expected after importing the initial CSV: three overview bars (GymNation 209,
PureGym 199, Warehouse 363 AED/month) and three evidence-history rows dated
2026-09-12. Original plan names remain unchanged; readable access, payment-period
and commitment labels interpret the existing fields. Payment structure and
renewal are separate evidence columns. Membership-price VAT and one-time admin
fees have their own columns, separate from joining fees. The additive migrations leave these
NULL on historical observations; it does not infer facts or backfill gym terms.
Blank commitments, classifications and joining fees display Unknown, not zero.
Prices come from SQL, not hardcoded
panel values. There is no automatic marketing-name-to-tier classifier.

The chart selects the newest date with known monthly single-branch prices for
all three offers explicitly listed in `docs/data_contract.md`. It preserves the
previous complete set when a newer collection is partial or incompatible. A
conflicting price for a selected offer prevents that date from qualifying.
The query returns `Observed` alongside its numeric values. No complete date
produces No data; dates are never mixed within the chart.

The filtered chart uses the same overview date, fixes access to Single branch
for the current selected set, and offers minimum-commitment, payment-structure
renewal-policy and membership-price VAT selectors. At least two distinct gym brands must match access,
monthly billing, known commitment, known payment structure, known renewal and known price VAT basis;
unknown or conflicting terms exclude an offer. With the existing records, both No
minimum commitment and 3 months produce **Not enough comparable offers** and no
filtered bars. That result is intentional, not a connection failure. Filters
do not affect the overview or evidence history. User values are interpolated
using Grafana's SQL-string quoting, not inserted as raw SQL.

Current CSV headers have 17 columns, appending `payment_structure`,
`renewal_policy`, `price_vat_status` and `admin_fee_aed` after `notes`.
Historical 13- and 15-column files and queued snapshots still parse with their
missing fields unknown; the checked-in original observations
are deliberately unchanged. Rebuild the app and run `sh scripts/migrate.sh`
before loading the updated provisioned dashboard SQL. This nullable-column
migration preserves existing rows and source values. A newly sourced prepaid
term must not be grouped with recurring payments merely because both cover a
month; neither classification determines its automatic-renewal policy.

The VAT selector contains only VAT included / VAT excluded. Unknown or conflicting
membership-price VAT does not qualify. The filtered chart title states its VAT
basis; an excluded-VAT chart shows pre-VAT source charges, not amounts payable.
No tax rate is assumed or applied. Historical overview amounts are not converted
and may have unknown or differing tax treatment, which is explicitly warned.
The VAT flag does not establish how separate fees are taxed. No joining fee does
not imply no admin fee; no total-cost or first-payment calculation is implemented.
Other mandatory charges and their timing remain outside this two-field extension.

The evidence table includes all recorded observations and dates, including
unknown prices and annual offers. Its numeric price is the native advertised
amount, with Payment covers identifying the period; an annual price must not
be mislabelled monthly. The hidden time picker does not filter these panels.

This is an advertised-charge overview, not an all-in-cost or value ranking.
Even the filtered charge chart matches only the named dimensions: fees, tax
treatment, offer type and facilities may differ. Read the warning and source
notes; do not infer that alphabetically ordered bars are equivalent memberships.
The source audit in `docs/data_contract.md` is not imported data. It identifies
unresolved Warehouse scope and mandatory-fee modelling gaps; no current purchase
quote or all-in-cost calculation is claimed.

## Queue a membership CSV

The project `data` directory is mounted read-only at `/app/data`. Collect and
verify official source facts manually before adding rows; there is no scraper,
gym API integration, or automatic schedule. The current CSV contains three
official-source observations from 12 September 2026. See `docs/data_contract.md`
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
three total attempts; invalid input cancels. No periodic pruning is configured.

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
sandbox transactions and are rolled back after each test. The test database and
its migrated tables remain for later runs. Tests cover validation, CSV parsing,
atomic saves, duplicate handling, enqueueing, and worker execution through Oban's
test helper. Dashboard regression tests execute actual panel and variable SQL
loaded from the read-only mounted dashboard JSON. They mirror Grafana's
`sqlstring` quoting for access, commitment, payment, renewal and VAT selections and check that unknown or
conflicting conditions cannot qualify. Their synthetic observations are confined
to sandbox transactions in the test database. A live queue smoke check is
separate from those tests. No CI is set up.

## Stop

```bash
docker compose down
```

This stops the containers but preserves the named PostgreSQL and Grafana volumes.
The first advertised-charge dashboard is available; broader comparison views
and reproducibility checks remain unfinished.
Source verification remains partial: unknown fees, commitments, tax treatment,
and offer type must not be presented as confirmed values.

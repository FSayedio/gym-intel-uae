# Local development

The MVP foundation runs exactly three Docker services:

- `app`: an Elixir application that connects through Ecto and starts Oban.
- `postgres`: the local database for membership data and Oban jobs.
- `grafana`: the local dashboard service.

All three images support the Mac's ARM64 architecture. PostgreSQL and Grafana bind only to `127.0.0.1`, so they are not exposed to the local network. Authentication is deliberately disabled for this local-only foundation and must be replaced before any non-local deployment.

## Start and verify

```bash
docker compose up --build --wait
docker compose ps
docker compose exec --no-TTY app mix ecto.migrations
curl http://127.0.0.1:3000/api/health
```

The app applies pending Ecto migrations before it starts. Running the same
migrations again is safe because Ecto records which versions are already up.

Expected evidence:

- `docker compose ps` lists exactly three running services.
- Ecto lists `create_memberships`, `add_oban_jobs`, and `create_membership_imports` as `up`.
- Grafana's health endpoint reports that its database is OK.

Open Grafana at <http://127.0.0.1:3000>.

## Connect Grafana to memberships

After starting the stack and applying migrations, grant a dedicated local reader
access to the memberships table and load the version-controlled data source:

```bash
docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U gym_intel -d gym_intel_dev < priv/grafana_reader.sql
docker compose up -d grafana
curl --fail http://127.0.0.1:3000/api/datasources/uid/gym-intel-memberships/health
```

Expected: the health response reports a successful database connection. This is
different from `/api/health`, which checks Grafana itself, not our memberships
connection. In Grafana, Connections > Data sources lists Gym Intel Memberships.

The YAML uses `postgres:5432` because Grafana connects across the Compose network,
not through the host port. The dedicated `gym_intel_grafana` login is granted only
SELECT on memberships, not write access or access to Oban job contents. It uses
the existing local trust authentication; this is not a production security setup.
Anonymous Grafana Admin and PostgreSQL trust authentication remain limitations.
After recreating the database volume, repeat reader setup after migrations.

## Membership dashboard

Open <http://127.0.0.1:3000/d/gym-intel-offers>. The dashboard JSON and provider
YAML live under `grafana/`; Compose mounts them read-only. Edit these files in
Git rather than saving dashboard changes through the UI. Grafana polls dashboard
files every 30 seconds. This does not fetch new gym facts or automatically import
CSV changes. Use the dashboard Refresh button after an import.

Expected after importing the initial CSV: three bars (GymNation 209, PureGym 199,
Warehouse 363 AED/month) and three terms/source rows dated 2026-09-12. Blank
commitments and joining fees display Unknown, not zero. Prices come from SQL,
not hardcoded panel values.

Both panels select the latest observation date across memberships, then include
only single-branch offers with monthly billing and a known advertised price.
They ignore the Grafana time picker, which is hidden. Different dates are never
mixed; an incomplete latest collection can reduce the number of displayed gyms.
No eligible observations produces No data. Other billing periods, access scopes,
and unknown prices are deliberately excluded from this first view.

This is an advertised-charge overview, not an all-in-cost or value ranking.
Terms, tax treatment, offer type and facilities may differ. Read the warning and
source notes; do not infer that alphabetically ordered bars are equivalent offers.

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
docker compose exec -T postgres psql -U gym_intel -d gym_intel_dev -c \
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
docker compose run --rm --no-deps -e MIX_ENV=test \
  -e DATABASE_NAME=gym_intel_test -e RUN_DB_TESTS=true \
  -v "$PWD/test:/app/test" \
  app sh -c 'mix ecto.create && mix ecto.migrate && mix test --no-start'
```

Database tests refuse any other database name. Synthetic rows and test jobs use
sandbox transactions and are rolled back after each test. The test database and
its migrated tables remain for later runs. Tests cover validation, CSV parsing,
atomic saves, duplicate handling, enqueueing, and worker execution through Oban's
test helper. A live queue smoke check is separate from those tests. No CI is set up.

## Stop

```bash
docker compose down
```

This stops the containers but preserves the named PostgreSQL and Grafana volumes.
The first advertised-charge dashboard is available; broader comparison views
and reproducibility checks remain unfinished.
Source verification remains partial: unknown fees, commitments, tax treatment,
and offer type must not be presented as confirmed values.

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
- Ecto lists `create_memberships` and `add_oban_jobs` as `up`.
- Grafana's health endpoint reports that its database is OK.

Open Grafana at <http://127.0.0.1:3000>.

## Stop

```bash
docker compose down
```

This stops the containers but preserves the named PostgreSQL and Grafana volumes. Importing CSV data, provisioning a PostgreSQL data source, and creating dashboards are deliberately outside this persistence step.

# Local development

The MVP foundation runs exactly three Docker services:

- `app`: a minimal Elixir application that confirms PostgreSQL is reachable.
- `postgres`: the local database that later stores imported gym data and Oban jobs.
- `grafana`: the local dashboard service.

All three images support the Mac's ARM64 architecture. PostgreSQL and Grafana bind only to `127.0.0.1`, so they are not exposed to the local network. Authentication is deliberately disabled for this local-only foundation and must be replaced before any non-local deployment.

## Start and verify

```bash
docker compose up --build --wait
docker compose ps
docker compose logs app
curl http://127.0.0.1:3000/api/health
```

Expected evidence:

- `docker compose ps` lists exactly three running services.
- The app log contains `PostgreSQL is reachable`.
- Grafana's health endpoint reports that its database is OK.

Open Grafana at <http://127.0.0.1:3000>.

## Stop

```bash
docker compose down
```

This stops the containers but preserves the named PostgreSQL and Grafana volumes. Importing CSV data, adding Oban, provisioning a PostgreSQL data source, and creating dashboards are deliberately outside this foundation step.

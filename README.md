# Gym Intel UAE

A local UAE gym analytics project built through practical learning. It helps
people interpret official gym offers and make their own choice—not declare one
universally best gym.

Working workflow: CSV -> Elixir + Oban -> PostgreSQL -> Grafana.
Exactly three application services run locally using Docker Compose.
The app uses a non-root packaged release; build/test tooling lives in a separate
image target. Host ports are configurable without changing container endpoints.

Gym facts must include a source and observation date.
Missing information remains unknown.

Status: local pricing MVP and the seven-feature foundation/reliability milestone
delivered through [PR #15](https://github.com/FSayedio/gym-intel-uae/pull/15).
The next focused feature is [local database backup and verified restore](docs/database_recovery.md).
Finishing the seven features closed one milestone, not the project. Broader product work,
operational recovery and eventual Kubernetes deployment remain on the
[roadmap](docs/roadmap.md).

## Start here

- [Operator runbook: setup, import, verify, diagnose and stop](docs/operator_runbook.md)
- [Database backup, isolated restore verification and retention](docs/database_recovery.md)
- [Detailed local configuration and credentials](docs/local_development.md)
- [Data contract and source limitations](docs/data_contract.md)
- [CI checks and manual review policy](docs/ci.md)
- [Observation identity and internal note history](docs/observation_integrity.md)
- [Current reviewer handoff](docs/reviewer_handoff.md)
- [Roadmap, milestone status and deferred review findings](docs/roadmap.md)
- [Historical reviewer checkpoints—not current instructions](docs/reviewer_history.md)

After following first setup in the runbook, an unchanged existing stack resumes
with `docker compose up -d --wait`. The default dashboard is
<http://127.0.0.1:3000/d/gym-intel-offers>; discover a configured alternate address
with `docker compose port grafana 3000`. Starting services does not migrate or
import automatically.

With the two checked-in CSV snapshots imported: six historical observations,
four brands, one vertical advertised-charge graph and a compact conditions table.
There are no filters. Dates and terms differ; Warehouse's historical access scope
is unresolved. These are not equivalent memberships, live quotes or all-in costs.

Keep this deployment local. Secrets are private file mounts, merge governance
is manual, and off-device recovery, scheduled backups, job pruning and full
clean-machine reproduction remain open. See the handoff and roadmap for evidence
and limits; local restore verification is not a full disaster-recovery service.

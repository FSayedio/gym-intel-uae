# Gym Intel UAE

A local UAE gym analytics project built through practical learning. It helps
people interpret official gym offers and make their own choice—not declare one
universally best gym.

Working workflow: CSV -> Elixir + Oban -> PostgreSQL -> Grafana.
Exactly three application services run in a local ARM64 Kubernetes (Kind) cluster.
Docker Desktop provides the container runtime; Compose remains an explicit
development/recovery alternative, not a second active pipeline.
The app uses a non-root packaged release; build/test tooling lives in a separate
image target. Host ports are configurable without changing container endpoints.

Gym facts must include a source and observation date.
Missing information remains unknown.

Status: the seven-feature foundation and subsequent operational-readiness work
are delivered through [PR #20](https://github.com/FSayedio/gym-intel-uae/pull/20).
The [Kubernetes migration](docs/kubernetes.md) adds local cluster operation while
preserving the verified update/backup/rolling-two lifecycle. Its PR and CI status
remain separate from these implementation instructions.

## Start here

- [Kubernetes setup, migration, daily commands and before/after examples](docs/kubernetes.md)
- [Compose alternative operator runbook](docs/operator_runbook.md)
- [Database backup, isolated restore verification and retention](docs/database_recovery.md)
- [One-command dashboard update and rolling-two lifecycle](docs/update_lifecycle.md)
- [Read-only update status and automatic two-report retention](docs/update_status.md)
- [Detailed local configuration and credentials](docs/local_development.md)
- [Data contract and source limitations](docs/data_contract.md)
- [CI checks and manual review policy](docs/ci.md)
- [Observation identity and internal note history](docs/observation_integrity.md)
- [Current reviewer handoff](docs/reviewer_handoff.md)
- [Roadmap, milestone status and deferred review findings](docs/roadmap.md)
- [Historical reviewer checkpoints—not current instructions](docs/reviewer_history.md)

After Kubernetes setup, resume with `sh scripts/k8s.sh start`. The dashboard is
<http://127.0.0.1:3001/d/gym-intel-offers>. Starting services does not migrate or
import automatically. Use `sh scripts/k8s.sh update data/memberships.csv` for
verified updates; do not run Compose commands against the stopped rollback copy.

With both checked-in snapshots imported before lifecycle cleanup: six observations,
four brands, one vertical advertised-charge graph and a compact conditions table.
There are no filters. Dates and terms differ; Warehouse's historical access scope
is unresolved. These are not equivalent memberships, live quotes or all-in costs.

Keep this deployment local. Secrets are private file mounts, merge governance
is manual, and off-device recovery and high availability remain outside this
local deployment. Verified updates include bounded job/backup/report cleanup;
health checks remain operator-triggered. See the handoff and roadmap for evidence
and limits; local restore verification is not a full disaster-recovery service.

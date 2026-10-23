# Gym Intel UAE

A local UAE gym analytics project built through practical learning.

Working workflow: CSV -> Elixir + Oban -> PostgreSQL -> Grafana.
Exactly three application services run locally using Docker Compose.

Gym facts must include a source and observation date.
Missing information remains unknown.

Status: local pricing MVP delivered. Recorded prices and conditions are not an
equivalent-membership or all-in-cost ranking. Broader metrics and hardening remain
on the roadmap.

- [Local setup, imports and tests](docs/local_development.md)
- [Data contract and source limitations](docs/data_contract.md)
- [CI checks and manual review policy](docs/ci.md)
- [Observation identity and internal note history](docs/observation_integrity.md)
- [Reviewer handoff](docs/reviewer_handoff.md)

# Local Kubernetes deployment and migration

This is the authorised **local ARM64 Kind migration**, not a cloud or
high-availability deployment. Docker Desktop still supplies the Linux runtime;
Kubernetes replaces Compose's coordination. Exactly three application services
remain: Elixir/Oban, PostgreSQL and Grafana. Kubernetes also needs its own
control-plane/DNS/storage infrastructure and short-lived operator/check Jobs.

## Changes, reasons and examples

| Area | Before | Action / after | Concrete example |
| --- | --- | --- | --- |
| Coordination | Compose starts three services | Kind 0.33.0, pinned Kubernetes 1.36.4 node, project-private kubeconfig | `sh scripts/k8s.sh start` starts the worker and Grafana in the managed namespace |
| Image delivery | A Docker-local tag | ARM64-only export to Kind; content-addressed app tag | A new app image is loaded before the deployment references it; no public registry upload |
| Database storage | Compose named volume | PostgreSQL StatefulSet and persistent volume claim | A replacement `postgres-0` pod reattaches the same claim instead of creating an empty database |
| Dashboard storage | Compose Grafana volume | Grafana persistent claim plus Git-provisioned configuration | Pod replacement preserves Grafana's SQLite state; chart/query definitions still come from Git |
| Data migration | Data in the old Compose database | Verified logical backup restored only into an empty paused target; exact baseline comparison | Six observations/four brands and retained jobs transfer without importing the CSV again |
| Credentials | Per-container secret files | Separate Kubernetes Secrets mounted only where needed | The runtime cannot read the owner or migrator password; Grafana gets only reader/admin credentials |
| Schema changes | One-off Compose process | Bounded migration Job, using the migrator account | `Applied migrations: 0` means the restored database already has the six migrations |
| Imports | One-off Compose process | Bounded Job receives CSV bytes through stdin into temporary storage | A 1 MB CSV is not squeezed into a ConfigMap; its pod is deleted after submission/wait |
| Update/retention | Compose-specific transport | Same update, backup verification, cleanup and status code with a Kubernetes transport | After update three, two verified backups and two finished reports/jobs remain; obsolete observations are removed |
| Recovery | Docker-only capture | Scale worker to zero, capture, restore-test separately, restore worker to one | A capture failure still attempts worker recovery; a failed archive never replaces a verified backup |
| Readiness/resources | Compose health checks | Database/Grafana probes, Repo-only app probe, bounded CPU/memory and graceful shutdown | A missing DB connection makes the app unready; the probe does not start another Oban worker |
| Runtime compatibility | Docker's file-descriptor limit | Cap app/operator/check processes at 65,536 descriptors | Kind's observed 1,073,741,816 default caused startup OOM; the cap permits the 512 MiB app limit |
| Local access | Dashboard 127.0.0.1:3000; DB host port | Dashboard loopback 127.0.0.1:3001; PostgreSQL cluster-only | The old URL stops when Compose stops; the new dashboard is `/d/gym-intel-offers` on port 3001 |
| Acceptance | Compose/source checks | Existing tests plus isolated Kubernetes migration/update/permission/PVC checks in CI | Three synthetic updates exercise real Jobs, SQL commits, backup restores and retention |
| Rollback | Existing Compose stack | Keep old containers/volumes stopped, not deleted | Before new Kubernetes writes, the old verified copy can be resumed; afterward it is stale |

## Prerequisites and scope

- ARM64 macOS or Linux, Docker running, `kubectl` compatible with Kubernetes
  1.36 (within the supported minor-version skew), `curl`, `openssl`, `shasum`.
- Five existing private files from [local credential setup](local_development.md#local-secrets-and-grafana-administrator-login).
- Port 3001 available. The Kind API and dashboard host mapping bind to loopback.
- No global kubeconfig changes, account creation, cluster cloud charges, registry
  publishing or Docker Desktop resource-setting changes.

The tested Mac's Docker VM has approximately 3.8 GiB RAM. Run heavy checks
sequentially if resource pressure appears. Limits are per process/container, not
a promise of spare capacity. Local-path PVC storage requests are not disk quotas.

## First setup: choose empty setup OR migration

Commands are run from the repository root. Stop at any failure.

```sh
sh scripts/k8s.sh bootstrap
sh scripts/k8s.sh prepare
```

`bootstrap` downloads a checksum-pinned Kind binary into ignored `.local/` and
creates the project cluster. `prepare` builds/loads images, creates scoped
Secrets/ConfigMaps and starts PostgreSQL; app and Grafana remain paused. It refuses
an already-running app before changing configuration. The namespace must carry
the project ownership label; every kubectl call explicitly names the private
kubeconfig, context and namespace.

For a genuinely new, empty database:

```sh
sh scripts/k8s.sh roles
sh scripts/k8s.sh migrate
sh scripts/k8s.sh start
```

For the existing Compose database instead:

1. Stop submitting imports/schema changes. Run `sh scripts/backup-database.sh`
   against Compose; it pauses/resumes the app and prints a verified bundle path.
2. Run `sh scripts/k8s.sh restore /absolute/path/to/verified/backup-directory`.
   It refuses a nonempty target or running app/Grafana, verifies the bundle,
   restores ownership/grants and compares the complete deterministic baseline.
   Failure leaves the target paused and the source untouched; do not bypass it.
3. Run `sh scripts/k8s.sh migrate`, then `sh scripts/k8s.sh start`.
4. Run `sh scripts/k8s.sh permissions`, `sh scripts/k8s.sh dashboard-check`,
   and compare protected-state hashes before allowing new writes.
5. Run `docker compose stop app grafana postgres`. Do **not** use `down -v`.
   The old volume is a rollback copy, not another active data source.
6. Run `sh scripts/k8s.sh backup` to create a verified Kubernetes-side backup.

The Git-provisioned dashboard is reconstructed. Untracked Grafana UI edits and
the old Grafana SQLite file are not copied. Existing admin credentials initialise
the new Grafana volume; changing a Secret later does not rotate an already-saved
Grafana password automatically.

## Everyday commands

| Command | Effect and expected evidence |
| --- | --- |
| `sh scripts/k8s.sh status` | Pods/PVCs/services plus saved update reports; reports are not a fresh health check |
| `sh scripts/k8s.sh start` | Resume one worker and Grafana; wait for readiness |
| `sh scripts/k8s.sh update data/memberships.csv` | Submit, verify exact job/commit, capture/restore-test backup, apply existing rolling-two cleanup, save status |
| `sh scripts/k8s.sh backup` | Quiescent verified capture only; does not perform observation/job cleanup |
| `sh scripts/k8s.sh permissions` | Real allowed/denied SQL probes in rolled-back transactions |
| `sh scripts/k8s.sh dashboard-check` | Actual Git-provisioned chart and table queries, reader datasource, admin login |
| `sh scripts/k8s.sh tests` | Full suite against `gym_intel_test`, not the live database |
| `sh scripts/verify-kubernetes.sh` | Disposable synthetic namespace: fresh migrations, three updates, retention, permissions and pod replacement |
| `sh scripts/k8s.sh pause` | Scale the worker to zero; PostgreSQL and Grafana remain running |

Dashboard: <http://127.0.0.1:3001/d/gym-intel-offers>.
Keep Docker Desktop running. No automatic source fetching or update schedule was
added. The low-level `import` command only queues and is not the everyday
backup/retention workflow. Do not submit concurrent imports or schema changes
during updates/backups. One app replica and one operator remain the supported model.

Kubernetes backups/reports live separately under
`~/Library/Application Support/Gym Intel UAE/kubernetes-backups`. Compose's old
backup directory is intentionally not merged or pruned during cutover. Each
active backend retains two verified backups; the explicit rollback archive is
separate. Do not mistake the retained old Compose database for current data.

## Upgrade, rollback and recovery

For an app/configuration upgrade: take a verified backup, pause the worker, run
`prepare`, `migrate`, `start`, then permission/dashboard checks. Preparation also
pauses Grafana so new mounted configuration is loaded on its next start. A failed
upgrade should be investigated against the retained backup; this script does not
silently roll back SQL or force an incompatible old image onto a new schema.

For PostgreSQL/Grafana pod replacement, delete only the identified pod, not its
PVC or namespace. Kubernetes creates a replacement using the same claim. This
is restart resilience, **not** high availability or a backup.

Before any new writes in Kubernetes, the preserved Compose copy can be resumed
after pausing Kubernetes. Once Kubernetes accepts updates, that copy is stale:
take and verify a new Kubernetes backup, restore into a separately prepared empty
target, verify the full baseline, then switch. Never overwrite a live database
or delete a volume to make a restore command pass. Namespace/cluster deletion
is deliberately not exposed as an everyday operator command.

## Limits that remain explicit

- Single local node and laptop: no failover, off-device copy or laptop-loss protection.
- Kind's local storage survives pod replacement, **not node/cluster deletion**.
- Secrets are access-scoped Kubernetes objects, not encrypted external secret
  storage. The local cluster administrator can read them. No multi-tenant
  isolation or enforced NetworkPolicy is claimed; local Kind networking alone
  does not provide those guarantees.
- Loopback access is local HTTP, not a public TLS deployment. Anonymous Viewer
  remains the approved local dashboard policy.
- Readiness does not automatically rescue abandoned Oban jobs. Existing explicit
  operator interruption-recovery rules still apply.
- Source dates, offer caveats, unknown fees and lack of live fetching are unchanged.
- Tests and CI are evidence for their recorded revision, not a claim that all
  possible crashes or migrations are safe. A PVC and a passing health endpoint
  do not prove disaster recovery.

## Local verification record — 23 October 2026

- Verified Compose archive restored into empty Kubernetes PostgreSQL; the full
  baseline (data, schema, grants, sequences, migrations and jobs) matched exactly.
- Protected-state hash stayed
  `59eea542a190807266b64bd05f17bac481425f3ef13ed926c70b32df6efc3f60`
  through cutover, tests and the final rollout. Six observations/four brands were
  preserved; no new real CSV was imported.
- Live Grafana probe verified both Git-defined panel queries returning four
  offers, the reader datasource and administrator login. Actual permission
  probes denied prohibited app/reader operations.
- `sh scripts/k8s.sh tests`: **184 passed**, dependency advisory audit passed,
  formatting and warnings-as-errors application compilation passed.
- `sh scripts/verify-kubernetes.sh`: fresh six-migration setup, three synthetic
  updates, two verified backups/reports/jobs, invalid-input rejection without
  protected-state changes, both PVC replacement checks, actual dashboard queries,
  another **184 passing tests**, and temporary-resource cleanup passed.
- Kubernetes-side capture restored successfully in isolation and resumed the
  worker. The final live pods were Ready with zero restarts and the original PVCs.
- Compose containers exited cleanly and were retained stopped; global kubectl
  contexts remained empty. The app used about 106 MiB at the sampled checkpoint
  after the descriptor-limit fix (not a load/peak-memory benchmark).

Hosted CI is a separate PR check; the local record does not claim a hosted pass.

## Primary references

The implementation follows the [Kind release and ARM64 node-image records](https://github.com/kubernetes-sigs/kind/releases/tag/v0.33.0),
[Kind local port mapping guidance](https://kind.sigs.k8s.io/docs/user/configuration/),
[Kubernetes probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
and [persistent-volume lifecycle](https://kubernetes.io/docs/concepts/storage/persistent-volumes/).

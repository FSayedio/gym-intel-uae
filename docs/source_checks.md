# Weekly official-source checks

Before: a dated membership observation could remain in the dashboard without any
automated indication that its source page had changed.

After: while the deployed application is running, Oban queues a source check
every Monday at **09:00 Asia/Dubai (05:00 UTC)**. It checks seven fixed official
routes for the four working gym brands. No new service or external account is
required. A stopped application misses that week's slot; there is no catch-up.

This checks public page text, not membership accuracy. PureGym's fixed Al Barsha
joining route is loaded in a temporary headless Firefox browser so its JavaScript
can populate both monthly plan cards. The other six routes use plain HTTP.
An old observation can
still be accurate; age alone does not prove a price changed. Equally, an unchanged
page does not prove all checkout fees, exclusions or conditions are unchanged.
The monitor never imports prices, changes `observed_on`, certifies an
offer, or changes Grafana's comparison rules. Updating gym facts still requires
reviewing the official offer and submitting a validated CSV through the existing
update workflow.

## Results and retention

| Result | Meaning | Operator action |
| --- | --- | --- |
| `baseline` | First usable page text saved; no earlier comparison exists. | Review the source and baseline. |
| `page_unchanged` | Normalized visible page text matches the previous successful fetch. | Check coverage limitations and any outstanding review flag. |
| `page_changed` | Page text differs from the previous successful fetch. | Review the excerpt and official selected offer; update CSV only for verified facts. |
| `check_failed` | A timeout, redirect, block, oversized response or missing expected context prevented comparison. | Check the official route manually; do not infer unchanged terms. |

Reports are internal PostgreSQL records. The latest two run reports are retained.
Each source keeps its latest successful text and its last manually acknowledged
text, each capped at 100 KB. Pending differences survive report rotation until
acknowledged. A failure never replaces the last successful baseline. Reports
always set `offer_verified` to false. Acknowledging a baseline only records that
the page change was reviewed; it does not verify or publish membership facts.
Historical reports remain snapshots; acknowledgements take effect in subsequent
reports, with the current accepted hash available in status immediately.

Terminal monitor jobs are trimmed on the next monitor attempt, reserving a slot
for the current job. This cleanup happens before the report transaction, so an
ordinary failed attempt cannot roll cleanup back. Pending/running/retrying jobs
and CSV import jobs are never removed by this cleanup. If PostgreSQL itself is
unavailable, cleanup waits until database access recovers. Oban tracks execution
and retries unexpected failures up to three attempts. Individual HTTP failures
are reported in a completed run rather than repeatedly hitting a blocked site.

## Kubernetes operator commands

```sh
# Read the two reports and current baseline hashes. No website requests.
./scripts/k8s.sh source-status

# Optionally queue a check now. The running application performs it.
./scripts/k8s.sh source-check

# After reviewing a specific current page, acknowledge the exact reported hash.
./scripts/k8s.sh source-ack gymnation_offer REPLACE_WITH_CURRENT_64_CHARACTER_HASH
```

Acknowledgement rejects a stale hash or an overlapping check. These short-lived
operator Jobs use the existing limited application database role. Grafana's
reader cannot read the source-check tables. No separate dashboard panel or
external notification is added. Review `source-status` to see check results.

The equivalent Compose operations use `docker compose exec -T app
bin/gym_intel eval 'GymIntel.Release.source_check_status()'` or
`GymIntel.Release.check_sources()`. Run only the chosen deployment, not Compose
and Kind as competing production pipelines.

## Scheduling and network boundaries

- `config/config.exs` defines the weekly Oban Cron entry and a one-job
  `source_checks` queue. `SOURCE_CHECKS_ENABLED=true` opts the running app in.
- The normal Compose app and `gym-intel` Kubernetes deployment enable it.
  Test/check containers, recovery containers and other Kubernetes namespaces
  default to disabled. A one-off submission process disables its own plugins
  and queues; only the long-running application performs jobs.
- `SourceMonitor.Sources` contains the fixed reviewed routes. Arbitrary submitted
  URLs, discovery/crawling, authenticated access and membership form submissions
  are absent. Plain HTTP redirects are reported for review. The browser rejects
  a result if its final URL differs from the exact pinned `center=8002` route.
- Finch verifies HTTPS certificates. Each plain HTTP fetch has a 25-second outer deadline,
  a 2 MB response cap and a 100 KB normalized-text cap. Six HTTP reads and one
  browser read fit inside a four-minute worker
  timeout. Scripts, styles, navigation and
  footers are excluded from comparison; unrelated body changes may still flag
  review. Expected context checks catch some empty/dynamic selector responses,
  but cannot establish all offer facts.
- The browser has a 60-second work deadline, bounded shutdown and a 70-second
  Elixir deadline. It waits for separate numeric monthly prices and joining fees
  on both Core and Plus cards. Missing/loading cards fail rather than producing
  an empty baseline. The visible plan page does not print the branch name;
  `center=8002` is the explicitly pinned Al Barsha route, not an inferred branch
  name from the words Core or Plus. No other centre URL is accepted.
- The rendered page's HTTP(S) requests allow only the exact `puregym-arabia.exerp.site` host.
  GET requests and the site's exact read-only anonymous plan-lookup POST are
  permitted; other methods, credentials in URLs and external origins are blocked.
  Inline image data is not treated as an outbound HTTP request. TLS validation
  and Firefox's default browser protections stay enabled. No extra Linux
  capabilities, privilege escalation or `--no-sandbox` flags are added.
  WebRTC and service workers are disabled. This HTTP(S) page interceptor
  is not a container-wide network firewall; WebSockets and browser-internal
  networking are separate boundaries. No claim of complete network isolation
  is made for live runs.
- Firefox, geckodriver, Node and Tini are packaged in the existing runtime image;
  there is no fourth service or npm dependency. This increases image size.
  Browser profiles are per-run under `/tmp`; normal completion, timeout and
  loss of the parent process close the browser process group and remove the
  profile. Tini reaps orphaned processes. The app's 512 MiB/one CPU/64 MiB temporary
  storage limits remain unchanged; a resource failure is not a verified result.
  The browser uses multiple processes and threads. If an operator adds a PID
  limit, allow at least the tested 512; a 256-task test limit prevented startup
  alongside the Elixir runtime. This is a tested allowance, not a guarantee for
  every future browser version or page.
- Source pages are untrusted evidence. PureGym's JavaScript executes inside the
  browser with its protections enabled. Returned text is stored as data and
  printed as JSON; the importer never executes that text or treats it as instructions.

Backups already snapshot all public tables, including these new tables. Existing
backup/update guards reject unfinished Oban jobs. If a check overlaps an operator
update, let it finish and retry the operation; do not weaken those guards. A
restore preserves the saved baselines and reports. The normal weekly schedule
continues when the application resumes. An abrupt crash can still require an
operator to investigate an executing job; this PR does not add a stuck-job rescue
plugin or promise automatic recovery from every infrastructure failure.

## Verification

Synthetic HTML tests cover text normalization, changed prices, empty selectors,
challenge pages, redirects and response limits. Isolated PostgreSQL tests cover
acknowledgements, stale hashes, failures preserving baselines, pending evidence
surviving report rotation, scoped job retention and transactional rollback.
They assert membership data is unchanged. Node unit tests cover allowed requests
and complete plan-card detection. `RELEASE_IMAGE=... sh scripts/verify-renderer.sh`
runs the final non-root browser image against synthetic JavaScript, with external
network access disabled, and checks timeout/interruption cleanup and memory usage.
Tests do not contact gym websites.
Live smoke checks, when performed, are page-availability evidence only.

Deploy this code through the normal Kubernetes build/migration/deployment flow
after PR review. Opening or merging a PR alone does not update the running app.

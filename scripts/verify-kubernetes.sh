#!/bin/sh
# End-to-end synthetic acceptance. Never reads/writes the live database.
set -eu
umask 077
project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"
export GYM_INTEL_BACKEND=kubernetes
export GYM_INTEL_KUBE_NAMESPACE="gym-intel-test-$(date +%s)-$$"
. scripts/kubernetes/common.sh
fixture_dir=$(mktemp -d "$kube_root/fixture-XXXXXX")
export GYM_INTEL_KUBE_SECRETS_DIR="$fixture_dir/secrets"
mkdir "$GYM_INTEL_KUBE_SECRETS_DIR"
# Backup paths intentionally live outside the checkout (existing safety rule).
fixture_backup=$(mktemp -d /tmp/gym-intel-kube-backups-XXXXXX)
fixture_csv="data/.kubernetes-fixture-$$.csv"
cleanup_fixture() {
  fixture_status=$?
  trap - EXIT HUP INT TERM
  kube delete namespace "$kube_namespace" --ignore-not-found --wait=true --timeout=120s >/dev/null || fixture_status=1
  rm -f "$fixture_csv"
  rm -f "$kube_image_file"
  # Keep failure evidence privately; successful fixtures are removed by exact
  # generated paths, not by globs across user data or backup directories.
  if [ "$fixture_status" = 0 ]; then
    case "$fixture_dir" in "$kube_root"/fixture-*) rm -rf "$fixture_dir" ;; *) exit 1 ;; esac
    case "$fixture_backup" in /tmp/gym-intel-kube-backups-*) rm -rf "$fixture_backup" ;; *) exit 1 ;; esac
  else
    printf 'Private failed-fixture evidence retained: %s\n' "$fixture_backup" >&2
  fi
  exit "$fixture_status"
}
trap cleanup_fixture EXIT
trap 'exit 1' HUP INT TERM
for secret in postgres_password postgres_app_password postgres_migrator_password grafana_database_password grafana_admin_password; do
  openssl rand -hex 32 > "$GYM_INTEL_KUBE_SECRETS_DIR/$secret"
done
kube create namespace "$kube_namespace"
kube label namespace "$kube_namespace" gym-intel-managed=true
sh scripts/kubernetes/deploy.sh
kube exec postgres-0 -- sh /opt/gym-intel/configure-roles.sh
sh scripts/kubernetes/task.sh migrate
kube exec postgres-0 -- sh /opt/gym-intel/configure-roles.sh
kube_resume
kube scale deployment/grafana --replicas=1
kube rollout status deployment/grafana --timeout=180s
sh scripts/verify-permissions.sh
header='brand_name,branch_name,plan_name,access_scope,offer_type,advertised_price_aed,billing_period_months,minimum_commitment_months,joining_fee_aed,source_url,source_published_on,observed_on,notes,payment_structure,renewal_policy,price_vat_status,admin_fee_aed'
for day in 1 2 3; do
  printf '%s\nTEST ONLY KUBERNETES,TEST BRANCH,TEST PLAN,single_branch,standard,%s,1,0,0,https://example.com/kubernetes,,2000-01-0%s,SYNTHETIC ONLY,,,,\n' "$header" "$((190 + day))" "$day" > "$fixture_csv"
  sh scripts/update-dashboard.sh "$fixture_csv" --directory "$fixture_backup"
done
test "$(find "$fixture_backup" -maxdepth 1 -type d -name 'backup-*' | wc -l | tr -d ' ')" = 2
test "$(kube_psql -qAtc 'SELECT count(*) FROM public.memberships')" = 1
test "$(kube_psql -qAtc 'SELECT advertised_price_aed = 193 FROM public.memberships')" = t
test "$(kube_psql -qAtc "SELECT count(*) FROM public.oban_jobs WHERE state='completed'")" = 2
sh scripts/update-status.sh --directory "$fixture_backup"
test "$(find "$fixture_backup/update-reports" -type f -name 'report-*.txt' | wc -l | tr -d ' ')" = 2
# Rejected input must not queue a job or change protected data.
state_before=$(kube_psql -qAt -f /opt/gym-intel-priv/update_state.sql -c 'SELECT pg_temp.dashboard_update_state()')
printf 'invalid,header\nnot,a-membership\n' > "$fixture_csv"
if sh scripts/update-dashboard.sh "$fixture_csv" --directory "$fixture_backup"; then
  echo 'FAIL: invalid CSV unexpectedly accepted' >&2; exit 1
fi
test "$(kube_psql -qAt -f /opt/gym-intel-priv/update_state.sql -c 'SELECT pg_temp.dashboard_update_state()')" = "$state_before"
test "$(find "$fixture_backup" -maxdepth 1 -type d -name 'backup-*' | wc -l | tr -d ' ')" = 2
test "$(find "$fixture_backup/update-reports" -type f -name 'report-*.txt' | wc -l | tr -d ' ')" = 2
kube_pause
kube_psql -qAt < scripts/recovery/snapshot.sql > "$fixture_dir/before.json"
old_pod=$(kube get pod postgres-0 -o 'jsonpath={.metadata.uid}')
old_pvc=$(kube get pvc data-postgres-0 -o 'jsonpath={.metadata.uid}')
kube delete pod postgres-0 --wait=true
kube rollout status statefulset/postgres --timeout=180s
test "$(kube get pod postgres-0 -o 'jsonpath={.metadata.uid}')" != "$old_pod"
test "$(kube get pvc data-postgres-0 -o 'jsonpath={.metadata.uid}')" = "$old_pvc"
kube_psql -qAt < scripts/recovery/snapshot.sql > "$fixture_dir/after.json"
cmp "$fixture_dir/before.json" "$fixture_dir/after.json"
kube_resume
grafana_pod=$(kube get pod -l app=grafana -o 'jsonpath={.items[0].metadata.name}')
grafana_uid=$(kube get pod "$grafana_pod" -o 'jsonpath={.metadata.uid}')
grafana_pvc=$(kube get pvc grafana-data -o 'jsonpath={.metadata.uid}')
kube exec deployment/grafana -- sh -c 'printf "persistent fixture\n" > /var/lib/grafana/kubernetes-persistence-probe'
kube delete pod "$grafana_pod" --wait=true
kube rollout status deployment/grafana --timeout=180s
test "$(kube get pod -l app=grafana -o 'jsonpath={.items[0].metadata.uid}')" != "$grafana_uid"
test "$(kube get pvc grafana-data -o 'jsonpath={.metadata.uid}')" = "$grafana_pvc"
test "$(kube exec deployment/grafana -- cat /var/lib/grafana/kubernetes-persistence-probe)" = 'persistent fixture'
kube exec deployment/grafana -- rm /var/lib/grafana/kubernetes-persistence-probe
sh scripts/kubernetes/checks.sh dashboard
sh scripts/kubernetes/checks.sh tests
test "$(kube get jobs -o 'jsonpath={.items[*].metadata.name}')" = ''
echo 'PASS: Kubernetes migrations, permissions, three rolling updates, rejected input, two verified backups/reports, current-only records, bounded jobs, task cleanup, both PVC replacements, dashboard queries and full tests'

#!/bin/sh
# Restore only into an empty, paused, managed Kubernetes database.
set -eu
umask 077
project_dir=$(cd "$(dirname "$0")/../.." && pwd)
cd "$project_dir"
. scripts/kubernetes/common.sh
. scripts/recovery/common.sh
test "$#" = 1 || { echo 'Usage: restore.sh /absolute/verified/backup-directory' >&2; exit 2; }
bundle=$1
recovery_check_verified
kube_guard
test "$(kube get deployment app -o 'jsonpath={.spec.replicas}')" = 0
test "$(kube get deployment grafana -o 'jsonpath={.spec.replicas}')" = 0
test "$(kube_psql -qAtc "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public'")" = 0 || {
  echo 'Refusing restore over existing database objects' >&2; exit 1;
}
kube exec postgres-0 -- sh /opt/gym-intel/configure-roles.sh
kube exec -i postgres-0 -- sh -ec '
  export PGPASSWORD="$(cat /run/secrets/postgres_password)"
  exec pg_restore --exit-on-error --single-transaction --username=gym_intel --dbname=gym_intel_dev
' < "$bundle/database.dump"
restored=$(mktemp "$kube_root/restored-XXXXXX")
trap 'rm -f "$restored"' EXIT HUP INT TERM
kube_psql -qAt < scripts/recovery/snapshot.sql > "$restored"
cmp -s "$bundle/baseline.json" "$restored" || {
  echo 'FAIL: restored baseline differs; app remains paused, source backup preserved' >&2; exit 1;
}
echo 'PASS: Kubernetes restore exactly matches verified source baseline (rows, roles, schema, sequences and jobs)'

#!/bin/sh
# Prepare paused workloads. Explicit start follows migration/restore verification.
set -eu
umask 077
project_dir=$(cd "$(dirname "$0")/../.." && pwd)
cd "$project_dir"
. scripts/kubernetes/common.sh
kube_guard
if kube get deployment app >/dev/null 2>&1; then
  test "$(kube get deployment app -o 'jsonpath={.spec.replicas}')" = 0 || {
    echo 'Pause the app explicitly before preparing an upgrade' >&2; exit 1;
  }
fi
secret_dir="$project_dir/.secrets"
if [ -n "${GYM_INTEL_KUBE_SECRETS_DIR:-}" ]; then
  case "$kube_namespace:$GYM_INTEL_KUBE_SECRETS_DIR" in
    gym-intel-test-*:"$kube_root"/fixture-*/secrets) secret_dir=$GYM_INTEL_KUBE_SECRETS_DIR ;;
    *) echo 'Alternate credentials are restricted to disposable acceptance fixtures' >&2; exit 2 ;;
  esac
fi
for secret in postgres_password postgres_app_password postgres_migrator_password grafana_database_password grafana_admin_password; do
  test -s "$secret_dir/$secret" && test ! -L "$secret_dir/$secret" || { echo "Missing private credential: $secret" >&2; exit 1; }
done
kube create secret generic postgres-passwords --from-file="$secret_dir/postgres_password" \
  --from-file="$secret_dir/postgres_app_password" --from-file="$secret_dir/postgres_migrator_password" \
  --from-file="$secret_dir/grafana_database_password" --dry-run=client -o yaml | kube apply -f -
kube create secret generic app-password --from-file="$secret_dir/postgres_app_password" --dry-run=client -o yaml | kube apply -f -
kube create secret generic migrator-password --from-file="$secret_dir/postgres_migrator_password" --dry-run=client -o yaml | kube apply -f -
kube create secret generic grafana-passwords --from-file="$secret_dir/grafana_database_password" \
  --from-file="$secret_dir/grafana_admin_password" --dry-run=client -o yaml | kube apply -f -
for pair in postgres-scripts:postgres postgres-sql:priv grafana-datasources:grafana/provisioning/datasources grafana-provider:grafana/provisioning/dashboards grafana-panels:grafana/dashboards; do
  kube create configmap "${pair%%:*}" --from-file="${pair#*:}" --dry-run=client -o yaml | kube apply -f -
done
kube create configmap grafana-start --from-file=grafana-start.sh=grafana/start.sh --dry-run=client -o yaml | kube apply -f -
source_checks_enabled=false
if [ "$kube_namespace" = gym-intel ]; then source_checks_enabled=true; fi
kube create configmap app-settings --from-literal=DATABASE_NAME=gym_intel_dev \
  --from-literal=SOURCE_CHECKS_ENABLED="$source_checks_enabled" \
  --from-literal=DATABASE_USER=gym_intel_app --from-literal=DATABASE_HOST=postgres \
  --from-literal=DATABASE_PORT=5432 --from-literal=DATABASE_POOL_SIZE=5 \
  --from-literal=DATABASE_PASSWORD_FILE=/run/secrets/postgres_app_password \
  --from-literal=ERL_FLAGS='+S 2:2' --dry-run=client -o yaml | kube apply -f -
docker build --provenance=false --target runtime --tag gym-intel-runtime:kubernetes .
image_id=$(docker image inspect gym-intel-runtime:kubernetes --format '{{.Id}}')
runtime_image="gym-intel-runtime:k8s-${image_id#sha256:}"
docker tag gym-intel-runtime:kubernetes "$runtime_image"
for image in "$runtime_image" postgres:18.6-alpine grafana/grafana:13.2; do
  docker image inspect "$image" >/dev/null 2>&1 || docker pull --platform linux/arm64 "$image"
  # Desktop may cache only ARM64 layers of a multi-architecture manifest.
  # Export that platform explicitly rather than asking Kind for all platforms.
  image_archive=$(mktemp "$kube_root/image-XXXXXX")
  trap 'rm -f "$image_archive"' EXIT HUP INT TERM
  docker image save --platform linux/arm64 "$image" -o "$image_archive"
  docker exec -i gym-intel-control-plane ctr --namespace=k8s.io images import \
    --platform linux/arm64 --digests --snapshotter=overlayfs - < "$image_archive"
  rm "$image_archive"
  trap - EXIT HUP INT TERM
done
printf '%s\n' "$runtime_image" > "$kube_image_file"
# Do not reset a running deployment to zero on repeat preparation.
if kube get deployment app >/dev/null 2>&1; then
  test "$(kube get deployment app -o 'jsonpath={.spec.replicas}')" = 0 || {
    echo 'Pause the app explicitly before preparing an upgrade' >&2; exit 1;
  }
fi
kube apply -f kubernetes/workloads.yaml
if [ "$kube_namespace" = gym-intel ]; then kube apply -f kubernetes/local-access.yaml; fi
kube set image deployment/app "app=$runtime_image"
kube rollout status statefulset/postgres --timeout=180s
echo 'PASS: workloads prepared, app and Grafana paused; restore or migrate before starting'

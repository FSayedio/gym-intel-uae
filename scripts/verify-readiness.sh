#!/bin/sh
# Fresh resource-limited PostgreSQL and packaged-worker rehearsal; no live mounts.
set -eu
umask 077
if [ "$#" -ne 0 ]; then
  echo 'Usage: sh scripts/verify-readiness.sh' >&2
  exit 2
fi
project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"
readiness_image=${RELEASE_IMAGE:-gym-intel-runtime:local}
readiness_checks=${CHECK_IMAGE:-gym-intel-checks:local}
for readiness_tool in postgres:18.6-alpine "$readiness_image" "$readiness_checks"; do
  test "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$readiness_tool")" = linux/arm64
done
readiness_base=${TMPDIR:-/tmp}
readiness_tmp=$(mktemp -d "${readiness_base%/}/gym-intel-readiness.XXXXXX")
readiness_run="$(date +%s)-$$"
readiness_net="gym-intel-readiness-$readiness_run"
readiness_postgres="gym-intel-readiness-pg-$readiness_run"
readiness_cleanup() {
  readiness_status=$?
  trap - EXIT HUP INT TERM
  if ! docker info >/dev/null 2>&1; then
    echo 'FAIL: Docker unavailable; temporary resource cleanup cannot be confirmed' >&2
    readiness_status=1
  fi
  if docker inspect "$readiness_postgres" >/dev/null 2>&1; then
    if [ "$(docker inspect --format '{{index .Config.Labels "com.gym-intel.readiness"}}' "$readiness_postgres")" = "$readiness_run" ]; then
      docker rm -f "$readiness_postgres" >/dev/null 2>&1 || readiness_status=1
    else
      readiness_status=1
    fi
  fi
  if docker network inspect "$readiness_net" >/dev/null 2>&1; then
    if [ "$(docker network inspect --format '{{index .Labels "com.gym-intel.readiness"}}' "$readiness_net")" = "$readiness_run" ]; then
      docker network rm "$readiness_net" >/dev/null 2>&1 || readiness_status=1
    else
      readiness_status=1
    fi
  fi
  rm -f "$readiness_tmp/password" || readiness_status=1
  rmdir "$readiness_tmp" || readiness_status=1
  exit "$readiness_status"
}
trap readiness_cleanup EXIT
trap 'exit 1' HUP INT TERM
openssl rand -hex -out "$readiness_tmp/password" 32
chmod 644 "$readiness_tmp/password"
docker network create --internal --label "com.gym-intel.readiness=$readiness_run" "$readiness_net" >/dev/null
docker run --detach --platform linux/arm64 --pull never \
  --name "$readiness_postgres" --label "com.gym-intel.readiness=$readiness_run" \
  --network "$readiness_net" --network-alias postgres \
  --memory 768m --cpus 1 --pids-limit 128 \
  --tmpfs /var/lib/postgresql:rw,nosuid,noexec,size=512m \
  -e POSTGRES_USER=gym_intel -e POSTGRES_DB=postgres \
  -e POSTGRES_PASSWORD_FILE=/run/secrets/test_owner_password \
  -e POSTGRES_HOST_AUTH_METHOD=scram-sha-256 \
  -v "$readiness_tmp/password:/run/secrets/test_owner_password:ro" \
  postgres:18.6-alpine >/dev/null
readiness_wait=40
until docker exec "$readiness_postgres" sh -ec '
  export PGPASSWORD="$(cat /run/secrets/test_owner_password)"
  exec psql -X --host=127.0.0.1 --username=gym_intel --dbname=postgres -qAtc "SELECT 1"
' >/dev/null 2>&1; do
  readiness_wait=$((readiness_wait - 1))
  test "$readiness_wait" -gt 0 || { echo 'FAIL: isolated readiness database unavailable' >&2; exit 1; }
  sleep 1
done
echo 'Fresh ARM64 rehearsal: PostgreSQL 768 MiB/1 CPU/tmpfs 512 MiB; worker 512 MiB/1 CPU'
docker image inspect --format 'Runtime {{.Id}} {{.Os}}/{{.Architecture}}' "$readiness_image"
docker image inspect --format 'PostgreSQL image {{.Id}} {{.Os}}/{{.Architecture}}' postgres:18.6-alpine
READINESS_RUN="$readiness_run" RELEASE_IMAGE="$readiness_image" CHECK_IMAGE="$readiness_checks" \
  RELEASE_TEST_OWNER_PASSWORD_FILE="$readiness_tmp/password" \
  RELEASE_TEST_NETWORK="$readiness_net" RELEASE_TEST_HOST=postgres RELEASE_TEST_PORT=5432 \
  RELEASE_TEST_OWNER_USER=gym_intel sh scripts/verify-release.sh --readiness
echo 'PASS: fresh isolated setup, measured workload and explicit interrupted-job recovery'

#!/bin/sh
# Test the FINAL ARM64 runtime image against a new, uniquely named database.
# Only resources created by this invocation are removed; development is never used.
set -eu
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
umask 077

readiness_mode=false
case "$#:${1:-}" in
  0:) ;;
  1:--readiness) readiness_mode=true ;;
  *) echo 'Usage: sh scripts/verify-release.sh [--readiness]' >&2; exit 2 ;;
esac
if [ "$readiness_mode" = true ] && [ -z "${READINESS_RUN:-}" ]; then
  echo 'Readiness mode requires the isolated verify-readiness.sh wrapper' >&2
  exit 2
fi
runtime_image="${RELEASE_IMAGE:-gym-intel-runtime:local}"
owner_file="${RELEASE_TEST_OWNER_PASSWORD_FILE:-$project_dir/.secrets/postgres_password}"
test -s "$owner_file"
owner_file="$(cd "$(dirname "$owner_file")" && pwd)/$(basename "$owner_file")"
test_host="${RELEASE_TEST_HOST:-postgres}"
test_port="${RELEASE_TEST_PORT:-5432}"
owner_user="${RELEASE_TEST_OWNER_USER:-gym_intel}"
client_image=postgres:18.6-alpine

if [ -n "${RELEASE_TEST_NETWORK:-}" ]; then
  test_network="$RELEASE_TEST_NETWORK"
else
  postgres_id="$(docker compose ps -q postgres)"
  test -n "$postgres_id"
  test_network="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{println .NetworkID}}{{end}}' "$postgres_id" | sed '/^$/d')"
  test -n "$test_network"
  test "$(printf '%s\n' "$test_network" | wc -l | tr -d ' ')" = 1
fi
if [ "$readiness_mode" = true ]; then
  test "$(docker network inspect --format '{{.Internal}} {{index .Labels "com.gym-intel.readiness"}}' "$test_network")" = "true $READINESS_RUN" || {
    echo 'Readiness mode requires its labelled internal test network' >&2; exit 1;
  }
fi

test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/gym-intel-release.XXXXXX")"
run_id="$(date +%s)_$$"
test_database="gym_intel_release_test_$run_id"
migrator_role="release_migrator_$run_id"
runtime_role="release_app_$run_id"
reader_role="release_reader_$run_id"
runtime_container="gym-intel-release-$run_id"
database_created=false
migrator_created=false
runtime_role_created=false
reader_created=false
container_started=false
readiness_holder=''

psql_owner() {
  docker run --rm -i --platform linux/arm64 --network "$test_network" \
    --memory 128m --cpus 0.25 --pids-limit 64 \
    -e "PGHOST=$test_host" -e "PGPORT=$test_port" \
    -e "PGUSER=$owner_user" -e PGDATABASE=postgres -e PGCONNECT_TIMEOUT=3 \
    -v "$owner_file:/run/secrets/client_password:ro" \
    "$client_image" sh -c '
      export PGPASSWORD="$(cat /run/secrets/client_password)"
      exec psql -X --no-password -v ON_ERROR_STOP=1 "$@"
    ' sh "$@"
}

cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$status" -ne 0 ] && [ "$readiness_mode" = true ]; then
    printf 'FAIL: readiness phase=%s\n' "${readiness_phase:-release-smoke}" >&2
    if [ "$database_created" = true ]; then
      psql_owner --dbname="$test_database" -c 'SELECT id,state,attempt,cardinality(errors) AS error_count FROM oban_jobs ORDER BY id' || true
      psql_owner --dbname="$test_database" -c "SELECT usename,application_name,state,wait_event_type,wait_event FROM pg_stat_activity WHERE datname=current_database()" || true
    fi
  fi
  if [ -n "$readiness_holder" ]; then
    if [ "$(docker inspect --format '{{index .Config.Labels "com.gym-intel.release-fixture"}}' "$readiness_holder" 2>/dev/null)" = "$run_id" ]; then
      docker rm -f "$readiness_holder" >/dev/null 2>&1 || status=1
    else
      status=1
    fi
  fi
  if [ "$container_started" = true ]; then
    docker rm -f "$runtime_container" >/dev/null 2>&1 || status=1
  fi
  if [ "$database_created" = true ]; then
    # The name is generated above, never supplied by an operator.
    psql_owner -c "DROP DATABASE \"$test_database\" WITH (FORCE)" >/dev/null || status=1
  fi
  if [ "$runtime_role_created" = true ]; then
    psql_owner -c "DROP ROLE \"$runtime_role\"" >/dev/null || status=1
  fi
  if [ "$reader_created" = true ]; then
    psql_owner -c "DROP ROLE \"$reader_role\"" >/dev/null || status=1
  fi
  if [ "$migrator_created" = true ]; then
    psql_owner -c "DROP ROLE \"$migrator_role\"" >/dev/null || status=1
  fi
  # Exact generated files only; preserve unexpected content rather than recurse.
  rm -f "$test_tmp/app_password" "$test_tmp/migrator_password" \
    "$test_tmp/reader_password" \
    "$test_tmp/data/valid.csv" "$test_tmp/data/invalid.csv" \
    "$test_tmp/data/interrupted.csv" "$test_tmp/data/workload.csv" "$test_tmp/data/overlap.csv" \
    "$test_tmp/missing-secret.log" "$test_tmp/invalid-import.log" || status=1
  rmdir "$test_tmp/data" "$test_tmp" 2>/dev/null || status=1
  if [ "$status" -ne 0 ]; then
    echo "Release check failed; if cleanup also reported errors, inspect $test_database and its temporary roles." >&2
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

mkdir "$test_tmp/data"
for secret_name in app_password migrator_password reader_password; do
  od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$test_tmp/$secret_name"
  printf '\n' >> "$test_tmp/$secret_name"
  # Readable inside non-root bind mounts; host parent stays mode 700.
  chmod 644 "$test_tmp/$secret_name"
done
app_password="$(cat "$test_tmp/app_password")"
migrator_password="$(cat "$test_tmp/migrator_password")"

echo 'Checking non-root runtime and absence of the Mix build toolchain'
docker run --rm --platform linux/arm64 --memory 512m --cpus 1 --pids-limit 256 "$runtime_image" sh -ec '
  test "$(id -u)" = 10001
  test ! -w /app
  if command -v mix || command -v elixir || command -v cc; then
    echo "Unexpected build tool in runtime" >&2
    exit 1
  fi
  test ! -e /app/mix.exs
  test ! -d /app/test
  test ! -d /app/deps
  test ! -e /run/secrets/postgres_password
  test ! -e /run/secrets/postgres_migrator_password'

echo 'Checking missing credentials fail instead of starting'
if docker run --rm --platform linux/arm64 \
  --memory 512m --cpus 1 --pids-limit 256 \
  -e DATABASE_PASSWORD_FILE=/run/secrets/intentionally_missing \
  "$runtime_image" bin/gym_intel eval 'GymIntel.Release.migrate()' \
  > "$test_tmp/missing-secret.log" 2>&1; then
  echo 'FAIL: runtime accepted a missing credential' >&2
  exit 1
fi
grep -q '/run/secrets/intentionally_missing' "$test_tmp/missing-secret.log" || {
  echo 'FAIL: missing-secret probe failed for an unrelated reason' >&2; exit 1;
}

echo 'Creating isolated database and separate temporary migrator/runtime roles'
psql_owner >/dev/null <<SQL
CREATE ROLE "$migrator_role" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '$migrator_password';
SQL
migrator_created=true
psql_owner >/dev/null <<SQL
CREATE ROLE "$runtime_role" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '$app_password';
SQL
runtime_role_created=true
psql_owner -c "CREATE DATABASE \"$test_database\" OWNER \"$migrator_role\"" >/dev/null
database_created=true
psql_owner -c "REVOKE ALL ON DATABASE \"$test_database\" FROM PUBLIC; GRANT CONNECT ON DATABASE \"$test_database\" TO \"$runtime_role\"" >/dev/null
unset app_password migrator_password

echo 'Applying all migrations using only the packaged release and migrator secret'
docker run --rm --platform linux/arm64 --network "$test_network" \
  --memory 512m --cpus 1 --pids-limit 256 \
  -e "DATABASE_HOST=$test_host" -e "DATABASE_PORT=$test_port" \
  -e "DATABASE_NAME=$test_database" -e "DATABASE_USER=$migrator_role" \
  -e DATABASE_PASSWORD_FILE=/run/secrets/migrator_password \
  -v "$test_tmp/migrator_password:/run/secrets/migrator_password:ro" \
  "$runtime_image" bin/gym_intel eval 'GymIntel.Release.migrate()'

psql_owner --dbname="$test_database" >/dev/null <<SQL
SELECT public.configure_observation_access('$runtime_role'::name, NULL::name);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.oban_jobs, public.oban_peers TO "$runtime_role";
GRANT USAGE, SELECT ON SEQUENCE public.oban_jobs_id_seq TO "$runtime_role";
GRANT SELECT ON public.schema_migrations TO "$runtime_role";
SQL

cat > "$test_tmp/data/valid.csv" <<'CSV'
brand_name,branch_name,plan_name,access_scope,offer_type,advertised_price_aed,billing_period_months,minimum_commitment_months,joining_fee_aed,source_url,source_published_on,observed_on,notes,payment_structure,renewal_policy,price_vat_status,admin_fee_aed
TEST ONLY RELEASE,TEST BRANCH,TEST MONTHLY,single_branch,standard,199,1,0,0,https://example.com/release-smoke,,2000-01-01,SYNTHETIC TEST ONLY,recurring,automatic,included,0
CSV
printf 'invalid_header\n' > "$test_tmp/data/invalid.csv"
chmod 755 "$test_tmp/data"
chmod 644 "$test_tmp/data/valid.csv" "$test_tmp/data/invalid.csv"

run_import() {
  docker run --rm --platform linux/arm64 --network "$test_network" \
    --memory 512m --cpus 1 --pids-limit 256 \
    -e "DATABASE_HOST=$test_host" -e "DATABASE_PORT=$test_port" \
    -e "DATABASE_NAME=$test_database" -e "DATABASE_USER=$runtime_role" \
    -e DATABASE_PASSWORD_FILE=/run/secrets/app_password \
    -e "IMPORT_CSV_PATH=/app/data/$1" \
    -v "$test_tmp/app_password:/run/secrets/app_password:ro" \
    -v "$test_tmp/data:/app/data:ro" \
    "$runtime_image" bin/gym_intel eval 'GymIntel.Release.enqueue()'
}

echo 'Checking invalid input is rejected without a queued job'
if run_import invalid.csv > "$test_tmp/invalid-import.log" 2>&1; then
  echo 'FAIL: invalid CSV was accepted' >&2
  exit 1
fi
test "$(psql_owner --dbname="$test_database" -Atc 'SELECT count(*) FROM oban_jobs')" = 0

echo 'Starting actual runtime worker, with no owner/migrator secret mounted'
docker run --detach --platform linux/arm64 --name "$runtime_container" \
  --label "com.gym-intel.release-fixture=$run_id" \
  --memory 512m --cpus 1 --pids-limit 256 \
  --network "$test_network" \
  -e "DATABASE_HOST=$test_host" -e "DATABASE_PORT=$test_port" \
  -e "DATABASE_NAME=$test_database" -e "DATABASE_USER=$runtime_role" \
  -e DATABASE_PASSWORD_FILE=/run/secrets/app_password \
  -v "$test_tmp/app_password:/run/secrets/app_password:ro" \
  "$runtime_image" >/dev/null
container_started=true

wait_for_jobs() {
  remaining=40
  while [ "$remaining" -gt 0 ]; do
    test "$(docker inspect --format '{{.State.Running}}' "$runtime_container")" = true || {
      echo 'FAIL: runtime worker exited before completing the job' >&2; return 1;
    }
    completed="$(psql_owner --dbname="$test_database" -Atc "SELECT count(*) FROM oban_jobs WHERE state='completed' AND attempt=1 AND cardinality(errors)=0")"
    if [ "$completed" = "$1" ]; then return 0; fi
    sleep 1
    remaining=$((remaining - 1))
  done
  echo 'FAIL: background import did not complete within the verification deadline' >&2
  return 1
}

echo 'Submitting synthetic CSV and observing real Oban completion'
run_import valid.csv
wait_for_jobs 1
echo 'Submitting the identical CSV again; the job must complete without extra rows'
run_import valid.csv
wait_for_jobs 2

result="$(psql_owner --dbname="$test_database" -Atc "SELECT concat((SELECT count(*) FROM memberships),',',(SELECT count(*) FROM membership_notes),',',(SELECT count(*) FROM membership_imports),',',(SELECT count(*) FROM oban_jobs WHERE state='completed'),',',(SELECT count(*) FROM memberships WHERE brand_name='TEST ONLY RELEASE' AND advertised_price_aed=199 AND minimum_commitment_months=0 AND joining_fee_aed=0 AND admin_fee_aed=0))")"
test "$result" = '1,1,1,2,1' || {
  echo "FAIL: unexpected observation/note/fingerprint/job/fact counts: $result" >&2; exit 1;
}
docker exec "$runtime_container" sh -ec '
  test "$(id -u)" = 10001
  test ! -e /run/secrets/postgres_password
  test ! -e /run/secrets/postgres_migrator_password
  test ! -e /run/secrets/migrator_password'

if [ "$readiness_mode" = true ]; then
  . "$project_dir/scripts/readiness/rehearse.sh"
fi

echo 'Checking graceful runtime shutdown'
docker stop --time 20 "$runtime_container" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$runtime_container")" = 0
echo 'PASS: packaged migrations, non-root worker, invalid-input rejection, real jobs, dedupe and shutdown'

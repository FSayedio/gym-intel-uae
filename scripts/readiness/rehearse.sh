# Sourced only inside verify-release.sh's generated, labelled readiness fixture.
test "$readiness_mode" = true
test -n "$READINESS_RUN"
readiness_checks_image=${CHECK_IMAGE:-gym-intel-checks:local}
readiness_phase=generate-fixtures

docker run --rm --platform linux/arm64 --network none --memory 512m --cpus 1 \
  -e MIX_ENV=test -e DATABASE_PASSWORD_FILE=/run/secrets/app_password \
  -e READINESS_DATA_DIR=/fixture-data \
  -v "$test_tmp/app_password:/run/secrets/app_password:ro" \
  -v "$test_tmp/data:/fixture-data" \
  -v "$project_dir/scripts/readiness/workload.exs:/probe.exs:ro" \
  "$readiness_checks_image" mix run --no-start --no-compile -r /probe.exs \
  -e 'GymIntel.Readiness.Workload.write_inputs()'

readiness_eval() {
  docker run --rm --platform linux/arm64 --network "$test_network" --memory 512m --cpus 1 \
    -e "DATABASE_HOST=$test_host" -e "DATABASE_PORT=$test_port" \
    -e "DATABASE_NAME=$test_database" -e "DATABASE_USER=$1" \
    -e DATABASE_PASSWORD_FILE=/run/secrets/fixture_password -e READINESS_FIXTURE=true \
    -e "READINESS_JOB_ID=${readiness_job:-0}" \
    -v "$2:/run/secrets/fixture_password:ro" \
    -v "$project_dir/scripts/readiness/workload.exs:/probe.exs:ro" \
    -v "$project_dir/grafana/dashboards/memberships.json:/fixture-dashboard.json:ro" \
    "$runtime_image" bin/gym_intel eval "Code.require_file(\"/probe.exs\"); GymIntel.Readiness.Workload.run(:$3)"
}
readiness_job_id() {
  readiness_submission=$(run_import "$1")
  printf '%s\n' "$readiness_submission" | sed -n 's/^Queued import job \([0-9][0-9]*\); check job state for completion\.$/\1/p'
}
readiness_wait_job() {
  readiness_remaining=120
  while [ "$readiness_remaining" -gt 0 ]; do
    readiness_state=$(psql_owner --dbname="$test_database" -Atc "SELECT state FROM oban_jobs WHERE id=$1")
    case "$readiness_state" in
      completed) return 0 ;;
      cancelled|discarded) echo 'FAIL: measured fixture job failed' >&2; return 1 ;;
    esac
    test "$(docker inspect --format '{{.State.Running}}' "$runtime_container")" = true
    sleep 1
    readiness_remaining=$((readiness_remaining - 1))
  done
  echo 'FAIL: fixture job exceeded 120-second observation window' >&2
  return 1
}
readiness_data_hash() {
  psql_owner --dbname="$test_database" -Atc "SELECT encode(sha256(convert_to(concat_ws(':',
    (SELECT jsonb_agg(to_jsonb(t) ORDER BY id)::text FROM memberships t),
    (SELECT jsonb_agg(to_jsonb(t) ORDER BY id)::text FROM membership_notes t),
    (SELECT jsonb_agg(to_jsonb(t) ORDER BY content_sha256)::text FROM membership_imports t)
  ),'UTF8')),'hex')"
}

echo 'Holding a fixture-only insert transaction before killing the generated worker'
readiness_phase=acquire-transaction-gate
readiness_before=$(readiness_data_hash)
psql_owner --dbname="$test_database" >/dev/null <<'SQL'
CREATE FUNCTION public.readiness_gate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.brand_name = 'TEST ONLY INTERRUPTED' THEN
    PERFORM pg_advisory_xact_lock(18441, 1);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER readiness_import_gate AFTER INSERT ON public.memberships
FOR EACH ROW EXECUTE FUNCTION public.readiness_gate();
SQL
readiness_holder="gym-intel-readiness-gate-$run_id"
docker run --detach --platform linux/arm64 --name "$readiness_holder" \
  --label "com.gym-intel.release-fixture=$run_id" --network "$test_network" \
  --memory 128m --cpus 0.25 --pids-limit 64 \
  -e "PGHOST=$test_host" -e "PGPORT=$test_port" -e "PGUSER=$owner_user" \
  -e "PGDATABASE=$test_database" -e "PGAPPNAME=readiness_gate_$run_id" \
  -v "$owner_file:/run/secrets/client_password:ro" \
  "$client_image" sh -ec 'export PGPASSWORD="$(cat /run/secrets/client_password)"; exec psql -X --no-password -qAtc "SELECT pg_advisory_lock(18441,1); SELECT pg_sleep(120)"' >/dev/null
readiness_remaining=40
until [ "$(psql_owner --dbname="$test_database" -Atc "SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a ON a.pid=l.pid WHERE a.datname=current_database() AND a.application_name='readiness_gate_$run_id' AND l.locktype='advisory' AND l.granted")" = 1 ]; do
  readiness_remaining=$((readiness_remaining - 1)); test "$readiness_remaining" -gt 0; sleep 1
done
readiness_job=$(readiness_job_id interrupted.csv)
readiness_phase=await-gated-import
case "$readiness_job" in ''|*[!0-9]*) echo 'FAIL: exact fixture job ID unavailable' >&2; exit 1 ;; esac
readiness_remaining=40
until [ "$(psql_owner --dbname="$test_database" -Atc "SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND usename='$runtime_role' AND wait_event_type='Lock' AND wait_event='advisory'")" = 1 ]; do
  readiness_remaining=$((readiness_remaining - 1)); test "$readiness_remaining" -gt 0; sleep 1
done
test "$(psql_owner --dbname="$test_database" -Atc "SELECT concat(state,',',attempt) FROM oban_jobs WHERE id=$readiness_job")" = executing,1
readiness_phase=kill-generated-worker
test "$(docker inspect --format '{{index .Config.Labels "com.gym-intel.release-fixture"}}' "$runtime_container")" = "$run_id"
docker kill --signal KILL "$runtime_container" >/dev/null
readiness_remaining=40
while [ "$(docker inspect --format '{{.State.Running}}' "$runtime_container")" = true ]; do
  readiness_remaining=$((readiness_remaining - 1)); test "$readiness_remaining" -gt 0; sleep 1
done
test "$(docker inspect --format '{{.State.Running}} {{.State.ExitCode}}' "$runtime_container")" = 'false 137'
# A server waiting on our advisory lock may not observe client EOF until the
# blocked statement can finish. The dead worker cannot send COMMIT; release only
# this generated gate holder, then require the disconnected transaction to abort.
# Removing its client alone does not interrupt pg_sleep immediately, so terminate
# only the uniquely named gate backend in this generated database as well.
docker rm -f "$readiness_holder" >/dev/null
readiness_holder=''
test "$(psql_owner --dbname="$test_database" -Atc "SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND application_name='readiness_gate_$run_id' AND usename='$owner_user'")" = 1
test "$(psql_owner --dbname="$test_database" -Atc "SELECT pg_terminate_backend(pid,5000) FROM pg_stat_activity WHERE datname=current_database() AND application_name='readiness_gate_$run_id' AND usename='$owner_user'")" = t
readiness_phase=verify-rollback
readiness_remaining=40
until [ "$(psql_owner --dbname="$test_database" -Atc "SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND usename='$runtime_role'")" = 0 ]; do
  readiness_remaining=$((readiness_remaining - 1)); test "$readiness_remaining" -gt 0; sleep 1
done
test "$(readiness_data_hash)" = "$readiness_before"
test "$(psql_owner --dbname="$test_database" -Atc "SELECT concat(state,',',attempt) FROM oban_jobs WHERE id=$readiness_job")" = executing,1
psql_owner --dbname="$test_database" -c 'DROP TRIGGER readiness_import_gate ON public.memberships; DROP FUNCTION public.readiness_gate();' >/dev/null
echo 'PASS: worker killed mid-transaction; prior facts/notes/fingerprints unchanged; exact job remains executing attempt 1'
readiness_phase=recover-exact-job
readiness_eval "$runtime_role" "$test_tmp/app_password" recover
docker start "$runtime_container" >/dev/null
readiness_wait_job "$readiness_job"
test "$(psql_owner --dbname="$test_database" -Atc "SELECT concat(state,',',attempt) FROM oban_jobs WHERE id=$readiness_job")" = completed,2
readiness_replay=$(readiness_job_id interrupted.csv)
case "$readiness_replay" in ''|*[!0-9]*) exit 1 ;; esac
readiness_wait_job "$readiness_replay"
test "$(psql_owner --dbname="$test_database" -Atc "SELECT concat((SELECT count(*) FROM memberships WHERE brand_name='TEST ONLY INTERRUPTED'),',',(SELECT count(*) FROM membership_notes n JOIN memberships m ON m.id=n.membership_id WHERE m.brand_name='TEST ONLY INTERRUPTED'),',',(SELECT count(*) FROM membership_imports))")" = '1,1,2'
echo 'PASS: same interrupted job completed on attempt 2; duplicate replay added no facts or notes'
readiness_phase=measure-workload

for readiness_input in workload.csv workload.csv overlap.csv; do
  readiness_start=$(date +%s)
  readiness_job=$(readiness_job_id "$readiness_input")
  case "$readiness_job" in ''|*[!0-9]*) exit 1 ;; esac
  readiness_wait_job "$readiness_job"
  readiness_end=$(date +%s)
  readiness_counts=$(psql_owner --dbname="$test_database" -Atc "SELECT concat((SELECT count(*) FROM memberships WHERE brand_name LIKE 'TEST ONLY WORKLOAD %'),',',(SELECT count(*) FROM membership_notes n JOIN memberships m ON m.id=n.membership_id WHERE m.brand_name LIKE 'TEST ONLY WORKLOAD %'),',',(SELECT count(*) FROM membership_imports))")
  case "$readiness_input:$readiness_counts" in
    workload.csv:1000,1000,3|overlap.csv:1500,1500,4) ;;
    *) echo "FAIL: workload observation/note/total-marker counts: $readiness_counts" >&2; exit 1 ;;
  esac
  printf 'MEASUREMENT input=%s enqueue_to_completion_seconds=%s workload_rows,notes,total_markers=%s\n' \
    "$readiness_input" "$((readiness_end - readiness_start))" "$readiness_counts"
done
psql_owner --dbname="$test_database" -c 'ANALYZE public.memberships, public.membership_notes, public.membership_imports' >/dev/null
readiness_phase=measure-reader-plans
readiness_reader_password=$(cat "$test_tmp/reader_password")
psql_owner >/dev/null <<SQL
CREATE ROLE "$reader_role" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '$readiness_reader_password';
SQL
reader_created=true
unset readiness_reader_password
psql_owner --dbname="$test_database" -c "GRANT CONNECT ON DATABASE \"$test_database\" TO \"$reader_role\"; SELECT public.configure_observation_access(NULL::name,'$reader_role'::name)" >/dev/null
readiness_eval "$reader_role" "$test_tmp/reader_password" plans
docker stats --no-stream --format 'MEASUREMENT worker_memory={{.MemUsage}} worker_cpu={{.CPUPerc}}' "$runtime_container"
docker exec "$runtime_container" sh -ec 'if [ -r /sys/fs/cgroup/memory.peak ]; then printf "MEASUREMENT worker_cgroup_peak_bytes="; cat /sys/fs/cgroup/memory.peak; else echo "MEASUREMENT worker_cgroup_peak_bytes=unavailable"; fi'
echo 'PASS: 1000-row import, identical replay, 500-row overlap, reader query plans; measurements are not a throughput SLA'
readiness_phase=graceful-shutdown

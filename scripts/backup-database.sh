#!/bin/sh
# On-demand, quiescent PostgreSQL capture -> isolated restore -> seven verified copies.
set -eu
umask 077
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
. "$project_dir/scripts/recovery/common.sh"
case "$#" in
  0) backup_root="$HOME/Library/Application Support/Gym Intel UAE/backups" ;;
  2) test "$1" = --directory || { echo 'Usage: sh scripts/backup-database.sh [--directory /absolute/private/path]' >&2; exit 2; }
     backup_root=$2 ;;
  *) echo 'Usage: sh scripts/backup-database.sh [--directory /absolute/private/path]' >&2; exit 2 ;;
esac
recovery_init_root
mkdir "$backup_root/.backup.lock" 2>/dev/null || {
  recovery_fail 'Another capture or stale lock exists; inspect it, do not remove it blindly'; exit 1;
}
printf 'pid=%s started_utc=%s\n' "$$" "$(date -u +%Y%m%dT%H%M%SZ)" > "$backup_root/.backup.lock/owner"
capture_pending=''
capture_app=''
capture_restart=false
capture_resume() {
  docker start "$capture_app" >/dev/null || return 1
  capture_wait=15
  while [ "$capture_wait" -gt 0 ]; do
    if [ "$(docker inspect --format '{{.State.Running}}' "$capture_app")" = true ] &&
      [ "$(source_psql -qAtc "SELECT count(*) > 0 FROM pg_stat_activity WHERE datname='gym_intel_dev' AND usename='gym_intel_app'")" = t ]; then
      return 0
    fi
    capture_wait=$((capture_wait - 1))
    sleep 1
  done
  return 1
}
cleanup_capture() {
  capture_status=$?
  trap - EXIT HUP INT TERM
  if [ "$capture_restart" = true ]; then
    capture_resume >/dev/null 2>&1 || {
      echo 'FAIL: app restart failed; restart the original app after investigating' >&2
      capture_status=1
    }
  fi
  if [ -n "$capture_pending" ] && [ -d "$capture_pending" ]; then
    # Preserve the unverified attempt and private logs for diagnosis; never let
    # a failed run remove earlier verified backups or silently count as success.
    printf 'Unverified attempt retained privately: %s\n' "$capture_pending" >&2
  fi
  rm -f "$backup_root/.backup.lock/owner" || capture_status=1
  rmdir "$backup_root/.backup.lock" 2>/dev/null || capture_status=1
  exit "$capture_status"
}
trap cleanup_capture EXIT
trap 'exit 1' HUP INT TERM
capture_postgres=$(docker compose ps -q postgres)
test -n "$capture_postgres"
capture_project=${RECOVERY_FIXTURE_PROJECT:-gym-intel-uae}
if [ "$capture_project" != gym-intel-uae ]; then
  # The integration driver may target only its own disposable fixture project.
  # This is not a general database/project override or a way to bypass guards.
  printf '%s\n' "$capture_project" | LC_ALL=C grep -Eq '^gym-intel-recovery-test-[0-9]+-[0-9]+$'
  test "$(docker inspect --format '{{index .Config.Labels "com.gym-intel.recovery.fixture"}}' "$capture_postgres")" = "$capture_project"
fi
test "$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$capture_postgres")" = "$capture_project"
test "$(docker inspect --format '{{.State.Running}}' "$capture_postgres")" = true
capture_app=$(docker compose ps -a -q app)
test -n "$capture_app"
test "$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$capture_app")" = "$capture_project"
source_psql() { docker exec -i "$capture_postgres" sh /opt/gym-intel/psql.sh "$@"; }
test "$(source_psql -qAtc 'SELECT current_database()')" = gym_intel_dev
test "$(source_psql -qAtc "SELECT count(*) FROM public.oban_jobs WHERE state IN ('available','scheduled','executing','retryable')")" = 0 || {
  recovery_fail 'Unfinished jobs exist; no app stop, capture or cancellation performed'; exit 1;
}
if [ "$(docker inspect --format '{{.State.Running}}' "$capture_app")" = true ]; then
  # Set restart intent BEFORE stop, so interruption during stop still resumes it.
  capture_restart=true
  echo 'Pausing the existing app briefly; PostgreSQL and Grafana remain running'
  docker stop --time 20 "$capture_app" >/dev/null
fi
# Recheck after shutdown. Operators must not submit jobs or make schema/data
# changes during capture; this checkpoint is not a global maintenance lock.
test "$(source_psql -qAtc "SELECT count(*) FROM public.oban_jobs WHERE state IN ('available','scheduled','executing','retryable')")" = 0 || {
  recovery_fail 'Jobs appeared during shutdown; capture refused'; exit 1;
}
capture_pending=$(mktemp -d "$backup_root/.pending-XXXXXX")
capture_image=$(docker inspect --format '{{.Image}}' "$capture_postgres")
printf '%s\n' "$capture_image" > "$capture_pending/image-id"
printf 'gym-intel-db-backup-v1\n' > "$capture_pending/format"
source_psql -qAt < "$project_dir/scripts/recovery/snapshot.sql" \
  > "$capture_pending/baseline.json" 2> "$capture_pending/capture.log"
docker exec "$capture_postgres" sh -ec '
  export PGPASSWORD="$(cat /run/secrets/postgres_password)"
  exec pg_dump --format=custom --no-password --username=gym_intel --dbname=gym_intel_dev
' > "$capture_pending/database.dump" 2>> "$capture_pending/capture.log"
source_psql -qAt < "$project_dir/scripts/recovery/snapshot.sql" \
  > "$capture_pending/after.json" 2>> "$capture_pending/capture.log"
cmp -s "$capture_pending/baseline.json" "$capture_pending/after.json" || {
  recovery_fail 'Source changed during capture; no verified backup published'; exit 1;
}
rm "$capture_pending/after.json"
recovery_sha "$capture_pending/database.dump" > "$capture_pending/archive.sha256"
recovery_sha "$capture_pending/baseline.json" > "$capture_pending/baseline.sha256"
if [ "$capture_restart" = true ]; then
  capture_resume || { recovery_fail 'App did not resume database connections'; exit 1; }
  capture_restart=false
  echo 'Original app restarted; verifying the backup separately'
fi
sh "$project_dir/scripts/verify-database-backup.sh" "$capture_pending"
printf 'gym-intel-restore-verified-v1 %s %s\n' \
  "$(cat "$capture_pending/archive.sha256")" "$(cat "$capture_pending/baseline.sha256")" \
  > "$capture_pending/verified"
capture_suffix=${capture_pending##*.pending-}
capture_published="$backup_root/backup-$(date -u +%Y%m%dT%H%M%SZ)-$capture_suffix"
test ! -e "$capture_published"
mv "$capture_pending" "$capture_published"
capture_pending=''
recovery_prune "$capture_published"
printf 'PASS: verified database backup: %s\n' "$capture_published"
printf 'Retention: latest seven verified backups; local-only, not separately encrypted.\n'

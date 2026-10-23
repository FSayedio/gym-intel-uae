#!/bin/sh
# One operator: submit -> await commit -> verified backup -> bounded cleanup.
# Never fetches websites, restores over live data, or broadens runtime grants.
set -eu
umask 077
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
. "$project_dir/scripts/recovery/common.sh"
case "$#" in
  1) backup_root="$HOME/Library/Application Support/Gym Intel UAE/backups" ;;
  3) test "$2" = --directory || { echo 'Usage: sh scripts/update-dashboard.sh data/file.csv [--directory /absolute/private/path]' >&2; exit 2; }
     backup_root=$3 ;;
  *) echo 'Usage: sh scripts/update-dashboard.sh data/file.csv [--directory /absolute/private/path]' >&2; exit 2 ;;
esac
case "$1" in data/*) ;; *) recovery_fail 'CSV must be under data/'; exit 2 ;; esac
case "$1" in *'/../'*|*'/..'|*'/./'*|*'/.'|*'//'*) recovery_fail 'Use a direct data/ path'; exit 2 ;; esac
test -f "$1" || { recovery_fail 'CSV does not exist'; exit 1; }
recovery_init_root
mkdir "$backup_root/.update.lock" 2>/dev/null || {
  recovery_fail 'Another update or stale update lock exists; inspect it, do not remove it blindly'; exit 1;
}
update_phase=preflight
cleanup_update() {
  update_status=$?
  trap - EXIT HUP INT TERM
  if [ "$update_status" != 0 ]; then
    printf 'FAIL: dashboard update stopped at %s. Data may already be committed; no rollback of a successful import is implied. Inspect job state before retrying.\n' "$update_phase" >&2
  fi
  for update_file in token owner submission.log backup state.from-backup; do
    rm -f "$backup_root/.update.lock/$update_file" || update_status=1
  done
  rmdir "$backup_root/.update.lock" || update_status=1
  exit "$update_status"
}
trap cleanup_update EXIT
trap 'exit 1' HUP INT TERM
printf 'pid=%s started_utc=%s\n' "$$" "$(date -u +%Y%m%dT%H%M%SZ)" > "$backup_root/.update.lock/owner"
openssl rand -hex 32 > "$backup_root/.update.lock/token"
GYM_INTEL_UPDATE_TOKEN=$(cat "$backup_root/.update.lock/token")
export GYM_INTEL_UPDATE_TOKEN
test ! -e "$backup_root/.backup.lock" || { recovery_fail 'Capture or stale backup lock exists'; exit 1; }
update_postgres=$(docker compose ps -q postgres)
test -n "$update_postgres"
update_project=${RECOVERY_FIXTURE_PROJECT:-gym-intel-uae}
if [ "$update_project" != gym-intel-uae ]; then
  printf '%s\n' "$update_project" | LC_ALL=C grep -Eq '^gym-intel-recovery-test-[0-9]+-[0-9]+$'
  test "$(docker inspect --format '{{index .Config.Labels "com.gym-intel.recovery.fixture"}}' "$update_postgres")" = "$update_project"
fi
test "$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$update_postgres")" = "$update_project"
update_app=$(docker compose ps -q app)
test -n "$update_app"
test "$(docker inspect --format '{{.State.Running}}' "$update_app")" = true
source_psql() { docker exec -i "$update_postgres" sh /opt/gym-intel/psql.sh "$@"; }
test "$(source_psql -qAtc 'SELECT current_database()')" = gym_intel_dev
test "$(source_psql -qAtc "SELECT count(*) FROM public.oban_jobs WHERE state IN ('available','scheduled','executing','retryable')")" = 0 || {
  recovery_fail 'Unfinished jobs exist; finish or investigate them before updating'; exit 1;
}

update_phase=import
echo 'Submitting one verified CSV and waiting for its exact job and committed fingerprint'
# This one-off process must EXIT before backup: no extra Repo/Oban peer is
# left running while the backup pauses only the long-running Compose app.
if ! docker compose run --rm --no-deps -e "IMPORT_CSV_PATH=/app/$1" \
  app bin/gym_intel eval 'GymIntel.Release.update()' \
  > "$backup_root/.update.lock/submission.log" 2>&1; then
  recovery_fail 'Import failed or timed out; inspect recent job state (not raw arguments)'; exit 1
fi
update_receipt=$(LC_ALL=C grep -E '^UPDATE_VERIFIED [0-9]+ [0-9a-f]{64}$' "$backup_root/.update.lock/submission.log")
test "$(printf '%s\n' "$update_receipt" | wc -l | tr -d ' ')" = 1
update_job=${update_receipt#UPDATE_VERIFIED }
update_sha=${update_job#* }
update_job=${update_job%% *}
printf 'Committed import verified: job %s, fingerprint %s\n' "$update_job" "$update_sha"
update_state=$(source_psql -qAt -f /opt/gym-intel-priv/update_state.sql \
  -c 'SELECT pg_temp.dashboard_update_state()')
printf '%s\n' "$update_state" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$'

update_phase=backup-verification
sh scripts/backup-database.sh --directory "$backup_root"
recovery_private_file "$backup_root/.update.lock/backup"
bundle=$(cat "$backup_root/.update.lock/backup")
case "$bundle" in "$backup_root"/backup-*) ;; *) recovery_fail 'Invalid backup receipt'; exit 1 ;; esac
recovery_check_verified
update_backup_hashes=''
for update_table in memberships membership_notes membership_imports oban_jobs; do
  update_table_hash=$(sed -n "/\"table\": \"$update_table\"/s/.*\"sha256\": \"\([0-9a-f]*\)\".*/\1/p" "$bundle/baseline.json")
  printf '%s\n' "$update_table_hash" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$'
  if [ -n "$update_backup_hashes" ]; then update_backup_hashes="$update_backup_hashes:"; fi
  update_backup_hashes="$update_backup_hashes$update_table_hash"
done
printf '%s' "$update_backup_hashes" > "$backup_root/.update.lock/state.from-backup"
test "$(recovery_sha "$backup_root/.update.lock/state.from-backup")" = "$update_state" || {
  recovery_fail 'Verified backup does not match prepared protected state; database cleanup refused'; exit 1;
}

update_phase=current-data-and-job-cleanup
echo 'Verified backup exists; checking unchanged database before transactional cleanup'
source_psql -qAt -v "expected_state=$update_state" -v "expected_job=$update_job" \
  -v "expected_csv=$update_sha" -f /opt/gym-intel-priv/update_state.sql \
  -f /opt/gym-intel-priv/update_cleanup.sql -f - <<'SQL'
BEGIN;
SELECT pg_temp.cleanup_dashboard_update(:'expected_state', :'expected_job'::bigint, :'expected_csv');
COMMIT;
SQL
update_phase=complete
echo 'PASS: import committed, backup restored and verified, current observations retained, at most two finished import jobs and two verified backups retained'
echo 'Grafana rereads PostgreSQL every 30 seconds while open; no websites were fetched'

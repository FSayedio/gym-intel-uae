#!/bin/sh
# Restore a trusted local bundle into an isolated throwaway PostgreSQL instance.
set -eu
umask 077
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
. "$project_dir/scripts/recovery/common.sh"
if [ "$#" -ne 1 ]; then
  echo 'Usage: sh scripts/verify-database-backup.sh /absolute/path/to/backup-directory' >&2
  exit 2
fi
bundle=$1
case "$bundle" in /*) ;; *) recovery_fail 'Backup path must be absolute' || exit 2 ;; esac
printf '%s\n' "${bundle##*/}" | LC_ALL=C grep -Eq '^(backup-[0-9]{8}T[0-9]{6}Z-|\.pending-)[A-Za-z0-9]{6}$' || {
  recovery_fail 'Expected a managed backup directory' || exit 2;
}
case "$bundle" in */../*|*/./*|*//*) recovery_fail 'Traversal backup path refused' || exit 2 ;; esac
backup_root=${bundle%/*}
recovery_private_directory "$backup_root"
recovery_private_file "$backup_root/.gym-intel-backups-v1"
test "$(cat "$backup_root/.gym-intel-backups-v1")" = gym-intel-backups-v1
recovery_check_bundle
test "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$recovery_image")" = linux/arm64
if [ -e "$bundle/restore.log" ] || [ -L "$bundle/restore.log" ]; then
  recovery_private_file "$bundle/restore.log"
fi
: > "$bundle/restore.log"
restore_temp_base=${TMPDIR:-/tmp}
restore_temp_base=${restore_temp_base%/}
restore_tmp=$(mktemp -d "$restore_temp_base/gym-intel-restore.XXXXXX")
restore_name="gym-intel-restore-$(date +%s)-$$"
restore_id=''
restore_run="$(date +%s)-$$"
cleanup_restore() {
  restore_status=$?
  trap - EXIT HUP INT TERM
  if [ -z "$restore_id" ]; then
    # docker run can create a container then fail before returning its ID.
    # Resolve only our generated name; the label check still gates removal.
    restore_id=$(docker inspect --format '{{.Id}}' "$restore_name" 2>/dev/null || true)
  fi
  if [ -n "$restore_id" ]; then
    if [ "$(docker inspect --format '{{index .Config.Labels "com.gym-intel.recovery"}}' "$restore_id" 2>/dev/null)" = "$restore_run" ]; then
      docker rm -f "$restore_id" >/dev/null 2>&1 || restore_status=1
    else
      echo "FAIL: inspect temporary container $restore_name; cleanup identity check failed" >&2
      restore_status=1
    fi
  fi
  rm -f "$restore_tmp/password" "$restore_tmp/migrator_password" \
    "$restore_tmp/app_password" "$restore_tmp/reader_password" \
    "$restore_tmp/restored.json" "$restore_tmp/denied.log" || restore_status=1
  rmdir "$restore_tmp" 2>/dev/null || restore_status=1
  if [ "$restore_status" -ne 0 ]; then
    echo "FAIL: restore verification; inspect private log $bundle/restore.log" >&2
  fi
  exit "$restore_status"
}
trap cleanup_restore EXIT
trap 'exit 1' HUP INT TERM
openssl rand -hex -out "$restore_tmp/password" 32
for restore_secret in migrator_password app_password reader_password; do
  openssl rand -hex -out "$restore_tmp/$restore_secret" 32
done
# Private host directory is 700; initdb's non-root user needs its one mounted file.
chmod 644 "$restore_tmp/password"
printf 'Restoring into an isolated PostgreSQL container (no network or live mounts)\n'
restore_id=$(docker run --detach --platform linux/arm64 --pull never \
  --name "$restore_name" --label "com.gym-intel.recovery=$restore_run" \
  --network none --memory 768m --cpus 1 --pids-limit 128 \
  --tmpfs /var/lib/postgresql:rw,nosuid,noexec,size=512m \
  -e POSTGRES_USER=gym_intel -e POSTGRES_DB=postgres \
  -e POSTGRES_PASSWORD_FILE=/run/secrets/restore_password \
  -e POSTGRES_HOST_AUTH_METHOD=scram-sha-256 \
  -e 'POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256 --auth-local=scram-sha-256' \
  -v "$restore_tmp/password:/run/secrets/restore_password:ro" \
  -v "$restore_tmp/migrator_password:/run/secrets/migrator_password:ro" \
  -v "$restore_tmp/app_password:/run/secrets/app_password:ro" \
  -v "$restore_tmp/reader_password:/run/secrets/reader_password:ro" \
  -v "$bundle/database.dump:/restore/database.dump:ro" \
  "$recovery_image" 2>> "$bundle/restore.log")

restore_psql() {
  docker exec -i "$restore_id" sh -ec '
    role=$1; database=$2; shift 2
    case "$role" in
      gym_intel) password_file=restore_password ;;
      gym_intel_migrator) password_file=migrator_password ;;
      gym_intel_app) password_file=app_password ;;
      gym_intel_grafana) password_file=reader_password ;;
      *) exit 2 ;;
    esac
    export PGPASSWORD="$(cat "/run/secrets/$password_file")" PGCONNECT_TIMEOUT=3
    exec psql -X --no-password --host=127.0.0.1 --username="$role" \
      --dbname="$database" -v ON_ERROR_STOP=1 "$@"
  ' sh "$@"
}
restore_wait=40
until restore_psql gym_intel postgres -qAtc 'SELECT 1' >/dev/null 2>> "$bundle/restore.log"; do
  restore_wait=$((restore_wait - 1))
  test "$restore_wait" -gt 0 || { recovery_fail 'Isolated PostgreSQL did not become ready'; exit 1; }
  sleep 1
done
docker exec -i "$restore_id" sh -ec '
  export PGPASSWORD="$(cat /run/secrets/restore_password)"
  export RECOVERY_MIGRATOR_PASSWORD="$(cat /run/secrets/migrator_password)"
  export RECOVERY_APP_PASSWORD="$(cat /run/secrets/app_password)"
  export RECOVERY_READER_PASSWORD="$(cat /run/secrets/reader_password)"
  exec psql -X --no-password --host=127.0.0.1 --username=gym_intel \
    --dbname=postgres -q -v ON_ERROR_STOP=1
' < "$project_dir/scripts/recovery/bootstrap.sql" >> "$bundle/restore.log" 2>&1
docker exec "$restore_id" sh -ec '
  export PGPASSWORD="$(cat /run/secrets/restore_password)"
  exec pg_restore --exit-on-error --single-transaction --no-password \
    --host=127.0.0.1 --username=gym_intel --dbname=gym_intel_dev /restore/database.dump
' >> "$bundle/restore.log" 2>&1
restore_psql gym_intel gym_intel_dev -qAt \
  < "$project_dir/scripts/recovery/snapshot.sql" \
  > "$restore_tmp/restored.json" 2>> "$bundle/restore.log"
cmp -s "$bundle/baseline.json" "$restore_tmp/restored.json" || {
  diff -u "$bundle/baseline.json" "$restore_tmp/restored.json" >> "$bundle/restore.log" || true
  recovery_fail 'Restored data/schema/privileges/sequences differ from the captured baseline'; exit 1;
}

restore_denied() {
  if restore_psql "$1" gym_intel_dev --set=VERBOSITY=verbose \
    -c "BEGIN; $2; ROLLBACK;" > "$restore_tmp/denied.log" 2>&1; then
    recovery_fail "Restored $1 unexpectedly permitted a forbidden operation"; return 1
  fi
  grep -q '42501:' "$restore_tmp/denied.log" || {
    cat "$restore_tmp/denied.log" >> "$bundle/restore.log"
    recovery_fail 'Permission probe failed for an unrelated reason'; return 1;
  }
}
restore_denied gym_intel_app 'CREATE TABLE public.recovery_forbidden (id integer)'
restore_denied gym_intel_app 'UPDATE public.memberships SET notes=notes WHERE false'
restore_denied gym_intel_app 'DELETE FROM public.membership_notes WHERE false'
restore_denied gym_intel_app 'SET ROLE gym_intel_migrator'
restore_denied gym_intel_app 'SELECT count(*) FROM pg_authid'
restore_denied gym_intel_grafana 'SELECT notes FROM public.memberships LIMIT 0'
restore_denied gym_intel_grafana 'SELECT notes FROM public.membership_notes LIMIT 0'
restore_denied gym_intel_grafana 'SELECT args FROM public.oban_jobs LIMIT 0'
restore_denied gym_intel_grafana 'SELECT content_sha256 FROM public.membership_imports LIMIT 0'
restore_denied gym_intel_grafana 'DELETE FROM public.dashboard_memberships WHERE false'
restore_psql gym_intel_grafana gym_intel_dev -qAtc \
  'SELECT count(*) FROM public.dashboard_memberships' >> "$bundle/restore.log" 2>&1
restore_psql gym_intel_migrator gym_intel_dev -q -c \
  'BEGIN; CREATE TABLE public.recovery_probe (id integer); DROP TABLE public.recovery_probe; ROLLBACK;' \
  >> "$bundle/restore.log" 2>&1
restore_psql gym_intel_app gym_intel_dev -q \
  < "$project_dir/scripts/recovery/probes.sql" >> "$bundle/restore.log" 2>&1
printf 'PASS: complete restored baseline, actual role denials, identity/initial-note probes; no worker started\n'

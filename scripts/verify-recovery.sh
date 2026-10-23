#!/bin/sh
# Exercise the REAL backup entrypoint against synthetic, disposable services.
# Never points the backup command at the development Compose project or secrets.
set -eu
umask 077
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
. "$project_dir/scripts/recovery/common.sh"
fixture_temp_base=${TMPDIR:-/tmp}
fixture_temp_base=${fixture_temp_base%/}
fixture_tmp=$(mktemp -d "$fixture_temp_base/gym-intel-recovery-test.XXXXXX")
fixture_project="gym-intel-recovery-test-$(date +%s)-$$"
fixture_compose() {
  RECOVERY_FIXTURE_PASSWORD_FILE="$fixture_tmp/password" \
  RECOVERY_FIXTURE_PROJECT="$fixture_project" \
  docker compose --file "$project_dir/scripts/recovery/fixture.compose.yaml" \
    --project-name "$fixture_project" "$@"
}
fixture_backup_command() {
  COMPOSE_FILE="$project_dir/scripts/recovery/fixture.compose.yaml" \
  COMPOSE_PROJECT_NAME="$fixture_project" \
  RECOVERY_FIXTURE_PASSWORD_FILE="$fixture_tmp/password" \
  RECOVERY_FIXTURE_PROJECT="$fixture_project" \
  sh scripts/backup-database.sh --directory "$fixture_tmp/backups"
}
fixture_cleanup() {
  fixture_status=$?
  trap - EXIT HUP INT TERM
  fixture_compose down >> "$fixture_tmp/fixture.log" 2>&1 || fixture_status=1
  if [ "$fixture_status" = 0 ]; then
    # Exact mktemp-created test directory: only synthetic data and disposable
    # passwords. Never use the real backup root or a user-supplied cleanup path.
    case "${fixture_tmp##*/}" in
      gym-intel-recovery-test.??????)
        test ! -L "$fixture_tmp" && rm -rf -- "$fixture_tmp" || fixture_status=1 ;;
      *) fixture_status=1 ;;
    esac
  else
    printf 'FAIL: synthetic recovery check; private fixture evidence: %s\n' "$fixture_tmp" >&2
  fi
  exit "$fixture_status"
}
trap fixture_cleanup EXIT
trap 'exit 1' HUP INT TERM
openssl rand -hex -out "$fixture_tmp/password" 32
chmod 644 "$fixture_tmp/password"
echo 'Starting isolated synthetic source PostgreSQL; no host port or development volume'
fixture_compose up -d --wait postgres >> "$fixture_tmp/fixture.log" 2>&1
fixture_compose exec -T postgres sh /opt/gym-intel/configure-roles.sh \
  >> "$fixture_tmp/fixture.log" 2>&1
fixture_compose run --rm --no-deps -e DATABASE_USER=gym_intel_migrator \
  app bin/gym_intel eval 'GymIntel.Release.migrate()' >> "$fixture_tmp/fixture.log" 2>&1
fixture_compose exec -T postgres sh /opt/gym-intel/configure-roles.sh \
  >> "$fixture_tmp/fixture.log" 2>&1
fixture_compose exec -T postgres sh /opt/gym-intel/psql.sh \
  < scripts/recovery/fixture.sql >> "$fixture_tmp/fixture.log" 2>&1
fixture_compose up -d --wait app >> "$fixture_tmp/fixture.log" 2>&1

echo 'Capturing and restoring the synthetic database through the real operator command'
fixture_backup_command
fixture_backup=''
for fixture_candidate in "$fixture_tmp/backups"/backup-*; do
  test -z "$fixture_backup"
  test -d "$fixture_candidate"
  fixture_backup=$fixture_candidate
done
test -n "$fixture_backup"
bundle=$fixture_backup
recovery_check_verified
fixture_original_sha=$(recovery_sha "$fixture_backup/database.dump")

echo 'Checking corrupted archives fail before use and cannot replace the good backup'
fixture_bad="$fixture_tmp/backups/.pending-BAD001"
mkdir "$fixture_bad"
for fixture_file in database.dump baseline.json archive.sha256 baseline.sha256 image-id format; do
  cp "$fixture_backup/$fixture_file" "$fixture_bad/$fixture_file"
done
printf 'BROKEN ARCHIVE\n' > "$fixture_bad/database.dump"
if sh scripts/verify-database-backup.sh "$fixture_bad" > "$fixture_tmp/corrupt.log" 2>&1; then
  recovery_fail 'Corrupt archive was accepted'; exit 1
fi
grep -q 'Archive checksum mismatch' "$fixture_tmp/corrupt.log"
# A recomputed checksum is not restore proof either: pg_restore must reject it.
recovery_sha "$fixture_bad/database.dump" > "$fixture_bad/archive.sha256"
if sh scripts/verify-database-backup.sh "$fixture_bad" > "$fixture_tmp/corrupt-restore.log" 2>&1; then
  recovery_fail 'Invalid archive with recomputed checksum was accepted'; exit 1
fi
grep -Eq 'pg_restore: (error|fatal):' "$fixture_bad/restore.log"
test ! -e "$fixture_bad/verified"

echo 'Checking a weaker restored role fails despite matching source checksums'
fixture_compose exec -T postgres sh /opt/gym-intel/psql.sh \
  -c 'GRANT UPDATE ON public.memberships TO gym_intel_app' >> "$fixture_tmp/fixture.log" 2>&1
if fixture_backup_command > "$fixture_tmp/weak-role.log" 2>&1; then
  recovery_fail 'Weaker runtime permissions were accepted'; exit 1
fi
grep -q 'unexpectedly permitted' "$fixture_tmp/weak-role.log"
fixture_compose exec -T postgres sh /opt/gym-intel/psql.sh \
  -c 'REVOKE UPDATE ON public.memberships FROM gym_intel_app' >> "$fixture_tmp/fixture.log" 2>&1
test "$(recovery_sha "$fixture_backup/database.dump")" = "$fixture_original_sha"
test "$(fixture_compose exec -T postgres sh /opt/gym-intel/psql.sh -qAtc \
  "SELECT concat((SELECT count(*) FROM memberships),',',(SELECT count(*) FROM membership_notes),',',(SELECT count(*) FROM membership_imports))")" = '1,1,1'
fixture_app=$(fixture_compose ps -q app)
test "$(docker inspect --format '{{.State.Running}}' "$fixture_app")" = true
bundle=$fixture_backup
recovery_check_verified
printf 'PASS: synthetic full-database capture/restore, live app resume, corrupt rejection, role checks and good-backup preservation\n'

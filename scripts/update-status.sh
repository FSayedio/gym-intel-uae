#!/bin/sh
# Read-only saved evidence. No Docker, directory initialization or repairs.
set -eu
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
. "$project_dir/scripts/recovery/common.sh"
. "$project_dir/scripts/status/common.sh"
case "$#" in
  0) backup_root="$HOME/Library/Application Support/Gym Intel UAE/backups" ;;
  2) test "$1" = --directory || { echo 'Usage: sh scripts/update-status.sh [--directory /absolute/private/path]' >&2; exit 2; }
     backup_root=$2 ;;
  *) echo 'Usage: sh scripts/update-status.sh [--directory /absolute/private/path]' >&2; exit 2 ;;
esac
case "$backup_root" in
  /*) ;; *) recovery_fail 'Status directory must be absolute'; exit 2 ;;
esac
case "$backup_root" in
  /|"$HOME"|"$project_dir"|"$project_dir"/*|*/../*|*/..|*/./*|*/.|*//*)
    recovery_fail 'Refusing broad, repository or traversal status path'; exit 2 ;;
esac
if [ ! -e "$backup_root" ] && [ ! -L "$backup_root" ]; then
  echo 'No saved update reports. This is not evidence that no earlier import ran.'
  exit 0
fi
recovery_private_directory "$backup_root"
backup_root=$(cd "$backup_root" && pwd -P)
case "$backup_root" in
  /|"$HOME"|"$project_dir"|"$project_dir"/*)
    recovery_fail 'Canonical status root is broad or inside the repository'; exit 2 ;;
esac
recovery_private_file "$backup_root/.gym-intel-backups-v1"
test "$(cat "$backup_root/.gym-intel-backups-v1")" = gym-intel-backups-v1
if [ -e "$backup_root/.update.lock" ] || [ -L "$backup_root/.update.lock" ]; then
  echo 'Update lock exists: work may be active or interrupted. Do not infer process liveness or remove it blindly.'
fi
if [ ! -e "$backup_root/update-reports" ] && [ ! -L "$backup_root/update-reports" ]; then
  echo 'No saved update reports. This is not evidence that no earlier import ran.'
  exit 0
fi
status_check_root
status_names=$(status_scan)
status_count=0
for status_name in $(printf '%s\n' "$status_names" | LC_ALL=C sort -r); do
  status_count=$((status_count + 1))
  [ "$status_count" -le 3 ] || break
  status_render "$status_root/$status_name"
  printf '\n'
done
if [ "$status_count" = 0 ]; then echo 'No saved update reports; earlier imports may exist.'; fi

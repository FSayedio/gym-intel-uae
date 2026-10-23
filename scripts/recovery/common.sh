#!/bin/sh
# Sourced by recovery entrypoints. No work occurs merely by sourcing this file.

recovery_fail() { printf 'FAIL: %s\n' "$*" >&2; return 1; }

recovery_sha() {
  recovery_digest=$(openssl dgst -sha256 -r "$1") || return 1
  recovery_digest=${recovery_digest%% *}
  printf '%s\n' "$recovery_digest" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' || return 1
  printf '%s\n' "$recovery_digest"
}

recovery_mode() {
  # macOS and GNU stat have different flags; never print file contents.
  if [ "$(uname -s)" = Darwin ]; then stat -f '%Lp' "$1";
  else stat -c '%a' "$1"; fi
}

recovery_owned() {
  if [ "$(uname -s)" = Darwin ]; then recovery_uid=$(stat -f '%u' "$1");
  else recovery_uid=$(stat -c '%u' "$1"); fi
  [ "$recovery_uid" = "$(id -u)" ] || recovery_fail 'Recovery path has a different owner'
}

recovery_private_directory() {
  [ -d "$1" ] && [ ! -L "$1" ] || recovery_fail 'Expected a real recovery directory' || return 1
  recovery_owned "$1" || return 1
  [ "$(recovery_mode "$1")" = 700 ] || recovery_fail 'Recovery directory must have mode 700'
}

recovery_private_file() {
  [ -f "$1" ] && [ ! -L "$1" ] || recovery_fail 'Expected a real recovery file' || return 1
  recovery_owned "$1" || return 1
  [ "$(recovery_mode "$1")" = 600 ] || recovery_fail 'Recovery file must have mode 600'
}

recovery_init_root() {
  case "$backup_root" in /*) ;; *) recovery_fail 'Backup directory must be absolute'; return 1 ;; esac
  case "$backup_root" in
    /|"$HOME"|"$project_dir"|"$project_dir"/*|*/../*|*/..|*/./*|*/.|*//*)
      recovery_fail 'Refusing a broad, repository or traversal backup path'; return 1 ;;
  esac
  [ ! -L "$backup_root" ] || { recovery_fail 'Backup directory cannot be a symlink'; return 1; }
  if [ ! -e "$backup_root" ]; then mkdir -p "$backup_root"; chmod 700 "$backup_root"; fi
  recovery_private_directory "$backup_root" || return 1
  backup_root=$(cd "$backup_root" && pwd -P)
  case "$backup_root" in /|"$HOME"|"$project_dir"|"$project_dir"/*)
    recovery_fail 'Canonical backup path is broad or inside the repository'; return 1 ;;
  esac
  if [ ! -e "$backup_root/.gym-intel-backups-v1" ]; then
    [ -z "$(ls -A "$backup_root")" ] || { recovery_fail 'Unmanaged backup directory is not empty'; return 1; }
    printf 'gym-intel-backups-v1\n' > "$backup_root/.gym-intel-backups-v1"
  fi
  recovery_private_file "$backup_root/.gym-intel-backups-v1" || return 1
  [ "$(cat "$backup_root/.gym-intel-backups-v1")" = gym-intel-backups-v1 ] || recovery_fail 'Invalid backup root marker'
}

recovery_check_bundle() {
  recovery_private_directory "$bundle" || return 1
  for recovery_file in database.dump baseline.json image-id archive.sha256 baseline.sha256 format; do
    recovery_private_file "$bundle/$recovery_file" || return 1
  done
  [ "$(cat "$bundle/format")" = gym-intel-db-backup-v1 ] || { recovery_fail 'Unknown backup format'; return 1; }
  [ "$(recovery_sha "$bundle/database.dump")" = "$(cat "$bundle/archive.sha256")" ] || {
    recovery_fail 'Archive checksum mismatch'; return 1;
  }
  [ "$(recovery_sha "$bundle/baseline.json")" = "$(cat "$bundle/baseline.sha256")" ] || {
    recovery_fail 'Baseline checksum mismatch'; return 1;
  }
  recovery_image=$(cat "$bundle/image-id")
  printf '%s\n' "$recovery_image" | LC_ALL=C grep -Eq '^sha256:[0-9a-f]{64}$' || {
    recovery_fail 'Invalid recorded PostgreSQL image ID'; return 1;
  }
}

recovery_check_verified() {
  recovery_check_bundle || return 1
  recovery_private_file "$bundle/verified" || return 1
  [ "$(cat "$bundle/verified")" = "gym-intel-restore-verified-v1 $(cat "$bundle/archive.sha256") $(cat "$bundle/baseline.sha256")" ] ||
    recovery_fail 'Verification marker does not match this backup'
}

recovery_prune() {
  # Called only under the backup lock, after a new verified backup is published.
  # Validate every candidate BEFORE removing any. Never recurse or follow links.
  recovery_names=''
  for recovery_candidate in "$backup_root"/backup-*; do
    [ -e "$recovery_candidate" ] || [ -L "$recovery_candidate" ] || continue
    recovery_name=${recovery_candidate##*/}
    printf '%s\n' "$recovery_name" | LC_ALL=C grep -Eq '^backup-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]{6}$' || {
      recovery_fail 'Unexpected backup name; retention stopped'; return 1;
    }
    bundle=$recovery_candidate
    recovery_check_verified || return 1
    for recovery_entry in "$bundle"/* "$bundle"/.[!.]* "$bundle"/..?*; do
      [ -e "$recovery_entry" ] || [ -L "$recovery_entry" ] || continue
      case "${recovery_entry##*/}" in
        database.dump|baseline.json|image-id|archive.sha256|baseline.sha256|format|verified|capture.log|restore.log) ;;
        *) recovery_fail 'Unexpected backup content; retention stopped'; return 1 ;;
      esac
      recovery_private_file "$recovery_entry" || return 1
    done
    recovery_names="${recovery_names}${recovery_name}
"
  done
  if [ -n "${1:-}" ]; then
    recovery_latest=$(printf '%s' "$recovery_names" | sed '/^$/d' | LC_ALL=C sort | tail -n 1)
    [ "$recovery_latest" = "${1##*/}" ] || {
      recovery_fail 'Backup clock/order moved backwards; retention stopped without deletion'; return 1;
    }
  fi
  recovery_count=$(printf '%s' "$recovery_names" | sed '/^$/d' | wc -l | tr -d ' ')
  recovery_remove=$((recovery_count - 2))
  [ "$recovery_remove" -gt 0 ] || return 0
  # Names above are strictly ASCII identifiers, so this controlled word split
  # cannot turn a pathname with spaces/newlines into a different target.
  for recovery_name in $(printf '%s' "$recovery_names" | sed '/^$/d' | LC_ALL=C sort); do
    [ "$recovery_remove" -gt 0 ] || break
    recovery_target="$backup_root/$recovery_name"
    for recovery_file in database.dump baseline.json image-id archive.sha256 baseline.sha256 format verified capture.log restore.log; do
      rm -f "$recovery_target/$recovery_file" || return 1
    done
    rmdir "$recovery_target" || return 1
    recovery_remove=$((recovery_remove - 1))
  done
}

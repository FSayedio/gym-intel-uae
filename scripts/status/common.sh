#!/bin/sh
# Private fixed-schema records; never source/eval saved status.
status_check_root() {
  recovery_private_directory "$backup_root" || return 1
  recovery_private_file "$backup_root/.gym-intel-backups-v1" || return 1
  [ "$(cat "$backup_root/.gym-intel-backups-v1")" = gym-intel-backups-v1 ] || return 1
  status_root="$backup_root/update-reports"
  recovery_private_directory "$status_root" || return 1
  recovery_private_file "$status_root/.gym-intel-status-v1" || return 1
  [ "$(cat "$status_root/.gym-intel-status-v1")" = gym-intel-status-v1 ] || return 1
}

status_init() {
  status_root="$backup_root/update-reports"
  if [ ! -e "$status_root" ] && [ ! -L "$status_root" ]; then
    mkdir "$status_root" || return 1
    chmod 700 "$status_root" || return 1
    printf 'gym-intel-status-v1\n' > "$status_root/.gym-intel-status-v1" || return 1
  fi
  status_check_root
}

status_validate() {
  recovery_private_file "$1" || return 1
  [ "$(wc -c < "$1" | tr -d ' ')" -le 2048 ] || { recovery_fail 'Oversized status record; no contents displayed'; return 1; }
  LC_ALL=C awk '
    NR == 1 { if ($0 != "format=gym-intel-update-status-v1") exit 1; next }
    NR == 2 { if ($0 !~ /^sequence=[0-9]{9}$/) exit 1; sequence = substr($0, 10) + 0; next }
    NR == 3 { if ($0 !~ /^started_utc=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/) exit 1; next }
    NR == 4 { if ($0 !~ /^finished_utc=(unknown|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)$/) exit 1; finished = substr($0, 14); next }
    NR == 5 { if ($0 !~ /^outcome=(in_progress_or_interrupted|succeeded|failed|interrupted)$/) exit 1; outcome = substr($0, 9); next }
    NR == 6 { if ($0 !~ /^phase=(preflight|import|backup-verification|current-data-and-job-cleanup|housekeeping|report-retention|complete)$/) exit 1; phase = substr($0, 7); next }
    NR >= 7 && NR <= 11 {
      split("import backup data_cleanup housekeeping report_retention", keys, " ")
      split($0, pair, "=")
      if (pair[1] != keys[NR - 6] || pair[2] !~ /^(not_attempted|unknown|confirmed)$/ || $0 != pair[1] "=" pair[2]) exit 1
      stages[pair[1]] = pair[2]
      next
    }
    NR == 12 { if ($0 !~ /^job_id=(unknown|[1-9][0-9]{0,18})$/) exit 1; next }
    NR == 13 { if ($0 !~ /^fingerprint=(unknown|[0-9a-f]{64})$/) exit 1; next }
    NR == 14 { if ($0 !~ /^backup_bundle=(unknown|backup-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]{6})$/) exit 1; next }
    NR == 15 { if ($0 !~ /^exit_code=(unknown|[0-9]{1,3})$/) exit 1; code = substr($0, 11); next }
    NR > 15 { exit 1 }
    END {
      if (NR != 15 || sequence < 1 || (code != "unknown" && code + 0 > 255)) exit 1
      if (stages["data_cleanup"] == "confirmed" && (stages["import"] != "confirmed" || stages["backup"] != "confirmed")) exit 1
      if (outcome == "succeeded") {
        if (phase != "complete" || code != "0" || finished == "unknown") exit 1
        for (stage in stages) if (stages[stage] != "confirmed") exit 1
      }
    }
  ' "$1" || { recovery_fail 'Malformed status record; no contents displayed'; return 1; }
}

status_value() { sed -n "s/^$1=//p" "$2"; }

status_scan() {
  status_check_root || return 1
  # Validate ALL files before selecting or deleting any; never sweep unknowns.
  for status_entry in "$status_root"/* "$status_root"/.[!.]* "$status_root"/..?*; do
    [ -e "$status_entry" ] || [ -L "$status_entry" ] || continue
    status_name=${status_entry##*/}
    case "$status_name" in
      .gym-intel-status-v1) continue ;;
      report-?????????.txt)
        printf '%s\n' "$status_name" | LC_ALL=C grep -Eq '^report-[0-9]{9}\.txt$' || return 1
        status_validate "$status_entry" || return 1
        [ "$status_name" = "report-$(status_value sequence "$status_entry").txt" ] || return 1
        printf '%s\n' "$status_name" ;;
      *) recovery_fail 'Unexpected status directory content; no sweep performed'; return 1 ;;
    esac
  done
}

status_reserve() {
  status_names=$(status_scan) || return 1
  status_last=$(printf '%s\n' "$status_names" | LC_ALL=C sort | tail -n 1)
  status_number=${status_last#report-}
  status_number=${status_number%.txt}
  status_number=$(printf '%s' "$status_number" | sed 's/^0*//')
  status_number=${status_number:-0}
  [ "$status_number" -lt 999999999 ] || { recovery_fail 'Status sequence exhausted'; return 1; }
  update_report_sequence=$(printf '%09d' "$((status_number + 1))")
  update_report_path="$status_root/report-$update_report_sequence.txt"
}

status_write() {
  status_check_root || return 1
  if [ "${update_report_initialized:-false}" = true ] && [ ! -e "$update_report_path" ]; then
    recovery_fail 'This status slot was removed; refusing to resurrect an obsolete report'; return 1
  fi
  if [ -e "$update_report_path" ] || [ -L "$update_report_path" ]; then
    status_validate "$update_report_path" || return 1
  fi
  status_temporary=$(mktemp "$status_root/.next-XXXXXX") || return 1
  if ! printf 'format=gym-intel-update-status-v1\nsequence=%s\nstarted_utc=%s\nfinished_utc=%s\noutcome=%s\nphase=%s\nimport=%s\nbackup=%s\ndata_cleanup=%s\nhousekeeping=%s\nreport_retention=%s\njob_id=%s\nfingerprint=%s\nbackup_bundle=%s\nexit_code=%s\n' \
    "$update_report_sequence" "$update_started" "$update_finished" "$update_outcome" "$update_phase" \
    "$update_import" "$update_backup" "$update_cleanup" "$update_housekeeping" "$update_report_retention" \
    "$update_job" "$update_sha" "$update_backup_name" "$update_exit_code" > "$status_temporary"; then
    rm -f "$status_temporary"; return 1
  fi
  if ! status_validate "$status_temporary"; then rm -f "$status_temporary"; return 1; fi
  if ! mv "$status_temporary" "$update_report_path"; then rm -f "$status_temporary"; return 1; fi
  update_report_initialized=true
}

status_prune() {
  status_validate "$update_report_path" || return 1
  status_names=$(status_scan) || return 1
  status_active=''
  if [ -e "$backup_root/.update.lock/attempt" ]; then
    recovery_private_directory "$backup_root/.update.lock" || return 1
    recovery_private_file "$backup_root/.update.lock/attempt" || return 1
    status_active=$(cat "$backup_root/.update.lock/attempt")
    printf '%s\n' "$status_active" | LC_ALL=C grep -Eq '^[0-9]{9}$' || return 1
  fi
  status_count=0
  for status_name in $(printf '%s\n' "$status_names" | LC_ALL=C sort -r); do
    [ "$status_name" = "report-$status_active.txt" ] && continue
    status_count=$((status_count + 1))
    [ "$status_count" -le 2 ] || rm "$status_root/$status_name" || return 1
  done
}

status_render() {
  status_validate "$1" || return 1
  awk -F= '
    $1 == "sequence" { print "Update: " $2 }
    $1 == "started_utc" { print "Started (UTC): " $2 }
    $1 == "finished_utc" { print "Finished (UTC): " $2 }
    $1 == "outcome" { outcome = $2; print "Outcome: " $2 }
    $1 == "phase" { phase = $2; print "Last observed phase: " $2 }
    $1 == "import" { imported = $2; print "Import commit: " $2 }
    $1 == "backup" { print "Backup verification: " $2 }
    $1 == "data_cleanup" { print "Data/job cleanup commit: " $2 }
    $1 == "housekeeping" { housekeeping = $2; print "Lock housekeeping: " $2 }
    $1 == "report_retention" { print "Report retention: " $2 }
    $1 == "job_id" { print "Job ID: " $2 }
    $1 == "exit_code" { print "Exit code: " $2 }
    END {
      if (outcome == "succeeded") print "Next: none; this is saved evidence, not a fresh health check."
      else if (housekeeping != "confirmed") print "Next: inspect lock/process state and the failed phase; do not remove locks blindly."
      else if (phase == "import" && imported == "not_attempted") print "Next: correct input/path validation before submitting again; this attempt did not queue a job."
      else if (phase == "import") print "Next: inspect job/fingerprint evidence; an interrupted import may have committed."
      else if (phase == "backup-verification") print "Next: inspect backup verification/publication; a failed command may have published a copy."
      else if (phase == "current-data-and-job-cleanup") print "Next: inspect current database evidence before retrying; COMMIT outcome may be unknown."
      else print "Next: investigate the recorded phase/storage before retrying."
      if (outcome == "in_progress_or_interrupted") print "Note: this file does not prove the process is still running; interruption may have bypassed final reporting."
    }
  ' "$1"
}

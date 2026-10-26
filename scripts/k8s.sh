#!/bin/sh
# Explicit backend choice prevents accidentally operating on the Compose copy.
set -eu
project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"
export GYM_INTEL_BACKEND=kubernetes
. scripts/kubernetes/common.sh
action=${1:-help}
test "$#" = 0 || shift
case "$action" in
  bootstrap) exec sh scripts/kubernetes/bootstrap.sh "$@" ;;
  prepare) exec sh scripts/kubernetes/deploy.sh "$@" ;;
  *) kube_guard ;;
esac
backup_root="$HOME/Library/Application Support/Gym Intel UAE/kubernetes-backups"
case "$action" in
  status) kube get pods,pvc,services; sh scripts/update-status.sh --directory "$backup_root" ;;
  kubectl) kube "$@" ;;
  psql) kube_psql "$@" ;;
  roles) kube exec postgres-0 -- sh /opt/gym-intel/configure-roles.sh ;;
  restore) exec sh scripts/kubernetes/restore.sh "$@" ;;
  migrate) sh scripts/kubernetes/task.sh migrate; kube exec postgres-0 -- sh /opt/gym-intel/configure-roles.sh ;;
  start) kube_resume; kube scale deployment/grafana --replicas=1; kube rollout status deployment/grafana --timeout=180s ;;
  pause) kube_pause ;;
  import) exec sh scripts/kubernetes/task.sh enqueue "$@" ;;
  source-check|source-status|source-ack) exec sh scripts/kubernetes/task.sh "$action" "$@" ;;
  update) test "$#" = 1; exec sh scripts/update-dashboard.sh "$1" --directory "$backup_root" ;;
  backup) exec sh scripts/backup-database.sh --directory "$backup_root" ;;
  permissions) exec sh scripts/verify-permissions.sh ;;
  tests|dashboard-check)
    if [ "$action" = tests ]; then exec sh scripts/kubernetes/checks.sh tests; fi
    exec sh scripts/kubernetes/checks.sh dashboard ;;
  *) echo 'Usage: sh scripts/k8s.sh bootstrap|prepare|roles|migrate|start|pause|status|psql|kubectl|import CSV|update CSV|backup|permissions|source-check|source-status|source-ack ID HASH' >&2; exit 2 ;;
esac

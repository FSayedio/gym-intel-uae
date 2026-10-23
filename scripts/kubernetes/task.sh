#!/bin/sh
# Short-lived, bounded pod: never mount the owner password into application code.
set -eu
umask 077
project_dir=$(cd "$(dirname "$0")/../.." && pwd)
cd "$project_dir"
. scripts/kubernetes/common.sh
kube_guard
action=${1:-}
case "$action" in
  migrate) role=gym_intel_migrator; secret=migrator-password; password=postgres_migrator_password; expression='GymIntel.Release.migrate()' ;;
  update|enqueue)
    test "$#" = 2
    case "$2" in data/*) ;; *) echo 'CSV must be under data/' >&2; exit 2 ;; esac
    case "$2" in *'/../'*|*'/..'|*'/./'*|*'/.'|*'//'*) exit 2 ;; esac
    test -f "$2"
    test "$(wc -c < "$2" | tr -d ' ')" -le 1000000
    role=gym_intel_app; secret=app-password; password=postgres_app_password
    expression="GymIntel.Release.$action()" ;;
  *) echo 'Expected migrate, update or enqueue' >&2; exit 2 ;;
esac
runtime_image=$(cat "$kube_image_file")
case "$runtime_image" in gym-intel-runtime:k8s-*) ;; *) exit 2 ;; esac
task_name="operator-$action-$(date +%s)-$$"
cleanup_task() {
  task_status=$?
  trap - EXIT HUP INT TERM
  kube delete job "$task_name" --ignore-not-found --wait=true --timeout=45s >/dev/null || task_status=1
  exit "$task_status"
}
trap cleanup_task EXIT
trap 'exit 1' HUP INT TERM
# Values interpolated below are fixed enums, a validated image and generated name.
kube apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $task_name
  labels: {app: operator-task}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 60
  activeDeadlineSeconds: 420
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext: {runAsUser: 10001, runAsGroup: 10001, fsGroup: 10001, runAsNonRoot: true}
      containers:
        - name: task
          image: $runtime_image
          imagePullPolicy: Never
          command: [sh, -c, 'sleep 400']
          envFrom:
            - configMapRef: {name: app-settings}
          env:
            - {name: DATABASE_USER, value: $role}
            - {name: DATABASE_PASSWORD_FILE, value: /run/secrets/$password}
            - {name: IMPORT_CSV_PATH, value: /tmp/input.csv}
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {cpu: '1', memory: 512Mi}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
          volumeMounts:
            - {name: secret, mountPath: /run/secrets, readOnly: true}
            - {name: tmp, mountPath: /tmp}
      volumes:
        - name: secret
          secret: {secretName: $secret, defaultMode: 288}
        - name: tmp
          emptyDir: {sizeLimit: 64Mi}
EOF
kube wait --for=create pod -l "job-name=$task_name" --timeout=60s
kube wait --for=condition=Ready pod -l "job-name=$task_name" --timeout=90s
task_pod=$(kube get pod -l "job-name=$task_name" -o 'jsonpath={.items[0].metadata.name}')
if [ "$action" != migrate ]; then
  kube exec -i "$task_pod" -- sh -c 'umask 077; cat > /tmp/input.csv' < "$2"
fi
kube exec "$task_pod" -- sh -ec 'ulimit -n 65536; exec bin/gym_intel eval "$1"' operator "$expression"

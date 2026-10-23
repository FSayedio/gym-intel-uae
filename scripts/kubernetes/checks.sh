#!/bin/sh
# Short-lived checks image, never included in the application runtime image.
set -eu
umask 077
project_dir=$(cd "$(dirname "$0")/../.." && pwd)
cd "$project_dir"
. scripts/kubernetes/common.sh
kube_guard
case "${1:-}" in
  tests) check_command='sh scripts/ci-checks.sh'; check_secret=postgres-passwords; check_key=postgres_password ;;
  dashboard) check_command='elixir -r scripts/recovery/dashboard_probe.exs -e "GymIntel.Recovery.DashboardProbe.run()"'; check_secret=grafana-passwords; check_key=grafana_admin_password ;;
  *) echo 'Expected tests or dashboard' >&2; exit 2 ;;
esac
docker build --provenance=false --target checks --tag gym-intel-checks:kubernetes .
image_id=$(docker image inspect gym-intel-checks:kubernetes --format '{{.Id}}')
check_image="gym-intel-checks:k8s-${image_id#sha256:}"
docker tag gym-intel-checks:kubernetes "$check_image"
archive=$(mktemp "$kube_root/check-image-XXXXXX")
check_job="checks-$1-$(date +%s)-$$"
cleanup_checks() {
  check_status=$?
  trap - EXIT HUP INT TERM
  rm -f "$archive"
  kube delete job "$check_job" --ignore-not-found --wait=true --timeout=60s >/dev/null || check_status=1
  exit "$check_status"
}
trap cleanup_checks EXIT
trap 'exit 1' HUP INT TERM
docker image save --platform linux/arm64 "$check_image" -o "$archive"
docker exec -i gym-intel-control-plane ctr --namespace=k8s.io images import \
  --platform linux/arm64 --digests --snapshotter=overlayfs - < "$archive"
kube apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $check_job
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 600
  ttlSecondsAfterFinished: 60
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      containers:
        - name: checks
          image: $check_image
          imagePullPolicy: Never
          command: [sh, -ec, 'ulimit -n 65536; $check_command']
          env:
            - {name: MIX_ENV, value: test}
            - {name: RUN_DB_TESTS, value: 'true'}
            - {name: DATABASE_NAME, value: gym_intel_test}
            - {name: DATABASE_HOST, value: postgres}
            - {name: DATABASE_USER, value: gym_intel}
            - {name: DATABASE_PASSWORD_FILE, value: /run/secrets/postgres_password}
            - {name: ERL_FLAGS, value: '+S 2:2'}
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {cpu: '2', memory: 768Mi}
          volumeMounts:
            - {name: secret, mountPath: /run/secrets, readOnly: true}
            - {name: expected, mountPath: /expected-dashboard.json, subPath: memberships.json, readOnly: true}
      volumes:
        - name: secret
          secret:
            secretName: $check_secret
            defaultMode: 256
            items: [{key: $check_key, path: $check_key}]
        - name: expected
          configMap: {name: grafana-panels}
EOF
kube wait --for=create pod -l "job-name=$check_job" --timeout=60s
check_pod=$(kube get pod -l "job-name=$check_job" -o 'jsonpath={.items[0].metadata.name}')
kube logs -f "$check_pod" --pod-running-timeout=90s
kube wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$check_pod" --timeout=30s || {
  echo 'FAIL: Kubernetes check process did not succeed' >&2; exit 1;
}
kube wait --for=condition=Complete "job/$check_job" --timeout=30s

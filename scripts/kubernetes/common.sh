#!/bin/sh
# Every operation names our private kubeconfig/context; never use ambient context.
kube_root="$project_dir/.local/kubernetes"
kube_namespace=${GYM_INTEL_KUBE_NAMESPACE:-gym-intel}
case "$kube_namespace" in
  gym-intel) ;;
  gym-intel-test-*) printf '%s\n' "$kube_namespace" | grep -Eq '^gym-intel-test-[0-9]+-[0-9]+$' || return 2 ;;
  *) echo 'Refusing unmanaged Kubernetes namespace' >&2; return 2 ;;
esac
kube_image_file="$kube_root/$kube_namespace.runtime-image"
kube() {
  kubectl --kubeconfig "$kube_root/kubeconfig" --context kind-gym-intel --namespace "$kube_namespace" "$@"
}
kube_guard() {
  test -s "$kube_root/kubeconfig" || { echo 'Run Kubernetes bootstrap first' >&2; return 1; }
  . "$project_dir/scripts/recovery/common.sh"
  recovery_private_directory "$kube_root"
  recovery_private_file "$kube_root/kubeconfig"
  kube_server=$(kube config view --minify -o 'jsonpath={.clusters[0].cluster.server}')
  printf '%s\n' "$kube_server" | grep -Eq '^https://127\.0\.0\.1:[0-9]+$' || {
    echo 'Refusing a non-loopback cluster endpoint' >&2; return 1;
  }
  test "$(kube get namespace "$kube_namespace" -o 'jsonpath={.metadata.labels.gym-intel-managed}')" = 'true' || {
    echo 'Refusing namespace without project ownership label' >&2; return 1;
  }
}
kube_psql() { kube exec -i postgres-0 -- sh /opt/gym-intel/psql.sh "$@"; }
kube_resume() {
  kube scale deployment/app --replicas=1 >/dev/null &&
    kube rollout status deployment/app --timeout=120s >/dev/null
}
kube_pause() {
  kube scale deployment/app --replicas=0 >/dev/null
  kube wait --for=delete pod -l app=app --timeout=60s >/dev/null
}

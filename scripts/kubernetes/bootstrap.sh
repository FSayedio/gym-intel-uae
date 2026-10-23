#!/bin/sh
set -eu
umask 077
project_dir=$(cd "$(dirname "$0")/../.." && pwd)
cd "$project_dir"
. scripts/kubernetes/common.sh
mkdir -p "$kube_root/bin"
chmod 700 "$project_dir/.local" "$kube_root" "$kube_root/bin"
case "$(uname -s):$(uname -m)" in
  Darwin:arm64) platform=darwin-arm64; checksum=0c8c7dbe5e23594a198b786c4bc13dacc101fa6196b0cb0b23a1ca44e61f4b4f ;;
  Linux:aarch64|Linux:arm64) platform=linux-arm64; checksum=20022bee6cfcd5086cb7234d218e3454e6090022f2a8f55d1fa7fcf42c3867a2 ;;
  *) echo 'This local deployment requires ARM64' >&2; exit 1 ;;
esac
if [ ! -f "$kube_root/bin/kind" ]; then
  curl --fail --location --silent --show-error "https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-$platform" -o "$kube_root/bin/kind.download"
  test "$(shasum -a 256 "$kube_root/bin/kind.download" | cut -d ' ' -f 1)" = "$checksum"
  chmod 700 "$kube_root/bin/kind.download"
  mv "$kube_root/bin/kind.download" "$kube_root/bin/kind"
fi
test "$(shasum -a 256 "$kube_root/bin/kind" | cut -d ' ' -f 1)" = "$checksum"
if "$kube_root/bin/kind" get clusters | grep -qx gym-intel; then
  test -s "$kube_root/kubeconfig" || { echo 'Existing cluster without private kubeconfig; inspect before adopting it' >&2; exit 1; }
else
  "$kube_root/bin/kind" create cluster --name gym-intel --config kubernetes/kind.yaml \
    --kubeconfig "$kube_root/kubeconfig" \
    --image kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed --wait 180s
fi
chmod 600 "$kube_root/kubeconfig"
kube get nodes
if ! kube get namespace "$kube_namespace" >/dev/null 2>&1; then
  kube create namespace "$kube_namespace"
  kube label namespace "$kube_namespace" gym-intel-managed=true
fi
kube_guard
echo 'PASS: local ARM64 cluster ready; global kubeconfig unchanged'

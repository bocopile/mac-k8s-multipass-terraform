#!/bin/bash
set -euo pipefail

# Usage: install-metallb.sh <metallb-version>
METALLB_VERSION="${1:?Usage: install-metallb.sh <metallb-version>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"
CLUSTERS_JSON="${GENERATED_DIR}/clusters.json"

if [[ ! -f "${CLUSTERS_JSON}" ]]; then
  echo "ERROR: clusters.json not found at ${CLUSTERS_JSON}"
  exit 1
fi

# clusters.json에서 클러스터 목록 읽기
CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  CONTEXT="kubernetes-admin@${CLUSTER}"
  POOL=$(jq -r ".\"${CLUSTER}\".metallb_pool" "${CLUSTERS_JSON}")

  echo "=== Installing MetalLB on ${CLUSTER} (pool: ${POOL}) ==="

  # MetalLB 네임스페이스 및 manifest 적용
  kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
    apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"

  # MetalLB controller가 준비될 때까지 대기
  echo "Waiting for MetalLB controller on ${CLUSTER}..."
  kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
    -n metallb-system wait deploy/controller \
    --for=condition=available --timeout=120s

  # MetalLB speaker가 준비될 때까지 대기
  kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
    -n metallb-system wait pod -l app.kubernetes.io/component=speaker \
    --for=condition=ready --timeout=120s || true

  # IPAddressPool 및 L2Advertisement 적용
  kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  namespace: metallb-system
  name: ${CLUSTER}-pool
spec:
  addresses:
    - ${POOL}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  namespace: metallb-system
  name: ${CLUSTER}-l2adv
spec:
  ipAddressPools:
    - ${CLUSTER}-pool
EOF

  echo "=== MetalLB installed on ${CLUSTER} ==="
done

echo "=== MetalLB installation complete on all clusters ==="

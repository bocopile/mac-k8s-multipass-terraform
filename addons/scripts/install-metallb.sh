#!/bin/bash
set -euo pipefail

# Usage: install-metallb.sh <metallb-version>
METALLB_VERSION="${1:?Usage: install-metallb.sh <metallb-version>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../scripts/lib/common.sh"

# Setup
setup_common_vars

# clusters.json에서 클러스터 목록 읽기
CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  CONTEXT="kubernetes-admin@${CLUSTER}"
  POOL=$(jq -r ".\"${CLUSTER}\".metallb_pool" "${CLUSTERS_JSON}")

  log_info "Installing MetalLB on ${CLUSTER} (pool: ${POOL})"

  # MetalLB 네임스페이스 및 manifest 적용
  $(get_kubectl_cmd "${CLUSTER}") \
    apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"

  # MetalLB controller가 준비될 때까지 대기
  wait_for_deployment "metallb-system" "controller" "${TIMEOUT_POD_READY}" "${CONTEXT}"

  # MetalLB speaker가 준비될 때까지 대기
  $(get_kubectl_cmd "${CLUSTER}") \
    -n metallb-system wait pod -l app.kubernetes.io/component=speaker \
    --for=condition=ready --timeout="${TIMEOUT_POD_READY}s" || true

  # IPAddressPool 및 L2Advertisement 적용
  $(get_kubectl_cmd "${CLUSTER}") apply -f - <<EOF
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

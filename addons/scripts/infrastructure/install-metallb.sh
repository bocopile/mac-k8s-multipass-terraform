#!/bin/bash
set -euo pipefail

# Usage: install-metallb.sh [metallb-version]
# Version priority: $1 argument > $METALLB_VERSION env var > default
METALLB_VERSION="${1:-${METALLB_VERSION:-0.15.3}}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../../scripts/lib/constants.sh"

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
    apply -f "https://raw.githubusercontent.com/metallb/metallb/v${METALLB_VERSION}/config/manifests/metallb-native.yaml"

  # MetalLB controller가 준비될 때까지 대기
  wait_for_deployment "metallb-system" "controller" "${TIMEOUT_POD_READY}" "${CONTEXT}"

  # MetalLB speaker가 준비될 때까지 대기
  $(get_kubectl_cmd "${CLUSTER}") \
    -n metallb-system wait pod -l component=speaker \
    --for=condition=ready --timeout="${TIMEOUT_POD_READY}s" || true

  # webhook이 준비될 때까지 대기
  log_info "Waiting for MetalLB webhook to be ready..."
  sleep 10

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

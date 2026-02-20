#!/bin/bash
set -euo pipefail

# Usage: install-gateway-api.sh
# 전 클러스터에 Gateway API CRD 설치 + Cilium Gateway API 활성화

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"
CLUSTERS_JSON="${GENERATED_DIR}/clusters.json"

if [[ ! -f "${CLUSTERS_JSON}" ]]; then
  echo "ERROR: clusters.json not found at ${CLUSTERS_JSON}"
  exit 1
fi

# Gateway API CRD 버전 (experimental 채널: TCPRoute, TLSRoute 포함)
GATEWAY_API_VERSION="v1.2.1"

CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  CONTEXT="kubernetes-admin@${CLUSTER}"

  echo "=== Installing Gateway API CRDs on ${CLUSTER} ==="

  # Gateway API CRD 설치 (experimental channel)
  kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
    apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"

  echo "=== Enabling Cilium Gateway API on ${CLUSTER} ==="

  # Cilium에 Gateway API 활성화 (helm upgrade)
  cilium upgrade \
    --set gatewayAPI.enabled=true \
    --context "${CONTEXT}" \
    --kubeconfig "${KUBECONFIG_MULTI}" \
    --wait

  echo "=== Gateway API enabled on ${CLUSTER} ==="
done

echo "=== Gateway API installation complete on all clusters ==="

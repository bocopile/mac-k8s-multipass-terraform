#!/bin/bash
set -euo pipefail

# Usage: install-tetragon.sh [tetragon-version]
TETRAGON_VERSION="${1:-1.3.0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"
CLUSTERS_JSON="${GENERATED_DIR}/clusters.json"

if [[ ! -f "${CLUSTERS_JSON}" ]]; then
  echo "ERROR: clusters.json not found at ${CLUSTERS_JSON}"
  exit 1
fi

# Helm repo 추가
helm repo add cilium https://helm.cilium.io 2>/dev/null || true
helm repo update cilium

CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  CONTEXT="kubernetes-admin@${CLUSTER}"

  echo "=== Installing Tetragon ${TETRAGON_VERSION} on ${CLUSTER} ==="

  helm upgrade --install tetragon cilium/tetragon \
    --version "${TETRAGON_VERSION}" \
    --namespace kube-system \
    --kubeconfig "${KUBECONFIG_MULTI}" \
    --kube-context "${CONTEXT}" \
    --set tetragon.enableProcessCred=true \
    --set tetragon.enableProcessNs=true \
    --wait --timeout 120s

  # DaemonSet 준비 대기
  kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
    -n kube-system rollout status daemonset/tetragon --timeout=120s

  echo "=== Tetragon installed on ${CLUSTER} ==="
done

echo "=== Tetragon installation complete on all clusters ==="

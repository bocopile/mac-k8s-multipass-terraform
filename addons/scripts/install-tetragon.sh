#!/bin/bash
set -euo pipefail

# Usage: install-tetragon.sh [tetragon-version]
TETRAGON_VERSION="${1:-1.3.0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../scripts/lib/constants.sh"

# Setup
setup_common_vars

# Helm repo 추가
add_helm_repo "cilium" "${HELM_REPO_CILIUM}"

CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  echo "=== Installing Tetragon ${TETRAGON_VERSION} on ${CLUSTER} ==="

  $(get_helm_cmd "${CLUSTER}") upgrade --install tetragon cilium/tetragon \
    --version "${TETRAGON_VERSION}" \
    --namespace kube-system \
    --set tetragon.enableProcessCred=true \
    --set tetragon.enableProcessNs=true \
    --wait --timeout "${TIMEOUT_POD_READY}s"

  # DaemonSet 준비 대기
  $(get_kubectl_cmd "${CLUSTER}") \
    -n kube-system rollout status daemonset/tetragon --timeout="${TIMEOUT_POD_READY}s"

  echo "=== Tetragon installed on ${CLUSTER} ==="
done

echo "=== Tetragon installation complete on all clusters ==="

#!/bin/bash
set -euo pipefail

# Usage: install-local-path-provisioner.sh [version]
# 전 클러스터에 Rancher local-path-provisioner 설치
# PVC 기반 addon (Vault, MinIO, Loki, Tempo 등) 설치 전에 필요

LOCAL_PATH_VERSION="${1:-0.0.30}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../../scripts/lib/constants.sh"

# Setup
setup_common_vars

CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  log_info "Installing local-path-provisioner ${LOCAL_PATH_VERSION} on ${CLUSTER}"

  CONTEXT="kubernetes-admin@${CLUSTER}"

  # local-path-storage namespace에 privileged PSA 필요 (hostPath 사용)
  ensure_namespace_privileged "local-path-storage" "${CLUSTER}"

  # local-path-provisioner 설치
  kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
    apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/v${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"

  # 배포 대기
  kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
    -n local-path-storage wait deployment/local-path-provisioner \
    --for=condition=available --timeout="${TIMEOUT_POD_READY}s" \
    || log_warn "local-path-provisioner not ready within ${TIMEOUT_POD_READY}s on ${CLUSTER}"

  # local-path-retain StorageClass 생성 (Retain 정책 — Vault, Loki, Tempo 등 StatefulSet용)
  log_info "Creating local-path-retain StorageClass on ${CLUSTER}"
  kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" apply -f - <<'SCEOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path-retain
provisioner: rancher.io/local-path
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
SCEOF

  log_info "local-path-provisioner installed on ${CLUSTER}"
done

echo ""
echo "=== local-path-provisioner ${LOCAL_PATH_VERSION} installed on all clusters ==="
echo "StorageClass: local-path (default), local-path-retain (Retain)"

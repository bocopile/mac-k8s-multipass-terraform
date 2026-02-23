#!/bin/bash
set -euo pipefail

# Usage: install-minio.sh
# mgmt 클러스터에 MinIO 설치 (Velero 백업 저장소)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../scripts/lib/constants.sh"
source "${SCRIPT_DIR}/../../scripts/lib/credentials.sh"

# Setup
setup_common_vars

# Initialize and get MinIO credentials
init_credentials
load_credentials || true
get_minio_credentials > /dev/null
source "${CREDENTIALS_FILE}"

# Helm repo 추가
add_helm_repo "bitnami" "${HELM_REPO_BITNAMI}"

log_info "Installing MinIO on mgmt cluster (Demo Environment)"

# Demo Environment Configuration:
# - Storage: 15Gi (down from 50Gi, 70% reduction)
# - Memory: 128Mi-256Mi (down from 256Mi-512Mi, 50% reduction)
# - CPU: 50m-250m (down from 100m-500m, 50% reduction)
# - Optimized for Mac M1 Max (10-core, 64GB RAM)

# Ensure namespace exists
ensure_namespace "${NAMESPACE_BACKUP}" "mgmt"

# Install MinIO
$(get_helm_cmd mgmt) upgrade --install minio bitnami/minio \
  --namespace "${NAMESPACE_BACKUP}" \
  --set auth.rootUser="${MINIO_ROOT_USER}" \
  --set auth.rootPassword="${MINIO_ROOT_PASSWORD}" \
  --set mode=standalone \
  --set persistence.enabled=true \
  --set persistence.storageClass="${STORAGE_CLASS_DEFAULT}" \
  --set persistence.size=15Gi \
  --set service.type=LoadBalancer \
  --set service.ports.api=9000 \
  --set service.ports.console=9001 \
  --set defaultBuckets="velero-backups,thanos,loki-logs,tempo-traces" \
  --set resources.requests.memory="${RESOURCES_MEDIUM_REQUESTS_MEMORY}" \
  --set resources.requests.cpu="${RESOURCES_SMALL_REQUESTS_CPU}" \
  --set resources.limits.memory="${RESOURCES_MEDIUM_LIMITS_MEMORY}" \
  --set resources.limits.cpu="${RESOURCES_SMALL_LIMITS_CPU}" \
  --set priorityClassName=platform-normal \
  --wait --timeout "${TIMEOUT_DEPLOYMENT}s"

# Wait for deployment
wait_for_deployment "${NAMESPACE_BACKUP}" "minio" "${TIMEOUT_POD_READY}" "kubernetes-admin@mgmt"

# Get LoadBalancer IP
MINIO_IP=$(wait_for_lb_ip "${NAMESPACE_BACKUP}" "minio" 20 "kubernetes-admin@mgmt")

if [[ -n "${MINIO_IP}" ]]; then
  echo "${MINIO_IP}" > "${GENERATED_DIR}/minio-ip"
  echo ""
  echo "========================================="
  echo "  MinIO Installation Summary (Demo)"
  echo "========================================="
  echo "  API:         http://${MINIO_IP}:9000"
  echo "  Console:     http://${MINIO_IP}:9001"
  echo "  Credentials: Stored in ${CREDENTIALS_FILE}"
  echo "               User: ${MINIO_ROOT_USER}"
  echo ""
  echo "  Storage:     15Gi (demo-optimized)"
  echo "  Resources:   128Mi-256Mi RAM, 50m-250m CPU"
  echo ""
  echo "  Buckets (auto-created):"
  echo "    - velero-backups  (cluster backups)"
  echo "    - thanos          (long-term metrics)"
  echo "    - loki-logs       (future log storage)"
  echo "    - tempo-traces    (future trace storage)"
  echo "========================================="
  echo ""
  echo "Access via domain (add to /etc/hosts):"
  echo "  ${MINIO_IP}  minio.local"
  echo ""
  echo "Or run: sudo bash scripts/update-hosts-mac.sh"
else
  echo "WARN: MinIO LoadBalancer IP가 할당되지 않았습니다."
  echo "      MetalLB가 정상 동작하는지 확인하세요."
fi

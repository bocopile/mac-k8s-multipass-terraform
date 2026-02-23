#!/bin/bash
set -euo pipefail

# Usage: install-velero.sh [velero-version]
# 전 클러스터에 Velero 설치 (백업 → mgmt MinIO)

VELERO_VERSION="${1:-8.2.0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../scripts/lib/constants.sh"
source "${SCRIPT_DIR}/../../scripts/lib/credentials.sh"

# Setup
setup_common_vars

# MinIO IP 확인
MINIO_IP_FILE="${GENERATED_DIR}/minio-ip"
MINIO_IP=""

if [[ -f "${MINIO_IP_FILE}" ]]; then
  MINIO_IP=$(cat "${MINIO_IP_FILE}")
else
  # Fallback: mgmt 클러스터에서 직접 조회
  MGMT_CONTEXT="kubernetes-admin@mgmt"
  MINIO_IP=$(kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${MGMT_CONTEXT}" \
    -n minio get svc minio \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
fi

if [[ -z "${MINIO_IP}" ]]; then
  echo "ERROR: MinIO IP를 확인할 수 없습니다."
  echo "       먼저 install-minio.sh를 실행하세요."
  exit 1
fi

S3_URL="http://${MINIO_IP}:9000"
echo "MinIO S3 endpoint: ${S3_URL}"

# Load MinIO credentials
load_credentials || {
  echo "ERROR: Credentials file not found. Run install-minio.sh first."
  exit 1
}

# Helm repo 추가
add_helm_repo "vmware-tanzu" "${HELM_REPO_VMWARE_TANZU}"

CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  log_info "Installing Velero on ${CLUSTER}"

  # MinIO 자격증명 Secret 생성
  ensure_namespace "${NAMESPACE_BACKUP}" "${CLUSTER}"
  $(get_kubectl_cmd "${CLUSTER}") -n "${NAMESPACE_BACKUP}" create secret generic velero-s3-credentials \
    --from-literal=aws="[default]
aws_access_key_id=${MINIO_ROOT_USER}
aws_secret_access_key=${MINIO_ROOT_PASSWORD}
" --dry-run=client -o yaml | $(get_kubectl_cmd "${CLUSTER}") apply -f -

  $(get_helm_cmd "${CLUSTER}") upgrade --install velero vmware-tanzu/velero \
    --version "${VELERO_VERSION}" \
    --namespace "${NAMESPACE_BACKUP}" \
    --set configuration.backupStorageLocation[0].name=default \
    --set configuration.backupStorageLocation[0].provider=aws \
    --set configuration.backupStorageLocation[0].bucket=velero-backups \
    --set configuration.backupStorageLocation[0].prefix="${CLUSTER}" \
    --set configuration.backupStorageLocation[0].config.region=minio \
    --set configuration.backupStorageLocation[0].config.s3ForcePathStyle=true \
    --set configuration.backupStorageLocation[0].config.s3Url="${S3_URL}" \
    --set configuration.backupStorageLocation[0].credential.name=velero-s3-credentials \
    --set configuration.backupStorageLocation[0].credential.key=aws \
    --set configuration.volumeSnapshotLocation[0].name=default \
    --set configuration.volumeSnapshotLocation[0].provider=aws \
    --set configuration.volumeSnapshotLocation[0].config.region=minio \
    --set snapshotsEnabled=false \
    --set deployNodeAgent=true \
    --set nodeAgent.resources.requests.memory=128Mi \
    --set nodeAgent.resources.requests.cpu=50m \
    --set nodeAgent.resources.limits.memory=512Mi \
    --set credentials.existingSecret=velero-s3-credentials \
    --set initContainers[0].name=velero-plugin-for-aws \
    --set initContainers[0].image=velero/velero-plugin-for-aws:v1.11.0 \
    --set initContainers[0].volumeMounts[0].mountPath=/target \
    --set initContainers[0].volumeMounts[0].name=plugins \
    --set metrics.enabled=true \
    --set metrics.serviceMonitor.enabled=true \
    --set priorityClassName=platform-normal \
    --wait --timeout 180s

  log_info "Velero installed on ${CLUSTER} (backup prefix: ${CLUSTER}/)"
done

echo ""
echo "=== Velero installation complete on all clusters ==="
echo ""
echo "백업 명령어 예시:"
echo "  velero backup create daily-backup --kubeconfig ~/kubeconfig-multi --kubecontext kubernetes-admin@mgmt"
echo ""
echo "스케줄 백업 생성:"
echo "  velero schedule create daily --schedule='0 2 * * *' --kubeconfig ~/kubeconfig-multi --kubecontext kubernetes-admin@mgmt"

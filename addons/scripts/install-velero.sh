#!/bin/bash
set -euo pipefail

# Usage: install-velero.sh [velero-version]
# 전 클러스터에 Velero 설치 (백업 → mgmt MinIO)

VELERO_VERSION="${1:-8.2.0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"
CLUSTERS_JSON="${GENERATED_DIR}/clusters.json"

if [[ ! -f "${CLUSTERS_JSON}" ]]; then
  echo "ERROR: clusters.json not found at ${CLUSTERS_JSON}"
  exit 1
fi

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

# Helm repo 추가
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts 2>/dev/null || true
helm repo update vmware-tanzu

CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  CONTEXT="kubernetes-admin@${CLUSTER}"
  KC="--kubeconfig ${KUBECONFIG_MULTI} --kube-context ${CONTEXT}"
  KC_KUBECTL="--kubeconfig ${KUBECONFIG_MULTI} --context ${CONTEXT}"

  echo "=== Installing Velero on ${CLUSTER} ==="

  # MinIO 자격증명 Secret 생성
  kubectl ${KC_KUBECTL} create namespace backup 2>/dev/null || true
  kubectl ${KC_KUBECTL} -n backup create secret generic velero-s3-credentials \
    --from-literal=aws='[default]
aws_access_key_id=minioadmin
aws_secret_access_key=minioadmin123
' --dry-run=client -o yaml | kubectl ${KC_KUBECTL} apply -f -

  helm upgrade --install velero vmware-tanzu/velero \
    --version "${VELERO_VERSION}" \
    --namespace backup \
    ${KC} \
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
    --wait --timeout 180s

  echo "=== Velero installed on ${CLUSTER} (backup prefix: ${CLUSTER}/) ==="
done

echo ""
echo "=== Velero installation complete on all clusters ==="
echo ""
echo "백업 명령어 예시:"
echo "  velero backup create daily-backup --kubeconfig ~/kubeconfig-multi --kubecontext kubernetes-admin@mgmt"
echo ""
echo "스케줄 백업 생성:"
echo "  velero schedule create daily --schedule='0 2 * * *' --kubeconfig ~/kubeconfig-multi --kubecontext kubernetes-admin@mgmt"

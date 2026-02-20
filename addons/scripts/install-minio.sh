#!/bin/bash
set -euo pipefail

# Usage: install-minio.sh
# mgmt 클러스터에 MinIO 설치 (Velero 백업 저장소)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"
CLUSTERS_JSON="${GENERATED_DIR}/clusters.json"

# Load credential management library
source "${SCRIPT_DIR}/../../scripts/lib/credentials.sh"

if [[ ! -f "${CLUSTERS_JSON}" ]]; then
  echo "ERROR: clusters.json not found at ${CLUSTERS_JSON}"
  exit 1
fi

MGMT_CONTEXT="kubernetes-admin@mgmt"
KC="--kubeconfig ${KUBECONFIG_MULTI} --kube-context ${MGMT_CONTEXT}"
KC_KUBECTL="--kubeconfig ${KUBECONFIG_MULTI} --context ${MGMT_CONTEXT}"

# Initialize and get MinIO credentials
init_credentials
load_credentials || true
get_minio_credentials > /dev/null
source "${CREDENTIALS_FILE}"

# Helm repo 추가
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo update bitnami

echo "=== Installing MinIO on mgmt cluster (Demo Environment) ==="

# Demo Environment Configuration:
# - Storage: 15Gi (down from 50Gi, 70% reduction)
# - Memory: 128Mi-256Mi (down from 256Mi-512Mi, 50% reduction)
# - CPU: 50m-250m (down from 100m-500m, 50% reduction)
# - Optimized for Mac M1 Max (10-core, 64GB RAM)

helm upgrade --install minio bitnami/minio \
  --namespace backup --create-namespace \
  ${KC} \
  --set auth.rootUser="${MINIO_ROOT_USER}" \
  --set auth.rootPassword="${MINIO_ROOT_PASSWORD}" \
  --set mode=standalone \
  --set persistence.enabled=true \
  --set persistence.storageClass=local-path \
  --set persistence.size=15Gi \
  --set service.type=LoadBalancer \
  --set service.ports.api=9000 \
  --set service.ports.console=9001 \
  --set defaultBuckets="velero-backups,thanos,loki-logs,tempo-traces" \
  --set resources.requests.memory=128Mi \
  --set resources.requests.cpu=50m \
  --set resources.limits.memory=256Mi \
  --set resources.limits.cpu=250m \
  --wait --timeout 180s

echo "Waiting for MinIO..."
kubectl ${KC_KUBECTL} -n backup wait deploy/minio \
  --for=condition=available --timeout=120s

# MinIO LoadBalancer IP 확인
MINIO_IP=""
for i in $(seq 1 20); do
  MINIO_IP=$(kubectl ${KC_KUBECTL} -n backup \
    get svc minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "${MINIO_IP}" ]]; then
    break
  fi
  echo "Waiting for MinIO LoadBalancer IP... (${i}/20)"
  sleep 5
done

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

#!/bin/bash
set -euo pipefail

# Usage: install-thanos.sh
# mgmt 클러스터에 Thanos Receive + Query 설치 (Prometheus Agent remote_write 수신)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../scripts/lib/constants.sh"
source "${SCRIPT_DIR}/../../scripts/lib/credentials.sh"

# Setup
setup_common_vars

# Load MinIO credentials
load_credentials || error_exit "Credentials file not found. Run install-minio.sh first."

# Helm repo 추가
add_helm_repo "bitnami" "${HELM_REPO_BITNAMI}"

log_info "Creating Thanos Object Storage Config (MinIO)"

# MinIO를 object storage로 사용 (장기 보존)
ensure_namespace "${NAMESPACE_OBSERVABILITY}" "mgmt"

$(get_kubectl_cmd mgmt) create secret generic thanos-objstore-config -n "${NAMESPACE_OBSERVABILITY}" \
  --from-literal=objstore.yml="$(cat <<EOF
type: S3
config:
  bucket: thanos
  endpoint: minio.${NAMESPACE_BACKUP}.svc.cluster.local:9000
  access_key: ${MINIO_ROOT_USER}
  secret_key: ${MINIO_ROOT_PASSWORD}
  # WARNING: insecure=true required while MinIO runs without TLS.
  # Set to false after enabling TLS on MinIO.
  insecure: true
  signature_version2: false
  http_config:
    idle_conn_timeout: 90s
    response_header_timeout: 2m
    insecure_skip_verify: false
EOF
)" --dry-run=client -o yaml | $(get_kubectl_cmd mgmt) apply -f -

log_info "Installing Thanos on mgmt cluster"

$(get_helm_cmd mgmt) upgrade --install thanos bitnami/thanos \
  --namespace "${NAMESPACE_OBSERVABILITY}" \
  --set receive.enabled=true \
  --set receive.replicaCount=1 \
  --set receive.persistence.enabled=true \
  --set receive.persistence.storageClass=local-path \
  --set receive.persistence.size=20Gi \
  --set receive.service.type=LoadBalancer \
  --set receive.tsdbRetention=15d \
  --set receive.objstoreConfig=thanos-objstore-config \
  --set receive.resources.requests.cpu=100m \
  --set receive.resources.requests.memory=256Mi \
  --set receive.resources.limits.cpu=500m \
  --set receive.resources.limits.memory=512Mi \
  --set receive.priorityClassName=platform-normal \
  --set query.enabled=true \
  --set query.replicaCount=1 \
  --set query.service.type=ClusterIP \
  --set query.resources.requests.cpu=50m \
  --set query.resources.requests.memory=128Mi \
  --set query.resources.limits.cpu=200m \
  --set query.resources.limits.memory=256Mi \
  --set query.priorityClassName=platform-normal \
  --set queryFrontend.enabled=true \
  --set queryFrontend.replicaCount=1 \
  --set queryFrontend.resources.requests.cpu=50m \
  --set queryFrontend.resources.requests.memory=64Mi \
  --set queryFrontend.resources.limits.cpu=100m \
  --set queryFrontend.resources.limits.memory=128Mi \
  --set queryFrontend.priorityClassName=platform-normal \
  --set storegateway.enabled=true \
  --set storegateway.replicaCount=1 \
  --set storegateway.persistence.enabled=true \
  --set storegateway.persistence.storageClass=local-path \
  --set storegateway.persistence.size=5Gi \
  --set storegateway.resources.requests.cpu=100m \
  --set storegateway.resources.requests.memory=256Mi \
  --set storegateway.resources.limits.cpu=500m \
  --set storegateway.resources.limits.memory=512Mi \
  --set storegateway.priorityClassName=platform-normal \
  --set compactor.enabled=true \
  --set compactor.persistence.enabled=true \
  --set compactor.persistence.storageClass=local-path \
  --set compactor.persistence.size=10Gi \
  --set compactor.objstoreConfig=thanos-objstore-config \
  --set compactor.resources.requests.cpu=100m \
  --set compactor.resources.requests.memory=256Mi \
  --set compactor.resources.limits.cpu=500m \
  --set compactor.resources.limits.memory=512Mi \
  --set compactor.priorityClassName=platform-normal \
  --set ruler.enabled=false \
  --set metrics.enabled=true \
  --set metrics.serviceMonitor.enabled=true \
  --set objstoreConfig=thanos-objstore-config \
  --wait --timeout 300s

log_info "Waiting for Thanos Receive..."
$(get_kubectl_cmd mgmt) -n "${NAMESPACE_OBSERVABILITY}" wait deploy/thanos-receive \
  --for=condition=available --timeout=180s || true

# Thanos Receive의 LoadBalancer IP 확인
THANOS_RECEIVE_IP=""
for i in $(seq 1 30); do
  THANOS_RECEIVE_IP=$($(get_kubectl_cmd mgmt) -n "${NAMESPACE_OBSERVABILITY}" \
    get svc thanos-receive -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "${THANOS_RECEIVE_IP}" ]]; then
    break
  fi
  echo "Waiting for Thanos Receive LoadBalancer IP... (${i}/30)"
  sleep 5
done

if [[ -n "${THANOS_RECEIVE_IP}" ]]; then
  echo ""
  echo "=== Thanos installed on mgmt ==="
  echo "Thanos Receive endpoint: http://${THANOS_RECEIVE_IP}:19291/api/v1/receive"
  echo "Thanos Query (internal):  http://thanos-query.observability.svc:9090"
  echo "Object Storage (MinIO):   minio.backup.svc.cluster.local:9000/thanos"
  echo ""
  echo "Grafana 데이터소스 추가:"
  echo "  Type: Prometheus"
  echo "  URL:  http://thanos-query.observability.svc.cluster.local:9090"
  echo ""
  echo "Components:"
  echo "  ✓ Receive (remote_write ingestion + local TSDB 15d)"
  echo "  ✓ StoreGateway (object storage query)"
  echo "  ✓ Query (unified querying)"
  echo "  ✓ QueryFrontend (query caching)"
  echo "  ✓ Compactor (downsampling + retention)"

  # Receive IP를 generated 디렉토리에 저장 (prometheus-agent 스크립트에서 참조)
  echo "${THANOS_RECEIVE_IP}" > "${GENERATED_DIR}/thanos-receive-ip"
else
  echo "WARN: Thanos Receive LoadBalancer IP가 할당되지 않았습니다."
  echo "      MetalLB가 정상 동작하는지 확인하세요."
fi

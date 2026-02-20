#!/bin/bash
set -euo pipefail

# Usage: install-thanos.sh
# mgmt 클러스터에 Thanos Receive + Query 설치 (Prometheus Agent remote_write 수신)

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

# Load MinIO credentials
load_credentials || {
  echo "ERROR: Credentials file not found. Run install-minio.sh first."
  exit 1
}

# Helm repo 추가
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo update bitnami

echo "=== Creating Thanos Object Storage Config (MinIO) ==="

# MinIO를 object storage로 사용 (장기 보존)
kubectl ${KC_KUBECTL} create secret generic thanos-objstore-config -n observability \
  --from-literal=objstore.yml="$(cat <<EOF
type: S3
config:
  bucket: thanos
  endpoint: minio.backup.svc.cluster.local:9000
  access_key: ${MINIO_ROOT_USER}
  secret_key: ${MINIO_ROOT_PASSWORD}
  insecure: true
  signature_version2: false
  http_config:
    idle_conn_timeout: 90s
    response_header_timeout: 2m
    insecure_skip_verify: true
EOF
)" --dry-run=client -o yaml | kubectl ${KC_KUBECTL} apply -f -

echo "=== Installing Thanos on mgmt cluster ==="

helm upgrade --install thanos bitnami/thanos \
  --namespace observability --create-namespace \
  ${KC} \
  --set receive.enabled=true \
  --set receive.replicaCount=1 \
  --set receive.persistence.enabled=true \
  --set receive.persistence.storageClass=local-path \
  --set receive.persistence.size=20Gi \
  --set receive.service.type=LoadBalancer \
  --set receive.tsdbRetention=15d \
  --set receive.objstoreConfig=thanos-objstore-config \
  --set query.enabled=true \
  --set query.replicaCount=1 \
  --set query.service.type=ClusterIP \
  --set queryFrontend.enabled=true \
  --set queryFrontend.replicaCount=1 \
  --set storegateway.enabled=true \
  --set storegateway.replicaCount=1 \
  --set storegateway.persistence.enabled=true \
  --set storegateway.persistence.storageClass=local-path \
  --set storegateway.persistence.size=5Gi \
  --set compactor.enabled=true \
  --set compactor.persistence.enabled=true \
  --set compactor.persistence.storageClass=local-path \
  --set compactor.persistence.size=10Gi \
  --set compactor.objstoreConfig=thanos-objstore-config \
  --set ruler.enabled=false \
  --set metrics.enabled=true \
  --set metrics.serviceMonitor.enabled=true \
  --set objstoreConfig=thanos-objstore-config \
  --wait --timeout 300s

echo "Waiting for Thanos Receive..."
kubectl ${KC_KUBECTL} -n observability wait deploy/thanos-receive \
  --for=condition=available --timeout=180s || true

# Thanos Receive의 LoadBalancer IP 확인
THANOS_RECEIVE_IP=""
for i in $(seq 1 30); do
  THANOS_RECEIVE_IP=$(kubectl ${KC_KUBECTL} -n observability \
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

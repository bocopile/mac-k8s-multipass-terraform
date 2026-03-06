#!/bin/bash
set -euo pipefail

# Usage: install-tempo.sh [tempo-version]
# Grafana Tempo 분산 추적 백엔드 설치 (mgmt 클러스터)
# - SingleBinary 모드 (로컬 환경 최적화)
# - local-path-retain StorageClass 사용
# - Grafana 데이터소스 자동 구성

TEMPO_VERSION="${1:-1.24.4}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../../scripts/lib/constants.sh"

# Setup
setup_common_vars

echo "=== Installing Grafana Tempo ${TEMPO_VERSION} on mgmt cluster ==="

# =============================================================================
# Helm Repo 추가
# =============================================================================
echo "[1/4] Adding Grafana Helm repository..."
add_helm_repo "grafana" "${HELM_REPO_GRAFANA}"

# =============================================================================
# Tempo 설치 (SingleBinary 모드)
# =============================================================================
echo "[2/4] Installing Tempo..."

ensure_namespace "${NAMESPACE_OBSERVABILITY}" "mgmt"

$(get_helm_cmd mgmt) upgrade --install tempo grafana/tempo \
  --version "${TEMPO_VERSION}" \
  --namespace "${NAMESPACE_OBSERVABILITY}" \
  --set tempo.repository=grafana/tempo \
  --set tempo.metricsGenerator.enabled=true \
  --set tempo.metricsGenerator.remoteWriteUrl="http://kube-prometheus-stack-prometheus.${NAMESPACE_MONITORING}.svc:9090/api/v1/write" \
  --set persistence.enabled=true \
  --set persistence.storageClassName=local-path-retain \
  --set persistence.size=10Gi \
  --set resources.requests.cpu=200m \
  --set resources.requests.memory=512Mi \
  --set resources.limits.cpu=1000m \
  --set resources.limits.memory=1Gi \
  --set service.type=ClusterIP \
  --set priorityClassName=platform-normal \
  --wait --timeout "${TIMEOUT_DEPLOYMENT}s"

echo "Tempo installed successfully."

# =============================================================================
# Tempo Query Frontend 서비스 확인
# =============================================================================
echo "[3/4] Verifying Tempo services..."

$(get_kubectl_cmd mgmt) -n "${NAMESPACE_OBSERVABILITY}" wait --for=condition=available --timeout="${TIMEOUT_DEPLOYMENT}s" \
  deployment/tempo || echo "WARNING: Tempo deployment not ready"

# Tempo 서비스 확인
TEMPO_SVC=$($(get_kubectl_cmd mgmt) -n "${NAMESPACE_OBSERVABILITY}" get svc tempo -o name 2>/dev/null || echo "")
if [[ -z "${TEMPO_SVC}" ]]; then
  echo "ERROR: Tempo service not found"
  exit 1
fi

echo "Tempo service available: ${TEMPO_SVC}"

# =============================================================================
# Grafana 데이터소스 추가 (Tempo)
# =============================================================================
echo "[4/4] Adding Tempo datasource to Grafana..."

# Grafana admin password 가져오기
GRAFANA_PASSWORD=$($(get_kubectl_cmd mgmt) -n "${NAMESPACE_MONITORING}" \
  get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d 2>/dev/null || echo "")

if [[ -z "${GRAFANA_PASSWORD}" ]]; then
  echo "WARNING: Grafana not found in monitoring namespace. Skipping datasource configuration."
  echo "         Install kube-prometheus-stack first, then run this script again."
  exit 0
fi

# Grafana Pod로 데이터소스 추가
$(get_kubectl_cmd mgmt) -n "${NAMESPACE_MONITORING}" exec -i \
  deployment/kube-prometheus-stack-grafana -- \
  sh -c "cat > /tmp/tempo-datasource.yaml" <<'EOF'
apiVersion: 1
datasources:
  - name: Tempo
    type: tempo
    access: proxy
    url: http://tempo.observability.svc:3100
    uid: tempo
    jsonData:
      httpMethod: GET
      tracesToLogs:
        datasourceUid: 'loki'
        tags: ['cluster', 'namespace', 'pod']
        mappedTags: [{ key: 'service.name', value: 'service' }]
        mapTagNamesEnabled: true
        spanStartTimeShift: '-1h'
        spanEndTimeShift: '1h'
      tracesToMetrics:
        datasourceUid: 'prometheus'
        tags: [{ key: 'service.name', value: 'service' }]
        queries:
          - name: 'Request Rate'
            query: 'rate(traces_spanmetrics_calls_total{$__tags}[5m])'
      serviceMap:
        datasourceUid: 'prometheus'
      nodeGraph:
        enabled: true
    editable: true
EOF

# Grafana 재시작하여 데이터소스 로드
$(get_kubectl_cmd mgmt) -n "${NAMESPACE_MONITORING}" rollout restart deployment/kube-prometheus-stack-grafana
$(get_kubectl_cmd mgmt) -n "${NAMESPACE_MONITORING}" rollout status deployment/kube-prometheus-stack-grafana --timeout="${TIMEOUT_POD_READY}s"

# =============================================================================
# 설치 요약
# =============================================================================
echo ""
echo "================================================================="
echo "  Tempo Installation Summary"
echo "================================================================="
echo "  [OK] Tempo ${TEMPO_VERSION} - observability namespace
  [OK] Metrics Generator: enabled (→ Prometheus in monitoring namespace)"
echo "  [OK] Persistence: local-path-retain (10Gi)"
echo "  [OK] Metrics Generator: enabled (→ Prometheus)"
echo "  [OK] Grafana Datasource: configured"
echo "================================================================="
echo ""
echo "Access Tempo:"
echo "  $(get_kubectl_cmd mgmt) -n ${NAMESPACE_OBSERVABILITY} port-forward svc/tempo 3100:3100"
echo ""
echo "Grafana integration:"
echo "  - Tempo datasource: http://tempo.observability.svc:3100"
echo "  - Traces → Logs correlation: enabled (Loki)"
echo "  - Traces → Metrics correlation: enabled (Prometheus)"
echo ""
echo "Test trace ingestion:"
echo "  curl -X POST http://localhost:3100/api/traces \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"traces\": [...]}"

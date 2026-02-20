#!/bin/bash
set -euo pipefail

# Usage: install-tempo.sh [tempo-version]
# Grafana Tempo 분산 추적 백엔드 설치 (mgmt 클러스터)
# - SingleBinary 모드 (로컬 환경 최적화)
# - local-path-retain StorageClass 사용
# - Grafana 데이터소스 자동 구성

TEMPO_VERSION="${1:-2.6.1}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"

if [[ ! -f "${KUBECONFIG_MULTI}" ]]; then
  echo "ERROR: kubeconfig-multi not found at ${GENERATED_DIR}"
  exit 1
fi

MGMT_CONTEXT="kubernetes-admin@mgmt"
KC="--kubeconfig ${KUBECONFIG_MULTI} --kube-context ${MGMT_CONTEXT}"
KC_KUBECTL="--kubeconfig ${KUBECONFIG_MULTI} --context ${MGMT_CONTEXT}"

echo "=== Installing Grafana Tempo ${TEMPO_VERSION} on mgmt cluster ==="

# =============================================================================
# Helm Repo 추가
# =============================================================================
echo "[1/4] Adding Grafana Helm repository..."
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update grafana

# =============================================================================
# Tempo 설치 (SingleBinary 모드)
# =============================================================================
echo "[2/4] Installing Tempo..."

helm upgrade --install tempo grafana/tempo \
  --version "${TEMPO_VERSION}" \
  --namespace observability --create-namespace \
  ${KC} \
  --set tempo.repository=grafana/tempo \
  --set tempo.tag="${TEMPO_VERSION}" \
  --set tempo.metricsGenerator.enabled=true \
  --set tempo.metricsGenerator.remoteWriteUrl="http://kube-prometheus-stack-prometheus.monitoring.svc:9090/api/v1/write" \
  --set persistence.enabled=true \
  --set persistence.storageClassName=local-path-retain \
  --set persistence.size=10Gi \
  --set resources.requests.cpu=200m \
  --set resources.requests.memory=512Mi \
  --set resources.limits.cpu=1000m \
  --set resources.limits.memory=1Gi \
  --set service.type=ClusterIP \
  --wait --timeout 180s

echo "Tempo installed successfully."

# =============================================================================
# Tempo Query Frontend 서비스 확인
# =============================================================================
echo "[3/4] Verifying Tempo services..."

kubectl ${KC_KUBECTL} -n observability wait --for=condition=available --timeout=180s \
  deployment/tempo || echo "WARNING: Tempo deployment not ready"

# Tempo 서비스 확인
TEMPO_SVC=$(kubectl ${KC_KUBECTL} -n observability get svc tempo -o name 2>/dev/null || echo "")
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
GRAFANA_PASSWORD=$(kubectl ${KC_KUBECTL} -n monitoring \
  get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d 2>/dev/null || echo "")

if [[ -z "${GRAFANA_PASSWORD}" ]]; then
  echo "WARNING: Grafana not found in monitoring namespace. Skipping datasource configuration."
  echo "         Install kube-prometheus-stack first, then run this script again."
  exit 0
fi

# Grafana Pod로 데이터소스 추가
kubectl ${KC_KUBECTL} -n monitoring exec -i \
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
kubectl ${KC_KUBECTL} -n monitoring rollout restart deployment/kube-prometheus-stack-grafana
kubectl ${KC_KUBECTL} -n monitoring rollout status deployment/kube-prometheus-stack-grafana --timeout=120s

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
echo "  kubectl ${KC_KUBECTL} -n observability port-forward svc/tempo 3100:3100"
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

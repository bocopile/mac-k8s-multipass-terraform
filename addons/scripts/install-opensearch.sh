#!/bin/bash
set -euo pipefail

# Usage: install-opensearch.sh [opensearch-version]
# mgmt 클러스터에 OpenSearch를 설치합니다. (감사·보안 로그 검색 분석)
# - Single node 모드 (시연/학습 환경)
# - namespace: observability (기존 관찰성 스택과 통합)
# - 보안 비활성화 (시연 목적)
# - LoadBalancer: app 클러스터 Alloy에서 직접 접근
#
# Alloy 이중화 연동:
#   loki.source.kubernetes → loki.write (Loki, 전체)
#                          → otelcol.receiver.loki (OpenSearch, 선별)
#                            → processor.filter (security/kube-system 네임스페이스)
#                            → exporter.elasticsearch (OpenSearch)

OPENSEARCH_VERSION="${1:-2.18.0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../scripts/lib/constants.sh"

# Setup
setup_common_vars

# =============================================================================
# Helm Repo 등록
# =============================================================================
echo "=== Adding OpenSearch Helm repository ==="
helm repo add opensearch https://opensearch-project.github.io/helm-charts 2>/dev/null || true
helm repo update

# =============================================================================
# 1. OpenSearch 설치 (mgmt 클러스터)
# =============================================================================
echo ""
echo "=== [1/3] Installing OpenSearch ${OPENSEARCH_VERSION} on mgmt ==="

ensure_namespace "${NAMESPACE_OBSERVABILITY}" "mgmt"

$(get_helm_cmd mgmt) upgrade --install opensearch opensearch/opensearch \
  --namespace "${NAMESPACE_OBSERVABILITY}" \
  --version "${OPENSEARCH_VERSION}" \
  --set singleNode=true \
  --set replicas=1 \
  --set minimumMasterNodes=1 \
  --set "opensearchJavaOpts=-Xmx512m -Xms512m" \
  --set resources.requests.memory=1Gi \
  --set resources.requests.cpu=100m \
  --set resources.limits.memory=1536Mi \
  --set resources.limits.cpu=500m \
  --set persistence.enabled=true \
  --set persistence.size=10Gi \
  --set persistence.storageClass=local-path-retain \
  --set service.type=ClusterIP \
  --set "securityConfig.enabled=false" \
  --set "plugins.security.disabled=true" \
  --set priorityClassName=platform-normal \
  --wait --timeout 300s

echo "OpenSearch installed."

# LoadBalancer 서비스 생성 (app 클러스터 Alloy에서 접근)
echo "Creating OpenSearch LoadBalancer service..."
$(get_kubectl_cmd mgmt) -n "${NAMESPACE_OBSERVABILITY}" apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: opensearch-lb
  namespace: observability
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: opensearch
    app.kubernetes.io/instance: opensearch
  ports:
  - name: http
    port: 9200
    targetPort: 9200
    protocol: TCP
EOF

# LoadBalancer IP 대기
echo "Waiting for OpenSearch LoadBalancer IP..."
OPENSEARCH_LB_IP=""
for i in $(seq 1 30); do
  OPENSEARCH_LB_IP=$($(get_kubectl_cmd mgmt) -n "${NAMESPACE_OBSERVABILITY}" \
    get svc opensearch-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "${OPENSEARCH_LB_IP}" ]]; then
    echo "${OPENSEARCH_LB_IP}" > "${GENERATED_DIR}/opensearch-lb-ip"
    echo "OpenSearch LoadBalancer IP: ${OPENSEARCH_LB_IP}"
    break
  fi
  echo "  Waiting... (${i}/30)"
  sleep 5
done

if [[ -z "${OPENSEARCH_LB_IP}" ]]; then
  echo "WARNING: LoadBalancer IP not assigned. Using in-cluster address."
  OPENSEARCH_LB_IP="opensearch.${NAMESPACE_OBSERVABILITY}.svc.cluster.local"
  echo "${OPENSEARCH_LB_IP}" > "${GENERATED_DIR}/opensearch-lb-ip"
fi

# =============================================================================
# 2. 인덱스 템플릿 생성
# =============================================================================
echo ""
echo "=== [2/3] Creating index templates ==="

# OpenSearch API 준비 대기
echo "Waiting for OpenSearch API..."
for i in $(seq 1 20); do
  if $(get_kubectl_cmd mgmt) -n "${NAMESPACE_OBSERVABILITY}" \
    exec -it opensearch-0 -- curl -sf http://localhost:9200/_cluster/health &>/dev/null; then
    echo "OpenSearch API is ready."
    break
  fi
  echo "  Waiting... (${i}/20)"
  sleep 5
done

# logs-* 인덱스 템플릿 (샤드 1개, 레플리카 0)
$(get_kubectl_cmd mgmt) -n "${NAMESPACE_OBSERVABILITY}" \
  exec opensearch-0 -- curl -sf -X PUT "http://localhost:9200/_index_template/logs" \
  -H "Content-Type: application/json" \
  -d '{
    "index_patterns": ["logs-*"],
    "template": {
      "settings": {
        "number_of_shards": 1,
        "number_of_replicas": 0,
        "index.lifecycle.name": "logs-policy"
      },
      "mappings": {
        "dynamic": true,
        "properties": {
          "@timestamp": { "type": "date" },
          "cluster":    { "type": "keyword" },
          "namespace":  { "type": "keyword" },
          "pod":        { "type": "keyword" },
          "container":  { "type": "keyword" },
          "body":       { "type": "text" },
          "severity":   { "type": "keyword" }
        }
      }
    }
  }' && echo "Index template created." || echo "WARNING: Index template creation failed."

# ILM 정책 (14일 보관)
$(get_kubectl_cmd mgmt) -n "${NAMESPACE_OBSERVABILITY}" \
  exec opensearch-0 -- curl -sf -X PUT "http://localhost:9200/_plugins/_ism/policies/logs-policy" \
  -H "Content-Type: application/json" \
  -d '{
    "policy": {
      "description": "Logs retention policy (14 days)",
      "default_state": "hot",
      "states": [
        {
          "name": "hot",
          "actions": [],
          "transitions": [
            {
              "state_name": "delete",
              "conditions": { "min_index_age": "14d" }
            }
          ]
        },
        {
          "name": "delete",
          "actions": [{ "delete": {} }],
          "transitions": []
        }
      ]
    }
  }' && echo "ISM policy created." || echo "WARNING: ISM policy creation failed."

# =============================================================================
# 3. OpenSearch Dashboards 설치
# =============================================================================
echo ""
echo "=== [3/3] Installing OpenSearch Dashboards ==="

$(get_helm_cmd mgmt) upgrade --install opensearch-dashboards opensearch/opensearch-dashboards \
  --namespace "${NAMESPACE_OBSERVABILITY}" \
  --set "opensearchHosts=http://opensearch.${NAMESPACE_OBSERVABILITY}.svc.cluster.local:9200" \
  --set resources.requests.memory=256Mi \
  --set resources.requests.cpu=100m \
  --set resources.limits.memory=512Mi \
  --set resources.limits.cpu=300m \
  --set service.type=ClusterIP \
  --set priorityClassName=platform-normal \
  --wait --timeout 180s

echo "OpenSearch Dashboards installed."

# =============================================================================
# 설치 요약
# =============================================================================
echo ""
echo "================================================================="
echo "  OpenSearch Installation Summary (mgmt cluster)"
echo "================================================================="
echo "  [OK] OpenSearch            - ${NAMESPACE_OBSERVABILITY} namespace"
echo "  [OK] OpenSearch Dashboards - ${NAMESPACE_OBSERVABILITY} namespace"
echo "  [OK] LoadBalancer IP       - ${OPENSEARCH_LB_IP}"
echo "  [OK] Index template        - logs-* (14d retention, no replica)"
echo "================================================================="
echo ""
echo "OpenSearch Dashboards 접근:"
echo "  $(get_kubectl_cmd mgmt) -n ${NAMESPACE_OBSERVABILITY} port-forward svc/opensearch-dashboards 5601:5601"
echo "  → http://localhost:5601"
echo ""
echo "OpenSearch API:"
echo "  $(get_kubectl_cmd mgmt) -n ${NAMESPACE_OBSERVABILITY} port-forward svc/opensearch 9200:9200"
echo "  → curl http://localhost:9200/_cat/indices"
echo ""
echo "다음 단계: Alloy 재설치로 OpenSearch 이중화 활성화"
echo "  addons/install.sh alloy"

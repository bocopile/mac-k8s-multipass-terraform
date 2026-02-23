#!/bin/bash
set -euo pipefail

# Usage: install-loki.sh
# mgmt 클러스터에 Loki를 설치합니다.
# - Loki: SingleBinary 모드 (로컬 개발 환경 적합)
# - 로그 수집 에이전트: Grafana Alloy (install-alloy.sh에서 처리)
# - ADR-006 관찰성 아키텍처 참조

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../scripts/lib/constants.sh"

# Setup
setup_common_vars

# =============================================================================
# Helm Repo 등록
# =============================================================================
add_helm_repo "grafana" "${HELM_REPO_GRAFANA}"

# =============================================================================
# 1. Loki 설치 (mgmt 클러스터)
# =============================================================================
echo ""
echo "=== [1/1] Installing Loki on mgmt cluster ==="

ensure_namespace "${NAMESPACE_OBSERVABILITY}" "mgmt"

$(get_helm_cmd mgmt) upgrade --install loki grafana/loki \
  --namespace "${NAMESPACE_OBSERVABILITY}" \
  --set deploymentMode=SingleBinary \
  --set singleBinary.replicas=1 \
  --set singleBinary.resources.requests.memory=256Mi \
  --set singleBinary.resources.requests.cpu=100m \
  --set singleBinary.resources.limits.memory=512Mi \
  --set singleBinary.resources.limits.cpu=500m \
  --set singleBinary.persistence.storageClass=local-path-retain \
  --set singleBinary.persistence.size=10Gi \
  --set loki.auth_enabled=false \
  --set loki.commonConfig.replication_factor=1 \
  --set loki.storage.type=filesystem \
  --set loki.limits_config.retention_period=168h \
  --set loki.schemaConfig.configs[0].from=2024-01-01 \
  --set loki.schemaConfig.configs[0].store=tsdb \
  --set loki.schemaConfig.configs[0].object_store=filesystem \
  --set loki.schemaConfig.configs[0].schema=v13 \
  --set loki.schemaConfig.configs[0].index.prefix=index_ \
  --set loki.schemaConfig.configs[0].index.period=24h \
  --set gateway.enabled=false \
  --set backend.replicas=0 \
  --set read.replicas=0 \
  --set write.replicas=0 \
  --set chunksCache.enabled=false \
  --set resultsCache.enabled=false \
  --set singleBinary.priorityClassName=platform-normal \
  --wait --timeout 180s

echo "Loki installed on mgmt cluster."

# Loki LoadBalancer 서비스 생성 (app 클러스터에서 접근용)
echo "Creating Loki LoadBalancer service..."
$(get_kubectl_cmd mgmt) -n "${NAMESPACE_OBSERVABILITY}" apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: loki-lb
  namespace: observability
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: loki
    app.kubernetes.io/component: single-binary
  ports:
  - name: http
    port: 3100
    targetPort: 3100
    protocol: TCP
EOF

# Loki LoadBalancer IP 대기
echo "Waiting for Loki LoadBalancer IP..."
LOKI_LB_IP=""
for i in $(seq 1 30); do
  LOKI_LB_IP=$($(get_kubectl_cmd mgmt) -n "${NAMESPACE_OBSERVABILITY}" \
    get svc loki-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "${LOKI_LB_IP}" ]]; then
    echo "${LOKI_LB_IP}" > "${GENERATED_DIR}/loki-lb-ip"
    echo "Loki LoadBalancer IP: ${LOKI_LB_IP}"
    break
  fi
  echo "  Waiting... (${i}/30)"
  sleep 5
done

if [[ -z "${LOKI_LB_IP}" ]]; then
  echo "WARNING: Loki LoadBalancer IP not assigned. Using in-cluster address for mgmt."
  LOKI_LB_IP="loki.observability.svc.cluster.local"
fi

# =============================================================================
# Grafana에 Loki 데이터소스 추가
# =============================================================================
echo ""
echo "=== Adding Loki datasource to Grafana ==="

GRAFANA_EXISTS=$($(get_kubectl_cmd mgmt) -n "${NAMESPACE_MONITORING}" get svc kube-prometheus-stack-grafana &>/dev/null && echo "true" || echo "false")

if [[ "${GRAFANA_EXISTS}" == "true" ]]; then
  $(get_kubectl_cmd mgmt) -n "${NAMESPACE_MONITORING}" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasource-loki
  namespace: monitoring
  labels:
    grafana_datasource: "1"
data:
  loki-datasource.yaml: |
    apiVersion: 1
    datasources:
    - name: Loki
      type: loki
      url: http://loki.observability.svc.cluster.local:3100
      access: proxy
      isDefault: false
EOF
  echo "Loki datasource added to Grafana."
else
  echo "NOTE: Grafana not found. Install kube-prometheus-stack first."
fi

# =============================================================================
# 설치 요약
# =============================================================================
echo ""
echo "================================================================="
echo "  Loki Installation Summary"
echo "================================================================="
echo "  [OK] Loki - mgmt:observability namespace (SingleBinary, 7d retention)"
echo ""
echo "NOTE: 로그 수집 에이전트는 Grafana Alloy가 담당합니다."
echo "  다음 단계: addons/install.sh alloy"
echo "================================================================="
echo ""
echo "Query logs via Grafana:"
echo "  $(get_kubectl_cmd mgmt) -n ${NAMESPACE_MONITORING} port-forward svc/kube-prometheus-stack-grafana 3000:80"
echo "  → Explore → Loki datasource → {cluster=\"app1\"}"
echo ""
echo "Estimated RAM: ~400MB (Loki on mgmt)"

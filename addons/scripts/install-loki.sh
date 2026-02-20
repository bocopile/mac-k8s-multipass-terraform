#!/bin/bash
set -euo pipefail

# Usage: install-loki.sh
# mgmt 클러스터에 Loki를 설치하고, app 클러스터에 Promtail을 배포합니다.
# - Loki: SingleBinary 모드 (로컬 개발 환경 적합)
# - Promtail: 각 app 클러스터의 로그를 mgmt의 Loki로 전송
# - ADR-006 관찰성 아키텍처 참조

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"
CLUSTERS_JSON="${GENERATED_DIR}/clusters.json"

if [[ ! -f "${CLUSTERS_JSON}" ]]; then
  echo "ERROR: clusters.json not found at ${CLUSTERS_JSON}"
  exit 1
fi

# mgmt 클러스터 컨텍스트
MGMT_CONTEXT="kubernetes-admin@mgmt"
KC_MGMT="--kubeconfig ${KUBECONFIG_MULTI} --kube-context ${MGMT_CONTEXT}"
KC_MGMT_KUBECTL="--kubeconfig ${KUBECONFIG_MULTI} --context ${MGMT_CONTEXT}"

# =============================================================================
# Helm Repo 등록
# =============================================================================
echo "=== Adding Grafana Helm repository ==="
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update

# =============================================================================
# 1. Loki 설치 (mgmt 클러스터)
# =============================================================================
echo ""
echo "=== [1/2] Installing Loki on mgmt cluster ==="

kubectl ${KC_MGMT_KUBECTL} create namespace observability 2>/dev/null || true

helm upgrade --install loki grafana/loki \
  --namespace observability \
  ${KC_MGMT} \
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
  --wait --timeout 180s

echo "Loki installed on mgmt cluster."

# Loki LoadBalancer 서비스 생성 (app 클러스터에서 접근용)
echo "Creating Loki LoadBalancer service..."
kubectl ${KC_MGMT_KUBECTL} -n observability apply -f - <<'EOF'
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
  LOKI_LB_IP=$(kubectl ${KC_MGMT_KUBECTL} -n observability \
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

GRAFANA_EXISTS=$(kubectl ${KC_MGMT_KUBECTL} -n monitoring get svc kube-prometheus-stack-grafana &>/dev/null && echo "true" || echo "false")

if [[ "${GRAFANA_EXISTS}" == "true" ]]; then
  kubectl ${KC_MGMT_KUBECTL} -n monitoring apply -f - <<EOF
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
# 2. Promtail 설치 (app 클러스터들)
# =============================================================================
echo ""
echo "=== [2/2] Installing Promtail on app clusters ==="

CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  CONTEXT="kubernetes-admin@${CLUSTER}"
  KC_APP="--kubeconfig ${KUBECONFIG_MULTI} --kube-context ${CONTEXT}"
  KC_APP_KUBECTL="--kubeconfig ${KUBECONFIG_MULTI} --context ${CONTEXT}"

  if [[ "${CLUSTER}" == "mgmt" ]]; then
    # mgmt는 Loki와 같은 클러스터이므로 in-cluster 주소 사용
    LOKI_URL="http://loki.observability.svc.cluster.local:3100"
  else
    # app 클러스터는 LoadBalancer IP로 접근
    LOKI_URL="http://${LOKI_LB_IP}:3100"
  fi

  echo ""
  echo "--- Installing Promtail on ${CLUSTER} (loki: ${LOKI_URL}) ---"

  kubectl ${KC_APP_KUBECTL} create namespace observability 2>/dev/null || true

  # PSA 예외 (Promtail은 호스트 로그 접근에 privileged 필요)
  kubectl ${KC_APP_KUBECTL} label namespace observability \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged \
    --overwrite

  helm upgrade --install promtail grafana/promtail \
    --namespace observability \
    ${KC_APP} \
    --set config.clients[0].url="${LOKI_URL}/loki/api/v1/push" \
    --set config.snippets.extraRelabelConfigs[0].target_label=cluster \
    --set config.snippets.extraRelabelConfigs[0].replacement="${CLUSTER}" \
    --set config.snippets.extraRelabelConfigs[0].action=replace \
    --set resources.requests.memory=64Mi \
    --set resources.requests.cpu=50m \
    --set resources.limits.memory=128Mi \
    --set resources.limits.cpu=100m \
    --wait --timeout 120s

  echo "Promtail installed on ${CLUSTER}."
done

# =============================================================================
# 설치 요약
# =============================================================================
echo ""
echo "================================================================="
echo "  Loki + Promtail Installation Summary"
echo "================================================================="
echo "  [OK] Loki         - mgmt:observability namespace (SingleBinary, 7d retention)"
echo "  [OK] Promtail     - all clusters:observability namespace (DaemonSet)"
echo "================================================================="
echo ""
echo "Query logs via Grafana:"
echo "  kubectl ${KC_MGMT_KUBECTL} -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80"
echo "  → Explore → Loki datasource → {cluster=\"app1\"}"
echo ""
echo "Estimated RAM: ~400MB (Loki on mgmt) + ~100MB per cluster (Promtail)"

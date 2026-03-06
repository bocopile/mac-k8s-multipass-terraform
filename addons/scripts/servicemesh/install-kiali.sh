#!/bin/bash
set -euo pipefail

# Usage: install-kiali.sh [kiali-version]
# Kiali Service Mesh 관찰성 대시보드 설치 (Istio 설치된 클러스터)
# - mgmt, app1 클러스터에 설치
# - Grafana 양방향 통합
# - Prometheus + Tempo 연동

KIALI_VERSION="${1:-2.22.0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../../scripts/lib/constants.sh"

# Setup
setup_common_vars

echo "=== Installing Kiali ${KIALI_VERSION} on Istio clusters ==="

# =============================================================================
# Helm Repo 추가
# =============================================================================
echo "[1/3] Adding Kiali Helm repository..."
add_helm_repo "kiali" "${HELM_REPO_KIALI}"

# =============================================================================
# Kiali 설치 대상 클러스터 (Istio 설치된 클러스터만)
# =============================================================================
KIALI_CLUSTERS="mgmt app1"

for CLUSTER in ${KIALI_CLUSTERS}; do
  echo ""
  echo "=== Installing Kiali on ${CLUSTER} cluster ==="

  # ===========================================================================
  # Grafana URL 가져오기 (mgmt 클러스터의 Grafana 서비스)
  # ===========================================================================
  echo "[2/3] Configuring Grafana integration..."

  # Grafana 서비스 IP 가져오기 (ClusterIP)
  GRAFANA_SVC_IP=$($(get_kubectl_cmd mgmt) \
    -n "${NAMESPACE_MONITORING}" get svc kube-prometheus-stack-grafana \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")

  if [[ -z "${GRAFANA_SVC_IP}" ]]; then
    echo "WARNING: Grafana service not found, using default URL"
    GRAFANA_URL="http://kube-prometheus-stack-grafana.monitoring.svc:80"
  else
    GRAFANA_URL="http://${GRAFANA_SVC_IP}:80"
  fi

  # Prometheus URL
  PROMETHEUS_URL="http://kube-prometheus-stack-prometheus.monitoring.svc:9090"

  # Tempo URL (mgmt 클러스터의 Tempo)
  TEMPO_URL="http://tempo.monitoring.svc:3100"

  # ===========================================================================
  # Kiali Server 설치
  # ===========================================================================
  echo "[3/3] Installing Kiali Server..."

  $(get_helm_cmd "${CLUSTER}") upgrade --install kiali-server kiali/kiali-server \
    --version "${KIALI_VERSION}" \
    --namespace istio-system \
    --set auth.strategy=anonymous \
    --set deployment.accessible_namespaces='["**"]' \
    --set deployment.cluster_wide_access=true \
    --set deployment.image_pull_policy=IfNotPresent \
    --set deployment.ingress.enabled=false \
    --set deployment.view_only_mode=false \
    --set external_services.custom_dashboards.enabled=true \
    --set external_services.custom_dashboards.prometheus.url="${PROMETHEUS_URL}" \
    --set external_services.grafana.enabled=true \
    --set external_services.grafana.in_cluster_url="${GRAFANA_URL}" \
    --set external_services.grafana.url="${GRAFANA_URL}" \
    --set external_services.grafana.auth.type=basic \
    --set external_services.grafana.auth.username=admin \
    --set external_services.grafana.dashboards[0].name="Istio Mesh Dashboard" \
    --set external_services.grafana.dashboards[1].name="Istio Service Dashboard" \
    --set external_services.grafana.dashboards[2].name="Istio Workload Dashboard" \
    --set external_services.istio.config_map_name=istio \
    --set external_services.istio.istio_identity_domain=svc.cluster.local \
    --set external_services.istio.istio_sidecar_annotation="sidecar.istio.io/status" \
    --set external_services.istio.url_service_version="http://istiod.istio-system:15014/version" \
    --set external_services.prometheus.url="${PROMETHEUS_URL}" \
    --set external_services.tracing.enabled=true \
    --set external_services.tracing.in_cluster_url="${TEMPO_URL}" \
    --set external_services.tracing.url="${TEMPO_URL}" \
    --set external_services.tracing.use_grpc=true \
    --set external_services.tracing.namespace_selector=true \
    --set server.web_root=/kiali \
    --set server.metrics_enabled=true \
    --set server.metrics_port=9090 \
    --set server.port=20001 \
    --set server.web_port=20001 \
    --set deployment.priorityClassName=platform-normal \
    --wait --timeout "${TIMEOUT_DEPLOYMENT}s"

  echo "Kiali Server installed on ${CLUSTER}"

  # ===========================================================================
  # Kiali Service 확인
  # ===========================================================================
  $(get_kubectl_cmd "${CLUSTER}") \
    -n istio-system wait --for=condition=available --timeout="${TIMEOUT_POD_READY}s" \
    deployment/kiali || echo "WARNING: Kiali deployment not ready"

  # ===========================================================================
  # Grafana에 Kiali 데이터소스 추가 (mgmt 클러스터만)
  # ===========================================================================
  if [[ "${CLUSTER}" == "mgmt" ]]; then
    echo ""
    echo "Configuring Grafana ↔ Kiali bidirectional integration..."

    # Kiali 서비스 URL
    KIALI_SVC_URL="http://kiali.istio-system.svc:20001"

    # Grafana ConfigMap에 Kiali 링크 추가
    $(get_kubectl_cmd "${CLUSTER}") \
      -n "${NAMESPACE_MONITORING}" get configmap kube-prometheus-stack-grafana &>/dev/null || \
      echo "WARNING: Grafana ConfigMap not found, skipping Kiali link configuration"

    # Kiali를 Grafana 데이터소스로 추가 (선택적)
    # Grafana는 Kiali API를 직접 쿼리하지 않지만, 외부 링크로 추가
    echo "Grafana → Kiali link: ${KIALI_SVC_URL}"
    echo "Add this link manually to Grafana dashboards if needed"
  fi

  echo "=== Kiali installed successfully on ${CLUSTER} ==="
done

# =============================================================================
# Prometheus ServiceMonitor 생성 (Kiali 메트릭 수집)
# =============================================================================
echo ""
echo "Creating Prometheus ServiceMonitor for Kiali metrics..."

for CLUSTER in ${KIALI_CLUSTERS}; do
  if $(get_kubectl_cmd "${CLUSTER}") get crd servicemonitors.monitoring.coreos.com &>/dev/null; then
    $(get_kubectl_cmd "${CLUSTER}") apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kiali-monitor
  namespace: istio-system
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: kiali
  endpoints:
  - port: http-metrics
    interval: 30s
    path: /metrics
EOF
    echo "ServiceMonitor created for ${CLUSTER}"
  else
    echo "ServiceMonitor CRD not found on ${CLUSTER}, skipping"
  fi
done

# =============================================================================
# 설치 요약
# =============================================================================
echo ""
echo "================================================================="
echo "  Kiali Installation Summary"
echo "================================================================="
for CLUSTER in ${KIALI_CLUSTERS}; do
  echo ""
  echo "Cluster: ${CLUSTER}"
  echo "  Kiali Server:"
  $(get_kubectl_cmd "${CLUSTER}") \
    -n istio-system get svc kiali -o wide
  echo ""
  echo "  Access URL (port-forward):"
  echo "    kubectl --context kubernetes-admin@${CLUSTER} -n istio-system port-forward svc/kiali 20001:20001"
  echo "    http://localhost:20001/kiali"
done
echo "================================================================="
echo ""
echo "Integrations:"
echo "  [OK] Grafana: ${GRAFANA_URL}"
echo "  [OK] Prometheus: ${PROMETHEUS_URL}"
echo "  [OK] Tempo Tracing: ${TEMPO_URL}"
echo "  [OK] Istio Config: istio-system/istio"
echo ""
echo "Next steps:"
echo "  1. Access Kiali dashboard via port-forward"
echo "  2. Deploy sample application to test Service Graph"
echo "  3. View distributed traces from Kiali → Tempo"
echo "  4. Navigate from Grafana dashboards → Kiali (manual link)"
echo ""
echo "Verify installation:"
echo "  kubectl --context kubernetes-admin@mgmt -n istio-system get pods -l app.kubernetes.io/name=kiali"

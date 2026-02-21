#!/bin/bash
set -euo pipefail

# Usage: install-prometheus-stack.sh
# mgmt 클러스터에 kube-prometheus-stack (Prometheus + Grafana + Alertmanager)을 설치합니다.
# - Prometheus: 로컬 메트릭 수집 + Thanos Sidecar 미사용 (Thanos Receive 아키텍처)
# - Grafana: 대시보드 시각화 (Thanos Query를 데이터소스로 연동)
# - Alertmanager: 알림 파이프라인
# - ADR-006 참조

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../scripts/lib/constants.sh"
source "${SCRIPT_DIR}/../../scripts/lib/credentials.sh"

# Setup
setup_common_vars

# Generate Grafana admin password
GRAFANA_ADMIN_PASSWORD=$(generate_password 24)

# =============================================================================
# Helm Repo 등록
# =============================================================================
add_helm_repo "prometheus-community" "${HELM_REPO_PROMETHEUS}"

# =============================================================================
# monitoring 네임스페이스 생성 (Privileged PSA)
# =============================================================================
ensure_namespace_privileged "${NAMESPACE_MONITORING}" "mgmt"

# =============================================================================
# kube-prometheus-stack 설치
# =============================================================================
log_info "Installing kube-prometheus-stack on mgmt cluster"

# Thanos Receive IP 확인 (이미 설치된 경우)
THANOS_QUERY_SVC="http://thanos-query.thanos.svc.cluster.local:9090"

$(get_helm_cmd mgmt) upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace "${NAMESPACE_MONITORING}" \
  --set prometheus.prometheusSpec.retention=7d \
  --set prometheus.prometheusSpec.retentionSize=5GB \
  --set prometheus.prometheusSpec.resources.requests.memory=512Mi \
  --set prometheus.prometheusSpec.resources.requests.cpu=200m \
  --set prometheus.prometheusSpec.resources.limits.memory=1Gi \
  --set prometheus.prometheusSpec.resources.limits.cpu=500m \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName="${STORAGE_CLASS_RETAIN}" \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage="${STORAGE_SIZE_MEDIUM}" \
  --set prometheus.prometheusSpec.externalLabels.cluster=mgmt \
  --set prometheus.prometheusSpec.enableRemoteWriteReceiver=true \
  --set prometheus.service.type=ClusterIP \
  --set grafana.enabled=true \
  --set grafana.adminPassword="${GRAFANA_ADMIN_PASSWORD}" \
  --set grafana.service.type=ClusterIP \
  --set grafana.resources.requests.memory="${RESOURCES_MEDIUM_REQUESTS_MEMORY}" \
  --set grafana.resources.requests.cpu="${RESOURCES_MEDIUM_REQUESTS_CPU}" \
  --set grafana.resources.limits.memory="${RESOURCES_MEDIUM_LIMITS_MEMORY}" \
  --set grafana.resources.limits.cpu="${RESOURCES_SMALL_LIMITS_CPU}" \
  --set grafana.persistence.enabled=true \
  --set grafana.persistence.storageClassName="${STORAGE_CLASS_RETAIN}" \
  --set grafana.persistence.size="${STORAGE_SIZE_SMALL}" \
  --set grafana.sidecar.dashboards.enabled=true \
  --set grafana.sidecar.datasources.enabled=true \
  --set alertmanager.enabled=true \
  --set alertmanager.alertmanagerSpec.resources.requests.memory=64Mi \
  --set alertmanager.alertmanagerSpec.resources.requests.cpu=50m \
  --set alertmanager.alertmanagerSpec.resources.limits.memory=128Mi \
  --set alertmanager.alertmanagerSpec.resources.limits.cpu=100m \
  --set alertmanager.service.type=ClusterIP \
  --set nodeExporter.enabled=true \
  --set kubeStateMetrics.enabled=true \
  --wait --timeout 300s

echo "kube-prometheus-stack installed."

# Save Grafana credentials
save_credential "GRAFANA_ADMIN_PASSWORD" "${GRAFANA_ADMIN_PASSWORD}"

# =============================================================================
# Grafana에 Thanos Query 데이터소스 추가
# =============================================================================
echo ""
echo "=== Configuring Grafana Thanos Query datasource ==="

# Thanos가 이미 설치되어 있으면 datasource 추가
THANOS_EXIST=$($(get_kubectl_cmd mgmt) -n thanos get svc thanos-query 2>/dev/null && echo "true" || echo "false")

if [[ "${THANOS_EXIST}" == "true" ]]; then
  $(get_kubectl_cmd mgmt) -n "${NAMESPACE_MONITORING}" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasource-thanos
  namespace: monitoring
  labels:
    grafana_datasource: "1"
data:
  thanos-datasource.yaml: |
    apiVersion: 1
    datasources:
    - name: Thanos
      type: prometheus
      url: ${THANOS_QUERY_SVC}
      access: proxy
      isDefault: false
      jsonData:
        timeInterval: 30s
EOF
  echo "Thanos Query datasource added to Grafana."
else
  echo "NOTE: Thanos not yet installed. Run install-thanos.sh first for multi-cluster metrics."
fi

# =============================================================================
# 설치 요약
# =============================================================================
echo ""
echo "================================================================="
echo "  Prometheus Stack Installation Summary (mgmt cluster)"
echo "================================================================="
echo "  [OK] Prometheus     - monitoring namespace (7d retention)"
echo "  [OK] Grafana        - monitoring namespace (password saved to credentials)"
echo "  [OK] Alertmanager   - monitoring namespace"
echo "  [OK] Node Exporter  - monitoring namespace (DaemonSet)"
echo "  [OK] kube-state-metrics - monitoring namespace"
echo "================================================================="
echo ""
echo "Access Grafana:"
echo "  $(get_kubectl_cmd mgmt) -n ${NAMESPACE_MONITORING} port-forward svc/kube-prometheus-stack-grafana 3000:80"
echo "  Username: admin"
echo "  Password: grep GRAFANA_ADMIN_PASSWORD ${CREDENTIALS_FILE}"
echo ""
echo "Access Prometheus:"
echo "  $(get_kubectl_cmd mgmt) -n ${NAMESPACE_MONITORING} port-forward svc/kube-prometheus-stack-prometheus 9090:9090"
echo ""
echo "Estimated RAM: ~1.0GB on mgmt-worker-0"

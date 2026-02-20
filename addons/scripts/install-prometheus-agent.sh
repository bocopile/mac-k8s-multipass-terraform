#!/bin/bash
set -euo pipefail

# Usage: install-prometheus-agent.sh
# app 클러스터에 Prometheus Agent Mode 설치 (remote_write → mgmt Thanos Receive)
# ADR-006: 에이전트 모드 아키텍처

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../scripts/lib/constants.sh"

# Setup
setup_common_vars

# Helm repo 추가
add_helm_repo "prometheus-community" "${HELM_REPO_PROMETHEUS_COMMUNITY}"

# Thanos Receive IP 확인
THANOS_IP_FILE="${GENERATED_DIR}/thanos-receive-ip"
THANOS_RECEIVE_IP=""

if [[ -f "${THANOS_IP_FILE}" ]]; then
  THANOS_RECEIVE_IP=$(cat "${THANOS_IP_FILE}")
  echo "Thanos Receive IP (from cache): ${THANOS_RECEIVE_IP}"
else
  # Fallback: mgmt 클러스터에서 직접 조회
  echo "Thanos IP file not found. Querying mgmt cluster..."
  THANOS_RECEIVE_IP=$($(get_kubectl_cmd mgmt) \
    -n "${NAMESPACE_OBSERVABILITY}" get svc thanos-receive \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

  if [[ -n "${THANOS_RECEIVE_IP}" ]]; then
    echo "Thanos Receive IP (from cluster): ${THANOS_RECEIVE_IP}"
    # Cache for future use
    echo "${THANOS_RECEIVE_IP}" > "${THANOS_IP_FILE}"
  fi
fi

if [[ -z "${THANOS_RECEIVE_IP}" ]]; then
  echo "=========================================================="
  echo "ERROR: Thanos Receive IP를 확인할 수 없습니다."
  echo ""
  echo "가능한 원인:"
  echo "  1. Thanos가 설치되지 않았음"
  echo "  2. LoadBalancer IP가 할당되지 않음 (MetalLB 확인)"
  echo "  3. mgmt 클러스터에 접근할 수 없음"
  echo ""
  echo "해결 방법:"
  echo "  1. 먼저 install-thanos.sh를 실행하세요"
  echo "  2. MetalLB가 정상 동작하는지 확인하세요:"
  echo "     kubectl --context kubernetes-admin@mgmt -n observability get svc thanos-receive"
  echo "=========================================================="
  exit 1
fi

REMOTE_WRITE_URL="http://${THANOS_RECEIVE_IP}:19291/api/v1/receive"
echo "Remote write target: ${REMOTE_WRITE_URL}"

# app 클러스터에만 설치 (mgmt 제외)
CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  # mgmt 클러스터는 건너뜀 (전체 Prometheus 스택 사용)
  if [[ "${CLUSTER}" == "mgmt" ]]; then
    echo "=== Skipping mgmt cluster (uses full Prometheus stack) ==="
    continue
  fi

  echo "=== Installing Prometheus Agent on ${CLUSTER} ==="

  ensure_namespace "${NAMESPACE_MONITORING}" "${CLUSTER}"

  $(get_helm_cmd "${CLUSTER}") upgrade --install prometheus-agent prometheus-community/kube-prometheus-stack \
    --namespace "${NAMESPACE_MONITORING}" \
    --set prometheus.prometheusSpec.mode=Agent \
    --set "prometheus.prometheusSpec.remoteWrite[0].url=${REMOTE_WRITE_URL}" \
    --set "prometheus.prometheusSpec.remoteWrite[0].writeRelabelConfigs[0].sourceLabels={__name__}" \
    --set "prometheus.prometheusSpec.remoteWrite[0].writeRelabelConfigs[0].action=keep" \
    --set "prometheus.prometheusSpec.remoteWrite[0].writeRelabelConfigs[0].regex=.*" \
    --set "prometheus.prometheusSpec.externalLabels.cluster=${CLUSTER}" \
    --set prometheus.prometheusSpec.retention=2h \
    --set prometheus.prometheusSpec.walCompression=true \
    --set grafana.enabled=false \
    --set alertmanager.enabled=false \
    --set thanosRuler.enabled=false \
    --set prometheusOperator.enabled=true \
    --set nodeExporter.enabled=true \
    --set kubeStateMetrics.enabled=true \
    --set prometheus.serviceMonitor.selfMonitor=true \
    --wait --timeout "${TIMEOUT_DEPLOYMENT}s"

  echo "=== Prometheus Agent installed on ${CLUSTER} ==="
  echo "    Mode: Agent (WAL buffer ~2h)"
  echo "    remote_write: ${REMOTE_WRITE_URL}"
  echo "    external_labels: cluster=${CLUSTER}"
done

echo ""
echo "=== Prometheus Agent installation complete on app clusters ==="
echo "NOTE: mgmt 클러스터의 Grafana에서 Thanos Query를 데이터소스로 추가하면"
echo "      전 클러스터 메트릭을 통합 조회할 수 있습니다."

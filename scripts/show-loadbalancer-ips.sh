#!/bin/bash
set -euo pipefail

# LoadBalancer IP 조회 스크립트

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/constants.sh"

# Setup
setup_common_vars

echo "========================================="
echo "LoadBalancer IPs (mgmt cluster)"
echo "========================================="
echo ""

# MinIO
echo "MinIO Object Storage:"
MINIO_IP=$($(get_kubectl_cmd mgmt) \
  get svc -n backup minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "NOT FOUND")
echo "  IP:      ${MINIO_IP}"
if [[ "${MINIO_IP}" != "NOT FOUND" ]]; then
  echo "  Console: http://${MINIO_IP}:9001"
  echo "  API:     http://${MINIO_IP}:9000"
fi
echo ""

# Vault
echo "Vault Secret Management:"
VAULT_IP=$($(get_kubectl_cmd mgmt) \
  get svc -n vault vault-ui-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "NOT FOUND")
echo "  IP:      ${VAULT_IP}"
if [[ "${VAULT_IP}" != "NOT FOUND" ]]; then
  echo "  UI/API:  http://${VAULT_IP}:8200"
fi
echo ""

# Thanos
echo "Thanos Metrics:"
THANOS_IP=$($(get_kubectl_cmd mgmt) \
  get svc -n observability thanos-receive -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "NOT FOUND")
echo "  IP:       ${THANOS_IP}"
if [[ "${THANOS_IP}" != "NOT FOUND" ]]; then
  echo "  Endpoint: http://${THANOS_IP}:19291/api/v1/receive"
fi
echo ""

# Loki
echo "Loki Logs:"
LOKI_IP=$($(get_kubectl_cmd mgmt) \
  get svc -n observability loki-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "NOT FOUND")
echo "  IP:       ${LOKI_IP}"
if [[ "${LOKI_IP}" != "NOT FOUND" ]]; then
  echo "  Endpoint: http://${LOKI_IP}:3100"
fi
echo ""

# Istio Gateway
echo "Istio Ingress Gateway:"
GATEWAY_IP=$($(get_kubectl_cmd mgmt) \
  get svc -n istio-system istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "NOT FOUND")
echo "  IP:    ${GATEWAY_IP}"
if [[ "${GATEWAY_IP}" != "NOT FOUND" ]]; then
  echo "  HTTP:  http://${GATEWAY_IP}:80"
  echo "  HTTPS: https://${GATEWAY_IP}:443"
fi
echo ""

echo "========================================="
echo ""
echo "To update /etc/hosts automatically:"
echo "  sudo bash scripts/update-hosts-mac.sh"
echo ""
echo "To access via port-forward:"
echo "  bash scripts/port-forward-all.sh"
echo ""

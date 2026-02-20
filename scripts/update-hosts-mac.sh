#!/bin/bash
set -euo pipefail

# Mac /etc/hosts 자동 업데이트 스크립트
# LoadBalancer IP를 조회하여 /etc/hosts에 자동 추가

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/constants.sh"

# Setup
setup_common_vars

echo "========================================="
echo "Mac /etc/hosts Auto-Update Script"
echo "========================================="
echo ""

# Root 권한 확인
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo)"
   echo "Usage: sudo bash scripts/update-hosts-mac.sh"
   exit 1
fi

# LoadBalancer IP 조회
echo "Querying LoadBalancer IPs from mgmt cluster..."
echo ""

# MinIO IP
MINIO_IP=$($(get_kubectl_cmd mgmt) \
  get svc -n backup minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

# Vault IP
VAULT_IP=$($(get_kubectl_cmd mgmt) \
  get svc -n vault vault-ui-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

# Thanos IP
THANOS_IP=$($(get_kubectl_cmd mgmt) \
  get svc -n observability thanos-receive -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

# Loki IP
LOKI_IP=$($(get_kubectl_cmd mgmt) \
  get svc -n observability loki-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

# Istio Gateway IP (mgmt)
GATEWAY_IP=$($(get_kubectl_cmd mgmt) \
  get svc -n istio-system istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

# 조회 결과 출력
echo "Found LoadBalancer IPs:"
echo "  MinIO:    ${MINIO_IP:-NOT FOUND}"
echo "  Vault:    ${VAULT_IP:-NOT FOUND}"
echo "  Thanos:   ${THANOS_IP:-NOT FOUND}"
echo "  Loki:     ${LOKI_IP:-NOT FOUND}"
echo "  Gateway:  ${GATEWAY_IP:-NOT FOUND}"
echo ""

# /etc/hosts 백업
HOSTS_FILE="/etc/hosts"
BACKUP_FILE="/etc/hosts.backup-$(date +%Y%m%d-%H%M%S)"

echo "Creating backup: ${BACKUP_FILE}"
cp "${HOSTS_FILE}" "${BACKUP_FILE}"

# 기존 Kubernetes 엔트리 제거
echo "Removing old Kubernetes entries..."
sed -i '' '/# Kubernetes Multi-Cluster Services/,/# ========================================$/d' "${HOSTS_FILE}"

# 새 엔트리 추가
echo "" >> "${HOSTS_FILE}"
echo "# ========================================" >> "${HOSTS_FILE}"
echo "# Kubernetes Multi-Cluster Services" >> "${HOSTS_FILE}"
echo "# Auto-generated on $(date)" >> "${HOSTS_FILE}"
echo "# ========================================" >> "${HOSTS_FILE}"

if [[ -n "${MINIO_IP}" ]]; then
  echo "" >> "${HOSTS_FILE}"
  echo "# MinIO Object Storage" >> "${HOSTS_FILE}"
  echo "${MINIO_IP}    minio.local" >> "${HOSTS_FILE}"
  echo "${MINIO_IP}    s3.local" >> "${HOSTS_FILE}"
  echo "${MINIO_IP}    minio-console.local" >> "${HOSTS_FILE}"
fi

if [[ -n "${VAULT_IP}" ]]; then
  echo "" >> "${HOSTS_FILE}"
  echo "# Vault Secret Management" >> "${HOSTS_FILE}"
  echo "${VAULT_IP}    vault.local" >> "${HOSTS_FILE}"
  echo "${VAULT_IP}    vault.mgmt.local" >> "${HOSTS_FILE}"
fi

if [[ -n "${THANOS_IP}" ]]; then
  echo "" >> "${HOSTS_FILE}"
  echo "# Thanos Metrics" >> "${HOSTS_FILE}"
  echo "${THANOS_IP}    thanos.local" >> "${HOSTS_FILE}"
  echo "${THANOS_IP}    thanos-receive.local" >> "${HOSTS_FILE}"
fi

if [[ -n "${LOKI_IP}" ]]; then
  echo "" >> "${HOSTS_FILE}"
  echo "# Loki Logs" >> "${HOSTS_FILE}"
  echo "${LOKI_IP}    loki.local" >> "${HOSTS_FILE}"
  echo "${LOKI_IP}    logs.local" >> "${HOSTS_FILE}"
fi

if [[ -n "${GATEWAY_IP}" ]]; then
  echo "" >> "${HOSTS_FILE}"
  echo "# Istio Gateway" >> "${HOSTS_FILE}"
  echo "${GATEWAY_IP}    gateway.local" >> "${HOSTS_FILE}"
  echo "${GATEWAY_IP}    api.local" >> "${HOSTS_FILE}"
fi

echo "# ========================================" >> "${HOSTS_FILE}"
echo "" >> "${HOSTS_FILE}"

# DNS 캐시 플러시
echo ""
echo "Flushing DNS cache..."
dscacheutil -flushcache
killall -HUP mDNSResponder 2>/dev/null || true

echo ""
echo "========================================="
echo "✅ /etc/hosts updated successfully!"
echo "========================================="
echo ""
echo "You can now access services:"
[[ -n "${MINIO_IP}" ]] && echo "  MinIO Console: http://minio.local:9001"
[[ -n "${VAULT_IP}" ]] && echo "  Vault:         http://vault.local:8200"
[[ -n "${THANOS_IP}" ]] && echo "  Thanos:        http://thanos.local:19291"
[[ -n "${LOKI_IP}" ]] && echo "  Loki:          http://loki.local:3100"
[[ -n "${GATEWAY_IP}" ]] && echo "  Gateway:       http://gateway.local"
echo ""
echo "Backup saved to: ${BACKUP_FILE}"
echo ""

#!/bin/bash
set -euo pipefail

# Automatically update Mac /etc/hosts with *.bocopile.io domains
# Usage: sudo bash scripts/update-hosts-bocopile.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"

if [[ ! -f "${KUBECONFIG_MULTI}" ]]; then
  echo "ERROR: kubeconfig-multi not found at ${GENERATED_DIR}"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (use sudo)"
  exit 1
fi

MGMT_CONTEXT="kubernetes-admin@mgmt"
KC_KUBECTL="--kubeconfig ${KUBECONFIG_MULTI} --context ${MGMT_CONTEXT}"

# Get Istio Ingress Gateway IP
INGRESS_IP=$(kubectl ${KC_KUBECTL} -n istio-system \
  get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

if [[ -z "${INGRESS_IP}" ]]; then
  echo "ERROR: Istio Ingress Gateway IP not found"
  echo "       Run 'bash scripts/apply-bocopile-gateway.sh' first"
  exit 1
fi

HOSTS_FILE="/etc/hosts"
BACKUP_FILE="/etc/hosts.backup.$(date +%Y%m%d_%H%M%S)"

# Backup current hosts file
cp "${HOSTS_FILE}" "${BACKUP_FILE}"
echo "Backed up /etc/hosts to ${BACKUP_FILE}"

# Remove old bocopile.io entries
sed -i.tmp '/bocopile\.io/d' "${HOSTS_FILE}"
rm -f "${HOSTS_FILE}.tmp"

# Define all domains
DOMAINS=(
  "grafana.bocopile.io"
  "prometheus.bocopile.io"
  "alertmanager.bocopile.io"
  "argocd.bocopile.io"
  "kiali.bocopile.io"
  "vault.bocopile.io"
  "minio.bocopile.io"
  "s3.bocopile.io"
  "tempo.bocopile.io"
  "thanos.bocopile.io"
  "opencost.bocopile.io"
  "goldilocks.bocopile.io"
  "chaos.bocopile.io"
)

# Add new entries
echo "" >> "${HOSTS_FILE}"
echo "# =============================================" >> "${HOSTS_FILE}"
echo "# Kubernetes bocopile.io domains (auto-generated)" >> "${HOSTS_FILE}"
echo "# Istio Ingress Gateway IP: ${INGRESS_IP}" >> "${HOSTS_FILE}"
echo "# Last updated: $(date)" >> "${HOSTS_FILE}"
echo "# =============================================" >> "${HOSTS_FILE}"

for domain in "${DOMAINS[@]}"; do
  echo "${INGRESS_IP}  ${domain}" >> "${HOSTS_FILE}"
done

echo "# =============================================" >> "${HOSTS_FILE}"
echo ""

echo "✅ Successfully updated /etc/hosts with ${#DOMAINS[@]} bocopile.io domains"
echo ""
echo "Added domains:"
for domain in "${DOMAINS[@]}"; do
  echo "  - http://${domain}"
done
echo ""
echo "Ingress IP: ${INGRESS_IP}"
echo ""
echo "Test access:"
echo "  curl -I http://grafana.bocopile.io"
echo "  open http://grafana.bocopile.io"
echo ""

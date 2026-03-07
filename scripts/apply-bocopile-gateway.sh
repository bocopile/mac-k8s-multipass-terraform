#!/bin/bash
set -euo pipefail

# Apply Istio Gateway and VirtualServices for *.bocopile.io domain
# Usage: bash scripts/apply-bocopile-gateway.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
TEMPLATES_DIR="${SCRIPT_DIR}/../templates"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"

if [[ ! -f "${KUBECONFIG_MULTI}" ]]; then
  echo "ERROR: kubeconfig-multi not found at ${GENERATED_DIR}"
  exit 1
fi

MGMT_CONTEXT="kubernetes-admin@mgmt"
KC_KUBECTL="--kubeconfig ${KUBECONFIG_MULTI} --context ${MGMT_CONTEXT}"

echo "=== Applying Istio Gateway for *.bocopile.io ==="

# Apply Gateway
echo "[1/2] Creating Gateway..."
kubectl ${KC_KUBECTL} apply -f "${TEMPLATES_DIR}/istio-gateway-bocopile.yaml"

# Apply VirtualServices
echo "[2/2] Creating VirtualServices..."
kubectl ${KC_KUBECTL} apply -f "${TEMPLATES_DIR}/virtualservices-bocopile.yaml"

# Get Istio Ingress Gateway IP
echo ""
echo "Waiting for Istio Ingress Gateway IP..."
INGRESS_IP=""
for i in $(seq 1 30); do
  INGRESS_IP=$(kubectl ${KC_KUBECTL} -n istio-system \
    get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "${INGRESS_IP}" ]]; then
    echo "${INGRESS_IP}" > "${GENERATED_DIR}/istio-ingress-ip"
    break
  fi
  echo "  Waiting... (${i}/30)"
  sleep 2
done

if [[ -z "${INGRESS_IP}" ]]; then
  echo "ERROR: Istio Ingress Gateway IP not assigned"
  echo "       Check MetalLB configuration"
  exit 1
fi

echo ""
echo "================================================================="
echo "  Istio Gateway Configuration Complete"
echo "================================================================="
echo "  Gateway:      bocopile-gateway (istio-system)"
echo "  Ingress IP:   ${INGRESS_IP}"
echo "  Domain:       *.bocopile.io"
echo "================================================================="
echo ""
echo "Services available at:"
echo "  http://grafana.bocopile.io       - Grafana Dashboard"
echo "  http://prometheus.bocopile.io    - Prometheus UI"
echo "  http://alertmanager.bocopile.io  - AlertManager UI"
echo "  http://argocd.bocopile.io        - ArgoCD Dashboard"
echo "  http://kiali.bocopile.io         - Kiali Service Mesh"
echo "  http://vault.bocopile.io         - Vault UI"
echo "  http://minio.bocopile.io         - MinIO Console"
echo "  http://s3.bocopile.io            - MinIO API (S3)"
echo "  http://tempo.bocopile.io         - Tempo API"
echo "  http://thanos.bocopile.io        - Thanos Query UI"
echo "================================================================="
echo ""
echo "Add to your Mac /etc/hosts:"
echo "  ${INGRESS_IP}  grafana.bocopile.io prometheus.bocopile.io alertmanager.bocopile.io"
echo "  ${INGRESS_IP}  argocd.bocopile.io kiali.bocopile.io vault.bocopile.io"
echo "  ${INGRESS_IP}  minio.bocopile.io s3.bocopile.io tempo.bocopile.io thanos.bocopile.io"
echo ""
echo "Or run: sudo bash scripts/update-hosts-bocopile.sh"
echo ""

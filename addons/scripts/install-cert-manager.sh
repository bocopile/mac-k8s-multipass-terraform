#!/bin/bash
set -euo pipefail

# Usage: install-cert-manager.sh [cert-manager-version]
# 전 클러스터에 cert-manager 설치 + Phase 1 Self-signed ClusterIssuer 생성

CERT_MANAGER_VERSION="${1:-v1.17.1}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../scripts/lib/constants.sh"

# Setup
setup_common_vars

# Helm repo 추가
add_helm_repo "jetstack" "${HELM_REPO_JETSTACK}"

CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  CONTEXT="kubernetes-admin@${CLUSTER}"

  log_info "Installing cert-manager ${CERT_MANAGER_VERSION} on ${CLUSTER}"

  # cert-manager 설치 (CRD 포함)
  $(get_helm_cmd "${CLUSTER}") upgrade --install cert-manager jetstack/cert-manager \
    --version "${CERT_MANAGER_VERSION}" \
    --namespace cert-manager --create-namespace \
    --set crds.enabled=true \
    --set prometheus.enabled=true \
    --set prometheus.servicemonitor.enabled=true \
    --wait --timeout "${TIMEOUT_DEPLOYMENT}s"

  wait_for_deployment "cert-manager" "cert-manager-webhook" "${TIMEOUT_POD_READY}" "${CONTEXT}"

  # Phase 1: Self-signed ClusterIssuer 생성 (ADR-004)
  log_info "Creating self-signed ClusterIssuer on ${CLUSTER}"
  $(get_kubectl_cmd "${CLUSTER}") apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-ca
spec:
  ca:
    secretName: selfsigned-ca-secret
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: selfsigned-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: "${CLUSTER}-ca"
  secretName: selfsigned-ca-secret
  duration: 8760h
  renewBefore: 720h
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
EOF

  echo "=== cert-manager installed on ${CLUSTER} (Phase 1: Self-signed) ==="
done

echo ""
echo "=== cert-manager installation complete ==="
echo "NOTE: Phase 2 (Vault Issuer) 전환은 Vault 설정 완료 후 별도 진행"

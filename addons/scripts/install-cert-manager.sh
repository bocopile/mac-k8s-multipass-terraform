#!/bin/bash
set -euo pipefail

# Usage: install-cert-manager.sh [cert-manager-version]
# 전 클러스터에 cert-manager 설치 + Phase 1 Self-signed ClusterIssuer 생성

CERT_MANAGER_VERSION="${1:-v1.17.1}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"
CLUSTERS_JSON="${GENERATED_DIR}/clusters.json"

if [[ ! -f "${CLUSTERS_JSON}" ]]; then
  echo "ERROR: clusters.json not found at ${CLUSTERS_JSON}"
  exit 1
fi

# Helm repo 추가
helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo update jetstack

CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  CONTEXT="kubernetes-admin@${CLUSTER}"

  echo "=== Installing cert-manager ${CERT_MANAGER_VERSION} on ${CLUSTER} ==="

  # cert-manager 설치 (CRD 포함)
  helm upgrade --install cert-manager jetstack/cert-manager \
    --version "${CERT_MANAGER_VERSION}" \
    --namespace cert-manager --create-namespace \
    --kubeconfig "${KUBECONFIG_MULTI}" \
    --kube-context "${CONTEXT}" \
    --set crds.enabled=true \
    --set prometheus.enabled=true \
    --set prometheus.servicemonitor.enabled=true \
    --wait --timeout 180s

  echo "Waiting for cert-manager webhook..."
  kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
    -n cert-manager wait deploy/cert-manager-webhook \
    --for=condition=available --timeout=120s

  # Phase 1: Self-signed ClusterIssuer 생성 (ADR-004)
  echo "Creating self-signed ClusterIssuer on ${CLUSTER}..."
  kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" apply -f - <<EOF
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

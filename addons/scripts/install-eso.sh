#!/bin/bash
set -euo pipefail

# Usage: install-eso.sh [eso-version]
# 전 클러스터에 External Secrets Operator 설치 + mgmt Vault SecretStore 생성

ESO_VERSION="${1:-0.14.3}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"
CLUSTERS_JSON="${GENERATED_DIR}/clusters.json"

if [[ ! -f "${CLUSTERS_JSON}" ]]; then
  echo "ERROR: clusters.json not found at ${CLUSTERS_JSON}"
  exit 1
fi

# Helm repo 추가
helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
helm repo update external-secrets

CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

# mgmt 클러스터의 Vault 서비스 주소 확인
MGMT_CONTEXT="kubernetes-admin@mgmt"
VAULT_ADDR=""

# Vault LoadBalancer IP 조회 시도
VAULT_LB_IP=$(kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${MGMT_CONTEXT}" \
  get svc vault -n vault -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

if [[ -n "${VAULT_LB_IP}" ]]; then
  VAULT_ADDR="http://${VAULT_LB_IP}:8200"
  echo "Vault LoadBalancer IP detected: ${VAULT_LB_IP}"
else
  # Fallback: mgmt worker 노드 IP + NodePort
  VAULT_ADDR="http://vault.vault.svc.cluster.local:8200"
  echo "WARN: Vault LoadBalancer IP not found. Using in-cluster address for mgmt."
  echo "      App 클러스터에서는 Cluster Mesh 또는 수동 설정이 필요할 수 있습니다."
fi

for CLUSTER in ${CLUSTERS}; do
  CONTEXT="kubernetes-admin@${CLUSTER}"

  echo "=== Installing External Secrets Operator on ${CLUSTER} ==="

  helm upgrade --install external-secrets external-secrets/external-secrets \
    --version "${ESO_VERSION}" \
    --namespace security --create-namespace \
    --kubeconfig "${KUBECONFIG_MULTI}" \
    --kube-context "${CONTEXT}" \
    --set installCRDs=true \
    --set prometheus.enabled=true \
    --set serviceMonitor.enabled=true \
    --wait --timeout 180s

  echo "Waiting for ESO webhook..."
  kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
    -n security wait deploy/external-secrets-webhook \
    --for=condition=available --timeout=120s

  # ClusterSecretStore 생성 (Vault 연동)
  # mgmt 클러스터는 in-cluster, app 클러스터는 LoadBalancer IP 사용
  if [[ "${CLUSTER}" == "mgmt" ]]; then
    STORE_VAULT_ADDR="http://vault.vault.svc.cluster.local:8200"
  else
    STORE_VAULT_ADDR="${VAULT_ADDR}"
  fi

  echo "Creating ClusterSecretStore on ${CLUSTER} (vault: ${STORE_VAULT_ADDR})..."
  kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "${STORE_VAULT_ADDR}"
      path: "secret"
      version: "v2"
      auth:
        tokenSecretRef:
          name: "vault-token"
          namespace: "external-secrets"
          key: "token"
  conditions:
    - type: Ready
  refreshInterval: 1h
EOF

  echo "=== ESO installed on ${CLUSTER} ==="
done

echo ""
echo "=== External Secrets Operator installation complete ==="
echo "NOTE: Vault 토큰 시크릿 생성이 필요합니다:"
echo "  kubectl create secret generic vault-token \\"
echo "    --from-literal=token=<vault-root-token> \\"
echo "    -n security --kubeconfig ~/kubeconfig-multi --context <context>"

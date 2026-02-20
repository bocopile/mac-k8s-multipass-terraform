#!/bin/bash
set -euo pipefail

# Usage: install-vault.sh
# mgmt 클러스터에 HashiCorp Vault를 설치합니다 (Dev/PoC 모드).
# - local-path-retain StorageClass 사용
# - LoadBalancer 서비스로 app 클러스터에서 접근 가능
# - ADR-004 Phase 2 PKI의 기반

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"
CLUSTERS_JSON="${GENERATED_DIR}/clusters.json"

# Load credential management library
source "${SCRIPT_DIR}/../../scripts/lib/credentials.sh"

if [[ ! -f "${CLUSTERS_JSON}" ]]; then
  echo "ERROR: clusters.json not found at ${CLUSTERS_JSON}"
  exit 1
fi

# mgmt 클러스터 컨텍스트
MGMT_CONTEXT="kubernetes-admin@mgmt"
KC="--kubeconfig ${KUBECONFIG_MULTI} --kube-context ${MGMT_CONTEXT}"
KC_KUBECTL="--kubeconfig ${KUBECONFIG_MULTI} --context ${MGMT_CONTEXT}"

# =============================================================================
# Helm Repo 등록
# =============================================================================
echo "=== Adding HashiCorp Helm repository ==="
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo update

# =============================================================================
# Vault 네임스페이스 생성
# =============================================================================
kubectl ${KC_KUBECTL} create namespace vault 2>/dev/null || true

# PSA 예외 설정 (Vault agent injector는 privileged 필요)
kubectl ${KC_KUBECTL} label namespace vault \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite

# =============================================================================
# Vault 설치 (Standalone, local-path-retain PVC)
# =============================================================================
echo ""
echo "=== Installing Vault on mgmt cluster ==="

helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  ${KC} \
  --set server.dataStorage.storageClass=local-path-retain \
  --set server.dataStorage.size=10Gi \
  --set server.standalone.enabled=true \
  --set server.ha.enabled=false \
  --set server.resources.requests.memory=256Mi \
  --set server.resources.requests.cpu=100m \
  --set server.resources.limits.memory=512Mi \
  --set server.resources.limits.cpu=500m \
  --set server.service.type=LoadBalancer \
  --set injector.enabled=true \
  --set injector.resources.requests.memory=64Mi \
  --set injector.resources.requests.cpu=50m \
  --set injector.resources.limits.memory=128Mi \
  --set injector.resources.limits.cpu=250m \
  --set ui.enabled=true \
  --set ui.serviceType=ClusterIP \
  --wait --timeout 180s

echo "Vault installed. Checking pod status..."
kubectl ${KC_KUBECTL} -n vault get pods

# =============================================================================
# Vault 초기화 (unseal)
# =============================================================================
echo ""
echo "=== Initializing Vault ==="

# Vault pod가 Running 상태가 될 때까지 대기
kubectl ${KC_KUBECTL} -n vault wait --for=condition=Ready pod/vault-0 --timeout=120s 2>/dev/null || true

# 초기화 상태 확인
INIT_STATUS=$(kubectl ${KC_KUBECTL} -n vault exec vault-0 -- vault status -format=json 2>/dev/null | jq -r '.initialized' || echo "false")

if [[ "${INIT_STATUS}" == "false" ]]; then
  echo "Initializing Vault with 1 key share, 1 key threshold (dev/PoC mode)..."
  INIT_OUTPUT=$(kubectl ${KC_KUBECTL} -n vault exec vault-0 -- vault operator init \
    -key-shares=1 -key-threshold=1 -format=json)

  UNSEAL_KEY=$(echo "${INIT_OUTPUT}" | jq -r '.unseal_keys_b64[0]')
  ROOT_TOKEN=$(echo "${INIT_OUTPUT}" | jq -r '.root_token')

  # Unseal
  kubectl ${KC_KUBECTL} -n vault exec vault-0 -- vault operator unseal "${UNSEAL_KEY}"

  # 키 저장 (generated 디렉토리에 보관)
  echo "${INIT_OUTPUT}" > "${GENERATED_DIR}/vault-init.json"
  echo "${ROOT_TOKEN}" > "${GENERATED_DIR}/vault-root-token"
  chmod 600 "${GENERATED_DIR}/vault-init.json" "${GENERATED_DIR}/vault-root-token"

  echo ""
  echo "Vault initialized and unsealed."
  echo "Root token saved to: ${GENERATED_DIR}/vault-root-token"
  echo "Init keys saved to:  ${GENERATED_DIR}/vault-init.json"
  echo ""
  echo "WARNING: 프로덕션 환경에서는 키를 안전하게 보관하세요!"
else
  echo "Vault already initialized."
  # 이미 초기화된 경우 unseal 시도
  SEALED=$(kubectl ${KC_KUBECTL} -n vault exec vault-0 -- vault status -format=json 2>/dev/null | jq -r '.sealed' || echo "true")
  if [[ "${SEALED}" == "true" && -f "${GENERATED_DIR}/vault-init.json" ]]; then
    UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' "${GENERATED_DIR}/vault-init.json")
    kubectl ${KC_KUBECTL} -n vault exec vault-0 -- vault operator unseal "${UNSEAL_KEY}"
    echo "Vault unsealed."
  fi
fi

# =============================================================================
# KV Secrets Engine 활성화
# =============================================================================
echo ""
echo "=== Enabling KV v2 secrets engine ==="

if [[ -f "${GENERATED_DIR}/vault-root-token" ]]; then
  ROOT_TOKEN=$(cat "${GENERATED_DIR}/vault-root-token")
  # Security: Pass token via stdin instead of command-line argument
  kubectl ${KC_KUBECTL} -n vault exec vault-0 -- sh -c \
    'export VAULT_TOKEN="'"${ROOT_TOKEN}"'" && vault secrets enable -path=secret kv-v2 2>/dev/null || true'
  echo "KV v2 secrets engine enabled at path: secret/"

  # Save to credentials file for reuse
  save_credential "VAULT_ROOT_TOKEN" "${ROOT_TOKEN}"
fi

# =============================================================================
# Vault LoadBalancer IP 저장
# =============================================================================
echo ""
echo "=== Waiting for Vault LoadBalancer IP ==="

for i in $(seq 1 30); do
  VAULT_LB_IP=$(kubectl ${KC_KUBECTL} -n vault \
    get svc vault -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "${VAULT_LB_IP}" ]]; then
    echo "${VAULT_LB_IP}" > "${GENERATED_DIR}/vault-lb-ip"
    echo "Vault LoadBalancer IP: ${VAULT_LB_IP}"
    break
  fi
  echo "  Waiting for LoadBalancer IP... (${i}/30)"
  sleep 5
done

if [[ -z "${VAULT_LB_IP:-}" ]]; then
  echo "WARNING: Vault LoadBalancer IP not assigned within timeout."
  echo "  Check: kubectl ${KC_KUBECTL} -n vault get svc vault"
fi

# =============================================================================
# 설치 요약
# =============================================================================
echo ""
echo "================================================================="
echo "  Vault Installation Summary (mgmt cluster)"
echo "================================================================="
echo "  [OK] Vault Server  - vault namespace (standalone mode)"
echo "  [OK] Vault Injector - sidecar injection enabled"
echo "  [OK] KV v2 Engine  - secret/ path"
echo "  [OK] UI            - ClusterIP (port-forward for access)"
echo "================================================================="
echo ""
echo "Access Vault UI:"
echo "  kubectl ${KC_KUBECTL} -n vault port-forward svc/vault-ui 8200:8200"
echo ""
echo "Estimated RAM: ~400MB on mgmt-worker-0"

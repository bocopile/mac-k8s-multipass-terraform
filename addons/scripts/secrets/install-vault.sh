#!/bin/bash
set -euo pipefail

# Usage: install-vault.sh
# mgmt 클러스터에 HashiCorp Vault를 설치합니다 (Dev/PoC 모드).
# - local-path-retain StorageClass 사용
# - LoadBalancer 서비스로 app 클러스터에서 접근 가능
# - ADR-004 Phase 2 PKI의 기반

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../../scripts/lib/constants.sh"
source "${SCRIPT_DIR}/../../../scripts/lib/credentials.sh"

# Setup
setup_common_vars

# =============================================================================
# Helm Repo 등록
# =============================================================================
add_helm_repo "hashicorp" "${HELM_REPO_HASHICORP}"

# =============================================================================
# Vault 네임스페이스 생성 (Privileged PSA)
# =============================================================================
ensure_namespace_privileged "${NAMESPACE_VAULT}" "mgmt"

# =============================================================================
# Vault 설치 (Standalone, local-path-retain PVC)
# =============================================================================
log_info "Installing Vault on mgmt cluster"

VAULT_VERSION="${1:-0.32.0}"

$(get_helm_cmd mgmt) upgrade --install vault hashicorp/vault \
  --version "${VAULT_VERSION}" \
  --namespace "${NAMESPACE_VAULT}" \
  --set server.dataStorage.storageClass="${STORAGE_CLASS_RETAIN}" \
  --set server.dataStorage.size="${STORAGE_SIZE_MEDIUM}" \
  --set server.standalone.enabled=true \
  --set server.ha.enabled=false \
  --set server.resources.requests.memory="${RESOURCES_LARGE_REQUESTS_MEMORY}" \
  --set server.resources.requests.cpu="${RESOURCES_MEDIUM_REQUESTS_CPU}" \
  --set server.resources.limits.memory="${RESOURCES_LARGE_LIMITS_MEMORY}" \
  --set server.resources.limits.cpu="${RESOURCES_MEDIUM_LIMITS_CPU}" \
  --set server.service.type=LoadBalancer \
  --set injector.enabled=true \
  --set injector.resources.requests.memory="${RESOURCES_SMALL_REQUESTS_MEMORY}" \
  --set injector.resources.requests.cpu="${RESOURCES_SMALL_REQUESTS_CPU}" \
  --set injector.resources.limits.memory="${RESOURCES_SMALL_LIMITS_MEMORY}" \
  --set injector.resources.limits.cpu="${RESOURCES_SMALL_LIMITS_CPU}" \
  --set server.priorityClassName=platform-critical \
  --set injector.priorityClassName=platform-critical \
  --set ui.enabled=true \
  --set ui.serviceType=ClusterIP \
  --wait --timeout "${TIMEOUT_DEPLOYMENT}s"

log_info "Vault installed. Checking pod status..."
$(get_kubectl_cmd mgmt) -n "${NAMESPACE_VAULT}" get pods

# =============================================================================
# Vault 초기화 (unseal)
# =============================================================================
echo ""
echo "=== Initializing Vault ==="

# Vault pod가 스케줄링 및 Running 상태가 될 때까지 대기
echo "Waiting for Vault pod to be scheduled..."
for i in $(seq 1 30); do
  POD_PHASE=$($(get_kubectl_cmd mgmt) -n "${NAMESPACE_VAULT}" get pod vault-0 -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [[ "${POD_PHASE}" == "Running" || "${POD_PHASE}" == "Pending" ]]; then
    POD_HOST=$($(get_kubectl_cmd mgmt) -n "${NAMESPACE_VAULT}" get pod vault-0 -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
    if [[ -n "${POD_HOST}" ]]; then
      echo "Vault pod scheduled on ${POD_HOST} (phase: ${POD_PHASE})"
      break
    fi
  fi
  echo "  Waiting for Vault pod scheduling... (${i}/30)"
  sleep 10
done

$(get_kubectl_cmd mgmt) -n "${NAMESPACE_VAULT}" wait --for=condition=Ready pod/vault-0 --timeout=180s 2>/dev/null \
  || log_warn "Vault pod not Ready within 180s (initialization may fail)"

# 초기화 상태 확인
INIT_STATUS=$($(get_kubectl_cmd mgmt) -n "${NAMESPACE_VAULT}" exec vault-0 -- vault status -format=json 2>/dev/null | jq -r '.initialized' || echo "false")

if [[ "${INIT_STATUS}" == "false" ]]; then
  echo "Initializing Vault with 1 key share, 1 key threshold (dev/PoC mode)..."
  INIT_OUTPUT=$($(get_kubectl_cmd mgmt) -n "${NAMESPACE_VAULT}" exec vault-0 -- vault operator init \
    -key-shares=1 -key-threshold=1 -format=json)

  UNSEAL_KEY=$(echo "${INIT_OUTPUT}" | jq -r '.unseal_keys_b64[0]')
  ROOT_TOKEN=$(echo "${INIT_OUTPUT}" | jq -r '.root_token')

  # Unseal
  $(get_kubectl_cmd mgmt) -n "${NAMESPACE_VAULT}" exec vault-0 -- vault operator unseal "${UNSEAL_KEY}"

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
  SEALED=$($(get_kubectl_cmd mgmt) -n "${NAMESPACE_VAULT}" exec vault-0 -- vault status -format=json 2>/dev/null | jq -r '.sealed' || echo "true")
  if [[ "${SEALED}" == "true" && -f "${GENERATED_DIR}/vault-init.json" ]]; then
    UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' "${GENERATED_DIR}/vault-init.json")
    $(get_kubectl_cmd mgmt) -n "${NAMESPACE_VAULT}" exec vault-0 -- vault operator unseal "${UNSEAL_KEY}"
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
  # Security: export token as env var inside the exec shell
  $(get_kubectl_cmd mgmt) -n "${NAMESPACE_VAULT}" exec -i vault-0 -- sh -c '
    export VAULT_TOKEN="'"${ROOT_TOKEN}"'"
    vault secrets enable -path=secret kv-v2 2>/dev/null || true
  '
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
  VAULT_LB_IP=$($(get_kubectl_cmd mgmt) -n "${NAMESPACE_VAULT}" \
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
  log_warn "Vault LoadBalancer IP not assigned within timeout."
  echo "  Check: $(get_kubectl_cmd mgmt) -n ${NAMESPACE_VAULT} get svc vault"
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
echo "  $(get_kubectl_cmd mgmt) -n ${NAMESPACE_VAULT} port-forward svc/vault-ui 8200:8200"
echo ""
echo "Estimated RAM: ~400MB on mgmt-worker-0"

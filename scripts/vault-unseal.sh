#!/bin/bash
set -euo pipefail

# Usage: bash scripts/vault-unseal.sh
# Vault 초기화(init) + unseal 실행
# - 최초 설치 후: init + unseal
# - Pod 재시작 후: unseal만

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"
VAULT_INIT_FILE="${GENERATED_DIR}/vault-init.json"
VAULT_TOKEN_FILE="${GENERATED_DIR}/vault-root-token"

if [[ ! -f "${KUBECONFIG_MULTI}" ]]; then
  echo "ERROR: kubeconfig-multi 파일을 찾을 수 없습니다."
  exit 1
fi

export KUBECONFIG="${KUBECONFIG_MULTI}"
CONTEXT="kubernetes-admin@mgmt"
NAMESPACE="vault"

# Vault Pod 대기
echo "=== Vault Pod 상태 확인 ==="
for i in $(seq 1 30); do
  POD_PHASE=$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" get pod vault-0 \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [[ "${POD_PHASE}" == "Running" ]]; then
    echo "Vault Pod Running"
    break
  fi
  echo "  대기 중... (${i}/30, phase: ${POD_PHASE:-unknown})"
  sleep 5
done

# Vault 상태 확인
# vault status는 sealed 상태일 때 exit code 2를 반환하므로 || true 처리
VAULT_STATUS=$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" exec vault-0 -- \
  vault status -format=json 2>/dev/null) || true

if [[ -z "${VAULT_STATUS}" ]]; then
  VAULT_STATUS='{"initialized":false,"sealed":true}'
fi

INITIALIZED=$(echo "${VAULT_STATUS}" | jq -r '.initialized')
SEALED=$(echo "${VAULT_STATUS}" | jq -r '.sealed')

if [[ "${INITIALIZED}" == "true" && "${SEALED}" == "false" ]]; then
  echo "Vault가 이미 초기화 및 unseal 상태입니다."
  kubectl --context "${CONTEXT}" -n "${NAMESPACE}" exec vault-0 -- vault status
  exit 0
fi

# 초기화되지 않은 경우: init + unseal
if [[ "${INITIALIZED}" == "false" ]]; then
  echo ""
  echo "=== Vault 초기화 (init) ==="
  echo "key-shares=1, key-threshold=1 (dev/PoC 모드)"

  INIT_OUTPUT=$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" exec vault-0 -- \
    vault operator init -key-shares=1 -key-threshold=1 -format=json)

  UNSEAL_KEY=$(echo "${INIT_OUTPUT}" | jq -r '.unseal_keys_b64[0]')
  ROOT_TOKEN=$(echo "${INIT_OUTPUT}" | jq -r '.root_token')

  # 키 저장
  echo "${INIT_OUTPUT}" > "${VAULT_INIT_FILE}"
  echo "${ROOT_TOKEN}" > "${VAULT_TOKEN_FILE}"
  chmod 600 "${VAULT_INIT_FILE}" "${VAULT_TOKEN_FILE}"

  echo "Root token 저장: ${VAULT_TOKEN_FILE}"
  echo "Init keys 저장: ${VAULT_INIT_FILE}"

  # Unseal
  echo ""
  echo "=== Vault unseal ==="
  kubectl --context "${CONTEXT}" -n "${NAMESPACE}" exec vault-0 -- \
    vault operator unseal "${UNSEAL_KEY}"

  # KV v2 secrets engine 활성화
  echo ""
  echo "=== KV v2 secrets engine 활성화 ==="
  kubectl --context "${CONTEXT}" -n "${NAMESPACE}" exec vault-0 -- \
    sh -c "export VAULT_TOKEN='${ROOT_TOKEN}' && vault secrets enable -path=secret kv-v2 2>/dev/null || true"
  echo "KV v2 활성화 완료 (path: secret/)"

else
  # 이미 초기화된 경우: unseal만
  echo ""
  echo "=== Vault unseal ==="

  if [[ ! -f "${VAULT_INIT_FILE}" ]]; then
    echo "ERROR: vault-init.json 파일을 찾을 수 없습니다: ${VAULT_INIT_FILE}"
    echo "  unseal key를 수동으로 입력하세요:"
    echo "    kubectl --context ${CONTEXT} -n ${NAMESPACE} exec -it vault-0 -- vault operator unseal"
    exit 1
  fi

  UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' "${VAULT_INIT_FILE}")
  kubectl --context "${CONTEXT}" -n "${NAMESPACE}" exec vault-0 -- \
    vault operator unseal "${UNSEAL_KEY}"
fi

echo ""
echo "=== Vault 최종 상태 ==="
kubectl --context "${CONTEXT}" -n "${NAMESPACE}" exec vault-0 -- vault status

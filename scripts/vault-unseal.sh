#!/bin/bash
set -euo pipefail

# Usage: bash scripts/vault-unseal.sh
# Vault Pod 재시작 후 수동 unseal 실행

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"
VAULT_INIT_FILE="${GENERATED_DIR}/vault-init.json"

if [[ ! -f "${KUBECONFIG_MULTI}" ]]; then
  echo "ERROR: kubeconfig-multi 파일을 찾을 수 없습니다."
  exit 1
fi

export KUBECONFIG="${KUBECONFIG_MULTI}"
CONTEXT="kubernetes-admin@mgmt"
NAMESPACE="vault"

# Vault 상태 확인
echo "=== Vault 상태 확인 ==="
SEALED=$(kubectl --context "${CONTEXT}" -n "${NAMESPACE}" exec vault-0 -- \
  vault status -format=json 2>/dev/null | jq -r '.sealed' || echo "unknown")

if [[ "${SEALED}" == "false" ]]; then
  echo "Vault가 이미 unseal 상태입니다."
  kubectl --context "${CONTEXT}" -n "${NAMESPACE}" exec vault-0 -- vault status
  exit 0
fi

# unseal key 파일 확인
if [[ ! -f "${VAULT_INIT_FILE}" ]]; then
  echo "ERROR: vault-init.json 파일을 찾을 수 없습니다: ${VAULT_INIT_FILE}"
  echo "  Vault를 처음 설치한 경우 addons/install.sh vault 를 실행하세요."
  exit 1
fi

# unseal 실행
echo "Vault unseal 실행 중..."
UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' "${VAULT_INIT_FILE}")
kubectl --context "${CONTEXT}" -n "${NAMESPACE}" exec vault-0 -- \
  vault operator unseal "${UNSEAL_KEY}"

echo ""
echo "=== Vault unseal 완료 ==="
kubectl --context "${CONTEXT}" -n "${NAMESPACE}" exec vault-0 -- vault status

#!/bin/bash
set -euo pipefail

# Usage: setup-vault-pki.sh
# Vault PKI Secrets Engine 설정 (Phase 2: Istio Gateway 인증서용)
# - PKI Engine 활성화
# - Root CA 생성
# - Istio Gateway용 Role 생성
# - cert-manager용 Kubernetes Auth 설정

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../scripts/lib/constants.sh"

# Setup
setup_common_vars

# Vault root token 확인
VAULT_ROOT_TOKEN=""
if [[ -f "${GENERATED_DIR}/vault-root-token" ]]; then
  VAULT_ROOT_TOKEN=$(cat "${GENERATED_DIR}/vault-root-token")
  if [[ -z "${VAULT_ROOT_TOKEN}" ]]; then
    echo "ERROR: Vault root token file is empty"
    exit 1
  fi
else
  echo "ERROR: Vault root token not found at ${GENERATED_DIR}/vault-root-token"
  echo "Please run scripts/install-vault.sh first"
  exit 1
fi

# Vault pod 상태 확인
echo "Checking Vault pod status..."
if ! $(get_kubectl_cmd mgmt) -n vault get pod vault-0 &>/dev/null; then
  echo "ERROR: Vault pod 'vault-0' not found"
  echo "Please ensure Vault is installed and running"
  exit 1
fi

echo "=== Setting up Vault PKI for Istio Gateway certificates ==="

# =============================================================================
# 1. PKI Secrets Engine 활성화
# =============================================================================
echo ""
echo "[1/5] Enabling PKI secrets engine..."

$(get_kubectl_cmd mgmt) -n vault exec vault-0 -- sh -c "
  VAULT_TOKEN=${VAULT_ROOT_TOKEN} vault secrets enable -path=pki pki 2>/dev/null || \
  echo 'PKI engine already enabled'
"

# Max lease TTL 설정 (1년)
$(get_kubectl_cmd mgmt) -n vault exec vault-0 -- sh -c "
  VAULT_TOKEN=${VAULT_ROOT_TOKEN} vault secrets tune -max-lease-ttl=8760h pki
"

# =============================================================================
# 2. Root CA 생성
# =============================================================================
echo ""
echo "[2/5] Generating Root CA..."

# Root CA가 이미 존재하는지 확인
CA_CERT=$($(get_kubectl_cmd mgmt) -n vault exec vault-0 -- sh -c "
  VAULT_TOKEN=${VAULT_ROOT_TOKEN} vault read -field=certificate pki/cert/ca 2>/dev/null || true
")

if [[ -z "${CA_CERT}" ]]; then
  echo "Creating new Root CA..."
  $(get_kubectl_cmd mgmt) -n vault exec vault-0 -- sh -c "
    VAULT_TOKEN=${VAULT_ROOT_TOKEN} vault write pki/root/generate/internal \
      common_name='K8s Multi-Cluster Root CA' \
      issuer_name='root-ca' \
      ttl=8760h
  "
else
  echo "Root CA already exists."
fi

# CRL 및 Issuing 인증서 엔드포인트 설정
$(get_kubectl_cmd mgmt) -n vault exec vault-0 -- sh -c "
  VAULT_TOKEN=${VAULT_ROOT_TOKEN} vault write pki/config/urls \
    issuing_certificates='http://vault.vault.svc.cluster.local:8200/v1/pki/ca' \
    crl_distribution_points='http://vault.vault.svc.cluster.local:8200/v1/pki/crl'
"

# =============================================================================
# 3. Istio Gateway용 PKI Role 생성
# =============================================================================
echo ""
echo "[3/5] Creating PKI role for Istio Gateway..."

# 사용할 도메인 설정 (여기서는 예시로 *.local, *.example.com 사용)
# 실제 사용할 도메인으로 변경 필요
ALLOWED_DOMAINS="*.local,*.example.com,*.cluster.local,localhost"

$(get_kubectl_cmd mgmt) -n vault exec vault-0 -- sh -c "
  VAULT_TOKEN=${VAULT_ROOT_TOKEN} vault write pki/roles/istio-gateway \
    allowed_domains='${ALLOWED_DOMAINS}' \
    allow_subdomains=true \
    allow_bare_domains=true \
    allow_glob_domains=true \
    allow_localhost=true \
    max_ttl=2160h \
    key_type=rsa \
    key_bits=2048 \
    require_cn=false
"

echo "PKI role 'istio-gateway' created with allowed domains: ${ALLOWED_DOMAINS}"

# =============================================================================
# 4. cert-manager용 Policy 생성
# =============================================================================
echo ""
echo "[4/5] Creating Vault policy for cert-manager..."

$(get_kubectl_cmd mgmt) -n vault exec vault-0 -- sh -c "
  VAULT_TOKEN=${VAULT_ROOT_TOKEN} vault policy write cert-manager-pki - <<EOF
# PKI 인증서 발급 권한
path \"pki/sign/istio-gateway\" {
  capabilities = [\"create\", \"update\"]
}

path \"pki/issue/istio-gateway\" {
  capabilities = [\"create\"]
}

# 인증서 조회 (선택적)
path \"pki/cert/*\" {
  capabilities = [\"read\"]
}
EOF
"

# =============================================================================
# 5. Kubernetes Auth 설정 (cert-manager용)
# =============================================================================
echo ""
echo "[5/5] Configuring Kubernetes auth for cert-manager..."

# Kubernetes Auth가 활성화되어 있는지 확인
AUTH_ENABLED=$($(get_kubectl_cmd mgmt) -n vault exec vault-0 -- sh -c "
  VAULT_TOKEN=${VAULT_ROOT_TOKEN} vault auth list -format=json 2>/dev/null | jq -r '.\"kubernetes/\"' || echo 'null'
")

if [[ "${AUTH_ENABLED}" == "null" ]]; then
  echo "Enabling Kubernetes auth..."
  $(get_kubectl_cmd mgmt) -n vault exec vault-0 -- sh -c "
    VAULT_TOKEN=${VAULT_ROOT_TOKEN} vault auth enable kubernetes
  "
fi

# Kubernetes API 서버 주소 설정
echo "Configuring Kubernetes auth..."
$(get_kubectl_cmd mgmt) -n vault exec vault-0 -- sh -c "
  VAULT_TOKEN=${VAULT_ROOT_TOKEN} vault write auth/kubernetes/config \
    kubernetes_host='https://kubernetes.default.svc:443'
"

# cert-manager용 Role 생성
$(get_kubectl_cmd mgmt) -n vault exec vault-0 -- sh -c "
  VAULT_TOKEN=${VAULT_ROOT_TOKEN} vault write auth/kubernetes/role/cert-manager \
    bound_service_account_names=cert-manager \
    bound_service_account_namespaces=cert-manager \
    policies=cert-manager-pki \
    ttl=1h
"

# =============================================================================
# CA 인증서 추출 (cert-manager Issuer에서 사용)
# =============================================================================
echo ""
echo "=== Extracting CA certificate for cert-manager ==="

CA_CERT_B64=$($(get_kubectl_cmd mgmt) -n vault exec vault-0 -- sh -c "
  VAULT_TOKEN=${VAULT_ROOT_TOKEN} vault read -field=certificate pki/cert/ca | base64 -w0
")

echo "${CA_CERT_B64}" > "${GENERATED_DIR}/vault-ca-cert.b64"
echo "CA certificate (base64) saved to: ${GENERATED_DIR}/vault-ca-cert.b64"

# =============================================================================
# 요약
# =============================================================================
echo ""
echo "================================================================="
echo "  Vault PKI Setup Complete"
echo "================================================================="
echo "  [OK] PKI secrets engine enabled at: pki/"
echo "  [OK] Root CA created: K8s Multi-Cluster Root CA"
echo "  [OK] PKI role created: istio-gateway"
echo "  [OK] Vault policy created: cert-manager-pki"
echo "  [OK] Kubernetes auth role: cert-manager"
echo "================================================================="
echo ""
echo "Next steps:"
echo "  1. Apply Vault Issuer: kubectl apply -f templates/vault-issuer.yaml"
echo "  2. Install Istio: bash scripts/install-istio.sh"
echo "  3. Apply Istio Gateway: kubectl apply -f templates/istio-gateway.yaml"
echo ""
echo "CA certificate for cert-manager Issuer:"
echo "  ${GENERATED_DIR}/vault-ca-cert.b64"

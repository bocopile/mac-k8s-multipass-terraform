#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/lib/common.sh"

# Setup (setup_common_vars는 kubeconfig-multi 존재를 요구하므로 직접 초기화)
validate_prerequisites

GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"
CLUSTERS_JSON="${GENERATED_DIR}/clusters.json"
require_file "${CLUSTERS_JSON}"

OUTPUT="${KUBECONFIG_MULTI}"

log_info "Merging kubeconfigs"

# clusters.json에서 클러스터 목록 읽기 (bash 3.2 호환)
CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")
KUBECONFIG_PATHS=""

for CLUSTER in ${CLUSTERS}; do
  SRC="${GENERATED_DIR}/kubeconfig-${CLUSTER}"

  require_file "${SRC}"

  # 원본 값 추출 (raw 모드로 인증서 데이터 유지)
  SERVER=$(kubectl --kubeconfig="${SRC}" config view --raw -o jsonpath='{.clusters[0].cluster.server}')
  CA_DATA=$(kubectl --kubeconfig="${SRC}" config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
  CLIENT_CERT=$(kubectl --kubeconfig="${SRC}" config view --raw -o jsonpath='{.users[0].user.client-certificate-data}')
  CLIENT_KEY=$(kubectl --kubeconfig="${SRC}" config view --raw -o jsonpath='{.users[0].user.client-key-data}')

  # 클러스터별 고유 이름으로 재설정 (cluster, user, context)
  kubectl --kubeconfig="${SRC}" config set-cluster "${CLUSTER}" --server="${SERVER}"
  kubectl --kubeconfig="${SRC}" config set "clusters.${CLUSTER}.certificate-authority-data" "${CA_DATA}"

  kubectl --kubeconfig="${SRC}" config set "users.kubernetes-admin@${CLUSTER}.client-certificate-data" "${CLIENT_CERT}"
  kubectl --kubeconfig="${SRC}" config set "users.kubernetes-admin@${CLUSTER}.client-key-data" "${CLIENT_KEY}"

  kubectl --kubeconfig="${SRC}" config set-context "kubernetes-admin@${CLUSTER}" \
    --cluster="${CLUSTER}" \
    --user="kubernetes-admin@${CLUSTER}"

  # 기존 default 엔트리 삭제 (병합 시 충돌 방지)
  kubectl --kubeconfig="${SRC}" config delete-cluster "kubernetes" 2>/dev/null || true
  kubectl --kubeconfig="${SRC}" config delete-user "kubernetes-admin" 2>/dev/null || true
  kubectl --kubeconfig="${SRC}" config delete-context "kubernetes-admin@kubernetes" 2>/dev/null || true

  kubectl --kubeconfig="${SRC}" config use-context "kubernetes-admin@${CLUSTER}"

  if [ -n "${KUBECONFIG_PATHS}" ]; then
    KUBECONFIG_PATHS="${KUBECONFIG_PATHS}:${SRC}"
  else
    KUBECONFIG_PATHS="${SRC}"
  fi
  log_info "Prepared kubeconfig for ${CLUSTER}"
done

# N개 kubeconfig 병합 (동적 경로)
log_info "Merging kubeconfigs..."
KUBECONFIG="${KUBECONFIG_PATHS}" kubectl config view --flatten > "${OUTPUT}"

# 기본 컨텍스트를 첫 번째 클러스터로 설정
FIRST_CLUSTER=$(jq -r 'keys[0]' "${CLUSTERS_JSON}")
kubectl --kubeconfig="${OUTPUT}" config use-context "kubernetes-admin@${FIRST_CLUSTER}"

# 홈 디렉토리에도 복사
cp "${OUTPUT}" ~/kubeconfig-multi

# ~/.kube/config에 병합 (기존 컨텍스트 보존)
KUBE_DIR="${HOME}/.kube"
KUBE_CONFIG="${KUBE_DIR}/config"
mkdir -p "${KUBE_DIR}"

if [[ -f "${KUBE_CONFIG}" ]]; then
  # 기존 config 백업 후 병합
  cp "${KUBE_CONFIG}" "${KUBE_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  KUBECONFIG="${KUBE_CONFIG}:${OUTPUT}" kubectl config view --flatten > "${KUBE_CONFIG}.merged"
  mv "${KUBE_CONFIG}.merged" "${KUBE_CONFIG}"
  log_info "Merged into ${KUBE_CONFIG} (backup: ${KUBE_CONFIG}.bak.*) ✓"
else
  cp "${OUTPUT}" "${KUBE_CONFIG}"
  log_info "Created ${KUBE_CONFIG} ✓"
fi
chmod 600 "${KUBE_CONFIG}"

log_info "Kubeconfig merged to ${OUTPUT} ✓"
log_info "Also copied to ~/kubeconfig-multi ✓"
echo ""
echo "Switch context: kubectl config use-context kubernetes-admin@<cluster>"

#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/lib/common.sh"

# Setup
setup_common_vars

OUTPUT="${GENERATED_DIR}/kubeconfig-multi"

log_info "Merging kubeconfigs"

# clusters.json에서 클러스터 목록 읽기
mapfile -t CLUSTERS < <(jq -r 'keys[]' "${CLUSTERS_JSON}")
KUBECONFIG_PATHS=()

for CLUSTER in "${CLUSTERS[@]}"; do
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

  KUBECONFIG_PATHS+=("${SRC}")
  log_info "Prepared kubeconfig for ${CLUSTER}"
done

# N개 kubeconfig 병합 (동적 경로)
log_info "Merging ${#CLUSTERS[@]} kubeconfigs..."
KUBECONFIG_MERGED=$(IFS=:; echo "${KUBECONFIG_PATHS[*]}")
export KUBECONFIG="${KUBECONFIG_MERGED}"
kubectl config view --flatten > "${OUTPUT}"
unset KUBECONFIG

# 기본 컨텍스트를 첫 번째 클러스터로 설정
FIRST_CLUSTER="${CLUSTERS[0]}"
kubectl --kubeconfig="${OUTPUT}" config use-context "kubernetes-admin@${FIRST_CLUSTER}"

# 홈 디렉토리에도 복사
cp "${OUTPUT}" ~/kubeconfig-multi

log_info "Kubeconfig merged to ${OUTPUT} ✓"
log_info "Also copied to ~/kubeconfig-multi ✓"
echo ""
echo "Usage: export KUBECONFIG=~/kubeconfig-multi"
echo "Switch context: kubectl config use-context kubernetes-admin@<cluster>"

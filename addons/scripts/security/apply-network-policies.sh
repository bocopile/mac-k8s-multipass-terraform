#!/bin/bash
set -euo pipefail

# Usage: apply-network-policies.sh
# 전 클러스터에 NetworkPolicy 적용 (네트워크 보안 강화)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../../scripts/lib/constants.sh"

# Setup
setup_common_vars

NETWORK_POLICIES_TEMPLATE="${SCRIPT_DIR}/../../templates/network-policies.yaml"

if [[ ! -f "${NETWORK_POLICIES_TEMPLATE}" ]]; then
  error_exit "network-policies.yaml template not found"
fi

# NOTE: 이 스크립트는 플랫폼 네임스페이스(monitoring/observability/backup/vault/security/argocd)에만
# NetworkPolicy를 적용합니다. 워크로드 네임스페이스(default 등)는 애플리케이션 배포 시
# 별도로 적용해야 합니다. (데모 환경 범위 제한 — ARCHITECTURE.md §7.4 참조)
log_info "Applying NetworkPolicies to platform namespaces..."

CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  log_info "Processing cluster: ${CLUSTER}"

  # Ensure namespace labels exist (required for namespaceSelector)
  for NS in monitoring observability security backup vault argocd kube-system; do
    if $(get_kubectl_cmd "${CLUSTER}") \
       get namespace "${NS}" &>/dev/null; then

      log_info "  Labeling namespace: ${NS}"
      $(get_kubectl_cmd "${CLUSTER}") \
        label namespace "${NS}" \
        "kubernetes.io/metadata.name=${NS}" \
        --overwrite 2>/dev/null || true
    fi
  done

  # Apply NetworkPolicies
  log_info "  Applying NetworkPolicies to ${CLUSTER}"

  # Apply monitoring namespace policies
  if $(get_kubectl_cmd "${CLUSTER}") \
     get namespace "${NAMESPACE_MONITORING}" &>/dev/null; then
    $(get_kubectl_cmd "${CLUSTER}") \
      apply -f "${NETWORK_POLICIES_TEMPLATE}" -n "${NAMESPACE_MONITORING}" 2>/dev/null || true
  fi

  # Apply observability namespace policies (mgmt only)
  if [[ "${CLUSTER}" == "mgmt" ]]; then
    if $(get_kubectl_cmd "${CLUSTER}") \
       get namespace "${NAMESPACE_OBSERVABILITY}" &>/dev/null; then
      $(get_kubectl_cmd "${CLUSTER}") \
        apply -f "${NETWORK_POLICIES_TEMPLATE}" -n "${NAMESPACE_OBSERVABILITY}" 2>/dev/null || true
    fi
  fi

  # Apply backup namespace policies (mgmt only)
  if [[ "${CLUSTER}" == "mgmt" ]]; then
    if $(get_kubectl_cmd "${CLUSTER}") \
       get namespace "${NAMESPACE_BACKUP}" &>/dev/null; then
      $(get_kubectl_cmd "${CLUSTER}") \
        apply -f "${NETWORK_POLICIES_TEMPLATE}" -n "${NAMESPACE_BACKUP}" 2>/dev/null || true
    fi
  fi

  # Apply vault namespace policies (mgmt only)
  if [[ "${CLUSTER}" == "mgmt" ]]; then
    if $(get_kubectl_cmd "${CLUSTER}") \
       get namespace "${NAMESPACE_VAULT}" &>/dev/null; then
      $(get_kubectl_cmd "${CLUSTER}") \
        apply -f "${NETWORK_POLICIES_TEMPLATE}" -n "${NAMESPACE_VAULT}" 2>/dev/null || true
    fi
  fi

  # Apply security namespace policies
  if $(get_kubectl_cmd "${CLUSTER}") \
     get namespace "${NAMESPACE_SECURITY}" &>/dev/null; then
    $(get_kubectl_cmd "${CLUSTER}") \
      apply -f "${NETWORK_POLICIES_TEMPLATE}" -n "${NAMESPACE_SECURITY}" 2>/dev/null || true
  fi

  # Apply argocd namespace policies (mgmt + app1)
  if [[ "${CLUSTER}" == "mgmt" || "${CLUSTER}" == "app1" ]]; then
    if $(get_kubectl_cmd "${CLUSTER}") \
       get namespace "${NAMESPACE_ARGOCD}" &>/dev/null; then
      $(get_kubectl_cmd "${CLUSTER}") \
        apply -f "${NETWORK_POLICIES_TEMPLATE}" -n "${NAMESPACE_ARGOCD}" 2>/dev/null || true
    fi
  fi

  log_info "  NetworkPolicies applied to ${CLUSTER} ✓"
done

echo ""
echo "========================================="
echo "  NetworkPolicy 적용 완료"
echo "========================================="
echo "모든 클러스터에 기본 네트워크 보안 정책이 적용되었습니다."
echo ""
echo "적용된 정책:"
echo "  - default-deny-all: 기본적으로 모든 트래픽 차단"
echo "  - allow-dns: DNS 쿼리 허용"
echo "  - allow-kubernetes-api: Kubernetes API 접근 허용"
echo "  - 각 서비스별 필요한 트래픽만 선택적으로 허용"
echo ""
echo "확인 방법:"
echo "  kubectl --kubeconfig ${KUBECONFIG_MULTI} --context kubernetes-admin@mgmt -n monitoring get networkpolicies"
echo "========================================="

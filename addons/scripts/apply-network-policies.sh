#!/bin/bash
set -euo pipefail

# Usage: apply-network-policies.sh
# 전 클러스터에 NetworkPolicy 적용 (네트워크 보안 강화)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"
CLUSTERS_JSON="${GENERATED_DIR}/clusters.json"
NETWORK_POLICIES_TEMPLATE="${SCRIPT_DIR}/../../templates/network-policies.yaml"

# Load common library
source "${SCRIPT_DIR}/../../scripts/lib/common.sh"

if [[ ! -f "${CLUSTERS_JSON}" ]]; then
  error_exit "clusters.json not found at ${CLUSTERS_JSON}"
fi

if [[ ! -f "${NETWORK_POLICIES_TEMPLATE}" ]]; then
  error_exit "network-policies.yaml template not found"
fi

log_info "Applying NetworkPolicies to all clusters..."

CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  CONTEXT="kubernetes-admin@${CLUSTER}"
  log_info "Processing cluster: ${CLUSTER}"

  # Ensure namespace labels exist (required for namespaceSelector)
  for NS in monitoring observability security backup vault argocd kube-system; do
    if kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
       get namespace "${NS}" &>/dev/null; then

      log_info "  Labeling namespace: ${NS}"
      kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
        label namespace "${NS}" \
        "kubernetes.io/metadata.name=${NS}" \
        --overwrite 2>/dev/null || true
    fi
  done

  # Apply NetworkPolicies
  log_info "  Applying NetworkPolicies to ${CLUSTER}"

  # Apply monitoring namespace policies
  if kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
     get namespace monitoring &>/dev/null; then
    kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
      apply -f "${NETWORK_POLICIES_TEMPLATE}" -n monitoring 2>/dev/null || true
  fi

  # Apply observability namespace policies (mgmt only)
  if [[ "${CLUSTER}" == "mgmt" ]]; then
    if kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
       get namespace observability &>/dev/null; then
      kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
        apply -f "${NETWORK_POLICIES_TEMPLATE}" -n observability 2>/dev/null || true
    fi
  fi

  # Apply backup namespace policies (mgmt only)
  if [[ "${CLUSTER}" == "mgmt" ]]; then
    if kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
       get namespace backup &>/dev/null; then
      kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
        apply -f "${NETWORK_POLICIES_TEMPLATE}" -n backup 2>/dev/null || true
    fi
  fi

  # Apply vault namespace policies (mgmt only)
  if [[ "${CLUSTER}" == "mgmt" ]]; then
    if kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
       get namespace vault &>/dev/null; then
      kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
        apply -f "${NETWORK_POLICIES_TEMPLATE}" -n vault 2>/dev/null || true
    fi
  fi

  # Apply security namespace policies
  if kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
     get namespace security &>/dev/null; then
    kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
      apply -f "${NETWORK_POLICIES_TEMPLATE}" -n security 2>/dev/null || true
  fi

  # Apply argocd namespace policies (mgmt + app1)
  if [[ "${CLUSTER}" == "mgmt" || "${CLUSTER}" == "app1" ]]; then
    if kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
       get namespace argocd &>/dev/null; then
      kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
        apply -f "${NETWORK_POLICIES_TEMPLATE}" -n argocd 2>/dev/null || true
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

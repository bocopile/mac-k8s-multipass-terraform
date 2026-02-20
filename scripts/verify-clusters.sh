#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"
CLUSTERS_JSON="${GENERATED_DIR}/clusters.json"

if [[ ! -f "${KUBECONFIG_MULTI}" ]]; then
  echo "ERROR: kubeconfig-multi not found at ${KUBECONFIG_MULTI}"
  echo "Run terraform apply first."
  exit 1
fi

if [[ ! -f "${CLUSTERS_JSON}" ]]; then
  echo "ERROR: clusters.json not found at ${CLUSTERS_JSON}"
  exit 1
fi

PASS=0
FAIL=0

check() {
  local desc="$1"
  shift
  echo -n "  [CHECK] ${desc}... "
  if "$@" &>/dev/null; then
    echo "OK"
    PASS=$((PASS + 1))
  else
    echo "FAIL"
    FAIL=$((FAIL + 1))
  fi
}

echo "========================================="
echo " Multi-Cluster Verification"
echo "========================================="

# VM 상태 확인
echo ""
echo "--- VM Status ---"
multipass list

# clusters.json에서 클러스터 목록 읽기
mapfile -t CLUSTERS < <(jq -r 'keys[]' "${CLUSTERS_JSON}")

# 각 클러스터 검증
for CLUSTER in "${CLUSTERS[@]}"; do
  CONTEXT="kubernetes-admin@${CLUSTER}"
  echo ""
  echo "--- Cluster: ${CLUSTER} ---"

  # Nodes ready 체크
  check "Nodes ready" bash -c \
    "kubectl --kubeconfig '${KUBECONFIG_MULTI}' --context '${CONTEXT}' get nodes -o jsonpath='{.items[*].status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"

  echo "  Nodes:"
  kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" get nodes -o wide 2>/dev/null || echo "    (failed)"

  # Cilium 상태
  if command -v cilium &>/dev/null; then
    check "Cilium healthy" cilium status \
      --context "${CONTEXT}" \
      --kubeconfig "${KUBECONFIG_MULTI}"
  fi

  # MetalLB 상태
  check "MetalLB running" bash -c \
    "kubectl --kubeconfig '${KUBECONFIG_MULTI}' --context '${CONTEXT}' -n metallb-system get deploy controller -o jsonpath='{.status.availableReplicas}' | grep -q 1"

  check "IPAddressPool exists" kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
    -n metallb-system get ipaddresspool "${CLUSTER}-pool"
done

# Cluster Mesh 상태
if command -v cilium &>/dev/null; then
  echo ""
  echo "--- Cluster Mesh Status ---"
  for CLUSTER in "${CLUSTERS[@]}"; do
    echo "  ${CLUSTER}:"
    cilium clustermesh status \
      --context "kubernetes-admin@${CLUSTER}" \
      --kubeconfig "${KUBECONFIG_MULTI}" 2>/dev/null || echo "    (not configured)"
  done
fi

echo ""
echo "========================================="
echo " Results: ${PASS} passed, ${FAIL} failed"
echo "========================================="

exit "${FAIL}"

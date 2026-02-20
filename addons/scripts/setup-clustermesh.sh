#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"
CLUSTERS_JSON="${GENERATED_DIR}/clusters.json"

if [[ ! -f "${CLUSTERS_JSON}" ]]; then
  echo "ERROR: clusters.json not found at ${CLUSTERS_JSON}"
  exit 1
fi

echo "=== Setting up Cilium Cluster Mesh ==="

# clusters.json에서 클러스터 목록 읽기
mapfile -t CLUSTERS < <(jq -r 'keys[]' "${CLUSTERS_JSON}")

# 각 클러스터에서 clustermesh enable
for CLUSTER in "${CLUSTERS[@]}"; do
  echo "Enabling Cluster Mesh on ${CLUSTER}..."
  cilium clustermesh enable --service-type NodePort \
    --context "kubernetes-admin@${CLUSTER}" \
    --kubeconfig "${KUBECONFIG_MULTI}"

  echo "Waiting for Cluster Mesh to be ready on ${CLUSTER}..."
  cilium clustermesh status --wait \
    --context "kubernetes-admin@${CLUSTER}" \
    --kubeconfig "${KUBECONFIG_MULTI}" || true
done

# Full Mesh 연결: 모든 클러스터 쌍
for ((i=0; i<${#CLUSTERS[@]}; i++)); do
  for ((j=i+1; j<${#CLUSTERS[@]}; j++)); do
    SRC="${CLUSTERS[$i]}"
    DST="${CLUSTERS[$j]}"
    echo "Connecting ${SRC} ↔ ${DST}..."
    cilium clustermesh connect \
      --context "kubernetes-admin@${SRC}" \
      --destination-context "kubernetes-admin@${DST}" \
      --kubeconfig "${KUBECONFIG_MULTI}"
  done
done

echo "Verifying Cluster Mesh status..."
for CLUSTER in "${CLUSTERS[@]}"; do
  echo "--- ${CLUSTER} ---"
  cilium clustermesh status \
    --context "kubernetes-admin@${CLUSTER}" \
    --kubeconfig "${KUBECONFIG_MULTI}"
done

echo "=== Cluster Mesh setup complete ==="

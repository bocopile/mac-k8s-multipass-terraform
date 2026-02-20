#!/bin/bash
set -euo pipefail

# Usage: cluster-join.sh <cluster-name> <cp-node> <worker-node> [<worker-node2> ...]
CLUSTER_NAME="${1:?Usage: cluster-join.sh <cluster-name> <cp-node> <worker-node> [...]}"
CP_NODE="${2:?Usage: cluster-join.sh <cluster-name> <cp-node> <worker-node> [...]}"
shift 2

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
JOIN_SCRIPT="${GENERATED_DIR}/join-${CLUSTER_NAME}.sh"

if [[ ! -f "${JOIN_SCRIPT}" ]]; then
  echo "ERROR: Join script not found: ${JOIN_SCRIPT}"
  exit 1
fi

for WORKER_NODE in "$@"; do
  echo "=== [${CLUSTER_NAME}] Joining ${WORKER_NODE} ==="

  # cloud-init 완료 대기 + 핵심 도구 검증
  echo "Waiting for cloud-init to finish on ${WORKER_NODE}..."
  multipass exec "${WORKER_NODE}" -- bash -c "cloud-init status --wait"
  echo "Verifying essential tools on ${WORKER_NODE}..."
  multipass exec "${WORKER_NODE}" -- bash -c "which kubeadm && which kubelet && systemctl is-active containerd"

  # join 스크립트 전송 및 실행
  multipass transfer "${JOIN_SCRIPT}" "${WORKER_NODE}":/home/ubuntu/join.sh
  multipass exec "${WORKER_NODE}" -- bash -c "chmod +x /home/ubuntu/join.sh && sudo bash /home/ubuntu/join.sh"

  echo "=== [${CLUSTER_NAME}] ${WORKER_NODE} joined ==="
done

# 노드 상태 확인
echo "=== [${CLUSTER_NAME}] Verifying nodes ==="
multipass exec "${CP_NODE}" -- kubectl get nodes -o wide

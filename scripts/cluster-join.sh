#!/bin/bash
set -euo pipefail

# Usage: cluster-join.sh <cluster-name> <cp-node> <worker-node> [<worker-node2> ...]
CLUSTER_NAME="${1:?Usage: cluster-join.sh <cluster-name> <cp-node> <worker-node> [...]}"
CP_NODE="${2:?Usage: cluster-join.sh <cluster-name> <cp-node> <worker-node> [...]}"
shift 2

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/lib/common.sh"

# Setup
GENERATED_DIR="${SCRIPT_DIR}/../generated"
JOIN_SCRIPT="${GENERATED_DIR}/join-${CLUSTER_NAME}.sh"

require_file "${JOIN_SCRIPT}"

for WORKER_NODE in "$@"; do
  log_info "[${CLUSTER_NAME}] Joining ${WORKER_NODE}"

  # Wait for node to be ready
  wait_for_node_ready "${WORKER_NODE}"

  # 이미 join된 노드는 스킵
  if multipass exec "${WORKER_NODE}" -- test -f /etc/kubernetes/kubelet.conf 2>/dev/null; then
    log_info "[${CLUSTER_NAME}] ${WORKER_NODE} already joined, skipping"
  else
    # join 스크립트 전송 및 실행
    multipass transfer "${JOIN_SCRIPT}" "${WORKER_NODE}":/home/ubuntu/join.sh
    multipass exec "${WORKER_NODE}" -- bash -c "chmod +x /home/ubuntu/join.sh && sudo bash /home/ubuntu/join.sh"
  fi

  log_info "[${CLUSTER_NAME}] ${WORKER_NODE} joined ✓"
done

# 노드 상태 확인
log_info "[${CLUSTER_NAME}] Verifying nodes"
multipass exec "${CP_NODE}" -- kubectl get nodes -o wide

#!/bin/bash
set -euo pipefail

# Usage: cluster-init.sh <cluster-name> <cp-node>
CLUSTER_NAME="${1:?Usage: cluster-init.sh <cluster-name> <cp-node>}"
CP_NODE="${2:?Usage: cluster-init.sh <cluster-name> <cp-node>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/lib/common.sh"

# Setup
GENERATED_DIR="${SCRIPT_DIR}/../generated"
mkdir -p "${GENERATED_DIR}"

log_info "[${CLUSTER_NAME}] Initializing cluster on ${CP_NODE}"

# Wait for node to be ready
wait_for_node_ready "${CP_NODE}"

# kubeadm init 실행
log_info "Running kubeadm init on ${CP_NODE}..."
if ! multipass exec "${CP_NODE}" -- sudo kubeadm init --config /home/ubuntu/kubeadm-config.yaml; then
  error_exit "kubeadm init failed on ${CP_NODE}. Check VM logs: multipass exec ${CP_NODE} -- sudo journalctl -u kubelet -n 50"
fi

# kubeconfig 설정
log_info "Setting up kubeconfig on ${CP_NODE}..."
multipass exec "${CP_NODE}" -- bash -c "\
  mkdir -p /home/ubuntu/.kube && \
  sudo cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config && \
  sudo chown ubuntu:ubuntu /home/ubuntu/.kube/config"

# kubeconfig 로컬로 전송
log_info "Transferring kubeconfig to local..."
multipass transfer "${CP_NODE}":/home/ubuntu/.kube/config "${GENERATED_DIR}/kubeconfig-${CLUSTER_NAME}"

# Worker join 명령 생성
log_info "Generating join command..."
if ! JOIN_CMD=$(multipass exec "${CP_NODE}" -- sudo kubeadm token create --print-join-command); then
  error_exit "Failed to generate join command on ${CP_NODE}"
fi

if [[ -z "${JOIN_CMD}" ]]; then
  error_exit "Join command is empty"
fi

echo "#!/bin/bash" > "${GENERATED_DIR}/join-${CLUSTER_NAME}.sh"
echo "sudo ${JOIN_CMD}" >> "${GENERATED_DIR}/join-${CLUSTER_NAME}.sh"
chmod +x "${GENERATED_DIR}/join-${CLUSTER_NAME}.sh"

log_info "[${CLUSTER_NAME}] Cluster initialized successfully ✓"

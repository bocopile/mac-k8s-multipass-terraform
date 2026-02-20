#!/bin/bash
set -euo pipefail

# Usage: cluster-init.sh <cluster-name> <cp-node>
CLUSTER_NAME="${1:?Usage: cluster-init.sh <cluster-name> <cp-node>}"
CP_NODE="${2:?Usage: cluster-init.sh <cluster-name> <cp-node>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"

echo "=== [${CLUSTER_NAME}] Initializing cluster on ${CP_NODE} ==="

# cloud-init 완료 대기 + 핵심 도구 검증
echo "Waiting for cloud-init to finish on ${CP_NODE}..."
multipass exec "${CP_NODE}" -- bash -c "cloud-init status --wait"
echo "Verifying essential tools on ${CP_NODE}..."
multipass exec "${CP_NODE}" -- bash -c "which kubeadm && which kubectl && which kubelet && systemctl is-active containerd"

# kubeadm init 실행
echo "Running kubeadm init on ${CP_NODE}..."
if ! multipass exec "${CP_NODE}" -- sudo kubeadm init --config /home/ubuntu/kubeadm-config.yaml; then
  echo "ERROR: kubeadm init failed on ${CP_NODE}"
  echo "Check VM logs: multipass exec ${CP_NODE} -- sudo journalctl -u kubelet -n 50"
  exit 1
fi

# kubeconfig 설정
echo "Setting up kubeconfig on ${CP_NODE}..."
multipass exec "${CP_NODE}" -- bash -c "\
  mkdir -p /home/ubuntu/.kube && \
  sudo cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config && \
  sudo chown ubuntu:ubuntu /home/ubuntu/.kube/config"

# kubeconfig 로컬로 전송
echo "Transferring kubeconfig to local..."
mkdir -p "${GENERATED_DIR}"
multipass transfer "${CP_NODE}":/home/ubuntu/.kube/config "${GENERATED_DIR}/kubeconfig-${CLUSTER_NAME}"

# Worker join 명령 생성
echo "Generating join command..."
if ! JOIN_CMD=$(multipass exec "${CP_NODE}" -- sudo kubeadm token create --print-join-command); then
  echo "ERROR: Failed to generate join command on ${CP_NODE}"
  exit 1
fi

if [[ -z "${JOIN_CMD}" ]]; then
  echo "ERROR: Join command is empty"
  exit 1
fi

echo "#!/bin/bash" > "${GENERATED_DIR}/join-${CLUSTER_NAME}.sh"
echo "sudo ${JOIN_CMD}" >> "${GENERATED_DIR}/join-${CLUSTER_NAME}.sh"
chmod +x "${GENERATED_DIR}/join-${CLUSTER_NAME}.sh"

echo "=== [${CLUSTER_NAME}] Cluster initialized successfully ==="

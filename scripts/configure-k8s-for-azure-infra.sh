#!/bin/bash
set -euo pipefail

# K8s 노드 → Azure Infra VM 연결 설정 스크립트
# Harbor/Nexus IP를 K8s 노드의 /etc/hosts + containerd 설정에 반영
#
# 실행 순서:
#   1. cd azure-infra && tofu apply  (Harbor/Nexus VM 생성)
#   2. tofu apply                    (K8s 클러스터 생성)
#   3. bash scripts/configure-k8s-for-azure-infra.sh  ← 이 스크립트

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
GENERATED_DIR="${ROOT_DIR}/generated"

source "${SCRIPT_DIR}/lib/constants.sh"

# =============================================================================
# generated/ 파일에서 IP 로드
# =============================================================================
if [[ ! -f "${GENERATED_DIR}/harbor-ip" ]]; then
  echo "ERROR: ${GENERATED_DIR}/harbor-ip not found."
  echo "  먼저 azure-infra/ 에서 tofu apply 를 실행하세요."
  exit 1
fi
if [[ ! -f "${GENERATED_DIR}/nexus-ip" ]]; then
  echo "ERROR: ${GENERATED_DIR}/nexus-ip not found."
  echo "  먼저 azure-infra/ 에서 tofu apply 를 실행하세요."
  exit 1
fi
if [[ ! -f "${GENERATED_DIR}/clusters.json" ]]; then
  echo "ERROR: ${GENERATED_DIR}/clusters.json not found."
  echo "  먼저 tofu apply 로 K8s 클러스터를 생성하세요."
  exit 1
fi

HARBOR_IP=$(cat "${GENERATED_DIR}/harbor-ip")
NEXUS_IP=$(cat "${GENERATED_DIR}/nexus-ip")

echo "========================================="
echo "K8s 노드 → Azure Infra 연결 설정"
echo "========================================="
echo ""
echo "  Harbor: ${HARBOR_IP} → harbor.${BASE_DOMAIN}"
echo "  Nexus:  ${NEXUS_IP}  → nexus.${BASE_DOMAIN}:8081"
echo ""

# =============================================================================
# 모든 K8s 노드에 설정 적용
# =============================================================================
ALL_NODES=$(jq -r '[.[].nodes[]] | .[]' "${GENERATED_DIR}/clusters.json" 2>/dev/null)

NODE_SETUP=$(mktemp /tmp/azure-infra-node-setup-XXXXXX.sh)
trap 'rm -f "${NODE_SETUP}"' EXIT
cat > "${NODE_SETUP}" << SETUP
#!/bin/bash
set -euo pipefail

HARBOR_IP="${HARBOR_IP}"
NEXUS_IP="${NEXUS_IP}"
BASE_DOMAIN="${BASE_DOMAIN}"

# /etc/hosts 업데이트
grep -q "harbor.\${BASE_DOMAIN}" /etc/hosts || \
  echo "\${HARBOR_IP}  harbor.\${BASE_DOMAIN}" >> /etc/hosts

grep -q "nexus.\${BASE_DOMAIN}" /etc/hosts || \
  echo "\${NEXUS_IP}  nexus.\${BASE_DOMAIN}" >> /etc/hosts

# containerd certs.d 설정 (Harbor insecure HTTP 레지스트리 허용)
mkdir -p /etc/containerd/certs.d/harbor.\${BASE_DOMAIN}
cat > /etc/containerd/certs.d/harbor.\${BASE_DOMAIN}/hosts.toml << 'TOML'
server = "http://harbor.${BASE_DOMAIN}"

[host."http://harbor.${BASE_DOMAIN}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify  = true
TOML

# containerd config_path 활성화 (아직 안 된 경우)
if ! grep -q 'config_path = "/etc/containerd/certs.d"' /etc/containerd/config.toml 2>/dev/null; then
  sed -i 's|config_path = ""|config_path = "/etc/containerd/certs.d"|' /etc/containerd/config.toml 2>/dev/null || true
fi

systemctl restart containerd
echo "  Configured: \$(hostname)"
SETUP

for node in ${ALL_NODES}; do
  echo "  → ${node} 설정 중..."
  multipass transfer "${NODE_SETUP}" "${node}:/tmp/azure-infra-node-setup.sh"
  multipass exec "${node}" -- sudo bash /tmp/azure-infra-node-setup.sh
done

echo ""
echo "========================================="
echo "완료! Mac /etc/hosts 업데이트:"
echo "  sudo bash scripts/update-hosts-mac.sh"
echo "========================================="

#!/bin/bash
set -euo pipefail

# Usage: install-falco.sh [falco-version]
# app 클러스터에만 Falco 설치 (런타임 보안 L5)

FALCO_VERSION="${1:-4.16.0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../scripts/lib/constants.sh"

# Setup
setup_common_vars

# Helm repo 추가
add_helm_repo "falcosecurity" "${HELM_REPO_FALCO}"

CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  # mgmt는 Tetragon만 사용 (리소스 절약)
  if [[ "${CLUSTER}" == "mgmt" ]]; then
    echo "=== Skipping mgmt cluster (Tetragon only) ==="
    continue
  fi

  echo "=== Installing Falco ${FALCO_VERSION} on ${CLUSTER} ==="

  ensure_namespace "${NAMESPACE_SECURITY}" "${CLUSTER}"

  # Falco 설치 (eBPF 드라이버 - 커널 모듈 대신 eBPF 사용)
  $(get_helm_cmd "${CLUSTER}") upgrade --install falco falcosecurity/falco \
    --version "${FALCO_VERSION}" \
    --namespace "${NAMESPACE_SECURITY}" \
    --set driver.kind=ebpf \
    --set tty=true \
    --set falco.grpc.enabled=true \
    --set falco.grpcOutput.enabled=true \
    --set falco.jsonOutput=true \
    --set falco.httpOutput.enabled=false \
    --set falcosidekick.enabled=true \
    --set falcosidekick.config.prometheus.enabled=true \
    --set serviceMonitor.enabled=true \
    --set resources.requests.cpu=200m \
    --set resources.requests.memory=256Mi \
    --set resources.limits.cpu=500m \
    --set resources.limits.memory=512Mi \
    --set priorityClassName=platform-normal \
    --wait --timeout "${TIMEOUT_DEPLOYMENT}s"

  # DaemonSet 준비 대기
  $(get_kubectl_cmd "${CLUSTER}") -n "${NAMESPACE_SECURITY}" rollout status daemonset/falco --timeout="${TIMEOUT_POD_READY}s" || true

  echo "=== Falco installed on ${CLUSTER} ==="
done

echo ""
echo "=== Falco installation complete on app clusters ==="
echo "Falco는 다음을 감지합니다:"
echo "  - 컨테이너 내 쉘 실행"
echo "  - 민감 파일 접근 (/etc/shadow, /etc/passwd)"
echo "  - 권한 상승 시도"
echo "  - 비정상 네트워크 활동"

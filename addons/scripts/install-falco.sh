#!/bin/bash
set -euo pipefail

# Usage: install-falco.sh [falco-version]
# app 클러스터에만 Falco 설치 (런타임 보안 L5)

FALCO_VERSION="${1:-4.16.0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"
CLUSTERS_JSON="${GENERATED_DIR}/clusters.json"

if [[ ! -f "${CLUSTERS_JSON}" ]]; then
  echo "ERROR: clusters.json not found at ${CLUSTERS_JSON}"
  exit 1
fi

# Helm repo 추가
helm repo add falcosecurity https://falcosecurity.github.io/charts 2>/dev/null || true
helm repo update falcosecurity

CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  # mgmt는 Tetragon만 사용 (리소스 절약)
  if [[ "${CLUSTER}" == "mgmt" ]]; then
    echo "=== Skipping mgmt cluster (Tetragon only) ==="
    continue
  fi

  CONTEXT="kubernetes-admin@${CLUSTER}"
  KC="--kubeconfig ${KUBECONFIG_MULTI} --kube-context ${CONTEXT}"
  KC_KUBECTL="--kubeconfig ${KUBECONFIG_MULTI} --context ${CONTEXT}"

  echo "=== Installing Falco ${FALCO_VERSION} on ${CLUSTER} ==="

  # Falco 설치 (eBPF 드라이버 - 커널 모듈 대신 eBPF 사용)
  helm upgrade --install falco falcosecurity/falco \
    --version "${FALCO_VERSION}" \
    --namespace security --create-namespace \
    ${KC} \
    --set driver.kind=ebpf \
    --set tty=true \
    --set falco.grpc.enabled=true \
    --set falco.grpcOutput.enabled=true \
    --set falco.jsonOutput=true \
    --set falco.httpOutput.enabled=false \
    --set falcosidekick.enabled=true \
    --set falcosidekick.config.prometheus.enabled=true \
    --set serviceMonitor.enabled=true \
    --wait --timeout 300s

  # DaemonSet 준비 대기
  kubectl ${KC_KUBECTL} -n security rollout status daemonset/falco --timeout=180s || true

  echo "=== Falco installed on ${CLUSTER} ==="
done

echo ""
echo "=== Falco installation complete on app clusters ==="
echo "Falco는 다음을 감지합니다:"
echo "  - 컨테이너 내 쉘 실행"
echo "  - 민감 파일 접근 (/etc/shadow, /etc/passwd)"
echo "  - 권한 상승 시도"
echo "  - 비정상 네트워크 활동"

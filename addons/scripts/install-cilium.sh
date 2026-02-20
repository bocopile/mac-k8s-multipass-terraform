#!/bin/bash
set -euo pipefail

# Usage: install-cilium.sh <cilium-version>
CILIUM_VERSION="${1:?Usage: install-cilium.sh <cilium-version>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"
CLUSTERS_JSON="${GENERATED_DIR}/clusters.json"

if [[ ! -f "${CLUSTERS_JSON}" ]]; then
  echo "ERROR: clusters.json not found at ${CLUSTERS_JSON}"
  exit 1
fi

# Cilium CLI 설치 확인
if ! command -v cilium &>/dev/null; then
  echo "Installing Cilium CLI..."

  if ! CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt); then
    echo "ERROR: Failed to fetch Cilium CLI version"
    exit 1
  fi

  CLI_ARCH="amd64"
  if [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then
    CLI_ARCH="arm64"
  fi

  if ! curl -L --fail --remote-name-all \
    "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-darwin-${CLI_ARCH}.tar.gz{,.sha256sum}"; then
    echo "ERROR: Failed to download Cilium CLI"
    exit 1
  fi

  if ! shasum -a 256 --check "cilium-darwin-${CLI_ARCH}.tar.gz.sha256sum"; then
    echo "ERROR: Cilium CLI checksum verification failed"
    rm -f "cilium-darwin-${CLI_ARCH}.tar.gz" "cilium-darwin-${CLI_ARCH}.tar.gz.sha256sum"
    exit 1
  fi

  sudo tar xzvfC "cilium-darwin-${CLI_ARCH}.tar.gz" /usr/local/bin
  rm -f "cilium-darwin-${CLI_ARCH}.tar.gz" "cilium-darwin-${CLI_ARCH}.tar.gz.sha256sum"
fi

# clusters.json에서 클러스터 목록 읽기
CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  CLUSTER_ID=$(jq -r ".\"${CLUSTER}\".id" "${CLUSTERS_JSON}")
  POD_CIDR=$(jq -r ".\"${CLUSTER}\".pod_cidr" "${CLUSTERS_JSON}")
  CONTEXT="kubernetes-admin@${CLUSTER}"

  echo "=== Installing Cilium on ${CLUSTER} (cluster-id=${CLUSTER_ID}, pod-cidr=${POD_CIDR}) ==="

  cilium install \
    --version "${CILIUM_VERSION}" \
    --set cluster.id="${CLUSTER_ID}" \
    --set cluster.name="${CLUSTER}" \
    --set routingMode=tunnel \
    --set tunnelProtocol=vxlan \
    --set hubble.enabled=true \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true \
    --set kubeProxyReplacement=true \
    --set "ipam.operator.clusterPoolIPv4PodCIDRList={${POD_CIDR}}" \
    --context "${CONTEXT}" \
    --kubeconfig "${KUBECONFIG_MULTI}"

  echo "Waiting for Cilium to be ready on ${CLUSTER}..."
  cilium status --wait \
    --context "${CONTEXT}" \
    --kubeconfig "${KUBECONFIG_MULTI}"

  echo "=== Cilium installed on ${CLUSTER} ==="
done

echo "=== Cilium installation complete on all clusters ==="

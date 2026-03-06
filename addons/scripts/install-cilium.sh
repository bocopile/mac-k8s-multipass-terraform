#!/bin/bash
set -euo pipefail

# Usage: install-cilium.sh [cilium-version]
# Version priority: $1 argument > $CILIUM_VERSION env var > default
CILIUM_VERSION="${1:-${CILIUM_VERSION:-1.19.0}}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../scripts/lib/constants.sh"

# Setup
setup_common_vars

# Cilium CLI 설치 확인
if ! command -v cilium &>/dev/null; then
  log_info "Installing Cilium CLI..."

  if ! CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt); then
    error_exit "Failed to fetch Cilium CLI version"
  fi

  CLI_ARCH="amd64"
  if [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then
    CLI_ARCH="arm64"
  fi

  if ! curl -L --fail --remote-name-all \
    "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-darwin-${CLI_ARCH}.tar.gz{,.sha256sum}"; then
    error_exit "Failed to download Cilium CLI"
  fi

  if ! shasum -a 256 --check "cilium-darwin-${CLI_ARCH}.tar.gz.sha256sum"; then
    rm -f "cilium-darwin-${CLI_ARCH}.tar.gz" "cilium-darwin-${CLI_ARCH}.tar.gz.sha256sum"
    error_exit "Cilium CLI checksum verification failed"
  fi

  # sudo 없이 설치 (homebrew bin 또는 /usr/local/bin 시도)
  INSTALL_DIR="/opt/homebrew/bin"
  if [[ ! -d "${INSTALL_DIR}" ]]; then
    INSTALL_DIR="/usr/local/bin"
  fi
  if [[ -w "${INSTALL_DIR}" ]]; then
    tar xzvfC "cilium-darwin-${CLI_ARCH}.tar.gz" "${INSTALL_DIR}"
  else
    sudo tar xzvfC "cilium-darwin-${CLI_ARCH}.tar.gz" "${INSTALL_DIR}"
  fi
  rm -f "cilium-darwin-${CLI_ARCH}.tar.gz" "cilium-darwin-${CLI_ARCH}.tar.gz.sha256sum"
fi

# clusters.json에서 클러스터 목록 읽기
CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  CLUSTER_ID=$(jq -r ".\"${CLUSTER}\".id" "${CLUSTERS_JSON}")
  POD_CIDR=$(jq -r ".\"${CLUSTER}\".pod_cidr" "${CLUSTERS_JSON}")
  CONTEXT="kubernetes-admin@${CLUSTER}"

  log_info "Installing Cilium on ${CLUSTER} (cluster-id=${CLUSTER_ID}, pod-cidr=${POD_CIDR})"

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
    --set priorityClassName=platform-critical \
    --set operator.priorityClassName=platform-critical \
    --context "${CONTEXT}" \
    --kubeconfig "${KUBECONFIG_MULTI}"

  echo "Waiting for Cilium to be ready on ${CLUSTER}..."
  cilium status --wait \
    --context "${CONTEXT}" \
    --kubeconfig "${KUBECONFIG_MULTI}"

  echo "=== Cilium installed on ${CLUSTER} ==="
done

echo "=== Cilium installation complete on all clusters ==="

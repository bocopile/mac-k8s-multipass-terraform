#!/bin/bash
# Common Shell Script Library
# Provides reusable functions for all installation scripts

set -euo pipefail

# Error handler
error_exit() {
  echo "ERROR: $*" >&2
  exit 1
}

# Info message
log_info() {
  echo "[INFO] $*"
}

# Warning message
log_warn() {
  echo "[WARN] $*" >&2
}

# Check if command exists
require_command() {
  local cmd="$1"
  if ! command -v "$cmd" &>/dev/null; then
    error_exit "Required command not found: $cmd"
  fi
}

# Check if file exists
require_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    error_exit "Required file not found: $file"
  fi
}

# Validate all required commands
validate_prerequisites() {
  log_info "Validating prerequisites..."

  local required_commands=("kubectl" "helm" "jq")
  for cmd in "${required_commands[@]}"; do
    require_command "$cmd"
  done

  log_info "All prerequisites validated ✓"
}

# Setup common variables
setup_common_vars() {
  validate_prerequisites

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  GENERATED_DIR="${SCRIPT_DIR}/../../generated"
  KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"
  CLUSTERS_JSON="${GENERATED_DIR}/clusters.json"

  require_file "${KUBECONFIG_MULTI}"
  require_file "${CLUSTERS_JSON}"
}

# Wait for deployment to be ready
wait_for_deployment() {
  local namespace="$1"
  local deployment="$2"
  local timeout="${3:-180}"
  local context="${4:-kubernetes-admin@mgmt}"

  log_info "Waiting for deployment ${namespace}/${deployment}..."

  kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${context}" \
    -n "${namespace}" wait --for=condition=available \
    --timeout="${timeout}s" "deployment/${deployment}" || {
    log_warn "Deployment ${deployment} not ready within ${timeout}s"
    return 1
  }

  log_info "Deployment ${namespace}/${deployment} is ready ✓"
}

# Wait for statefulset to be ready
wait_for_statefulset() {
  local namespace="$1"
  local statefulset="$2"
  local timeout="${3:-180}"
  local context="${4:-kubernetes-admin@mgmt}"

  log_info "Waiting for statefulset ${namespace}/${statefulset}..."

  kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${context}" \
    -n "${namespace}" wait --for=jsonpath='{.status.readyReplicas}'=1 \
    --timeout="${timeout}s" "statefulset/${statefulset}" || {
    log_warn "StatefulSet ${statefulset} not ready within ${timeout}s"
    return 1
  }

  log_info "StatefulSet ${namespace}/${statefulset} is ready ✓"
}

# Add Helm repo
add_helm_repo() {
  local name="$1"
  local url="$2"

  log_info "Adding Helm repository: ${name}"
  helm repo add "${name}" "${url}" 2>/dev/null || true
  helm repo update "${name}"
}

# Wait for LoadBalancer IP
wait_for_lb_ip() {
  local namespace="$1"
  local service="$2"
  local timeout="${3:-30}"
  local context="${4:-kubernetes-admin@mgmt}"

  echo "[INFO] Waiting for LoadBalancer IP: ${namespace}/${service}" >&2

  local ip=""
  for i in $(seq 1 "$timeout"); do
    ip=$(kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${context}" \
      -n "${namespace}" get svc "${service}" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi

    echo "[INFO] Waiting for IP... (${i}/${timeout})" >&2
    sleep 2
  done

  log_warn "LoadBalancer IP not assigned after ${timeout} attempts"
  return 1
}

# Get kubectl command with context
get_kubectl_cmd() {
  local cluster="${1:-mgmt}"
  echo "kubectl --kubeconfig ${KUBECONFIG_MULTI} --context kubernetes-admin@${cluster}"
}

# Get helm command with context
get_helm_cmd() {
  local cluster="${1:-mgmt}"
  echo "helm --kubeconfig ${KUBECONFIG_MULTI} --kube-context kubernetes-admin@${cluster}"
}

# Ensure namespace exists
ensure_namespace() {
  local namespace="$1"
  local cluster="${2:-mgmt}"
  local context="kubernetes-admin@${cluster}"

  log_info "Ensuring namespace exists: ${namespace}"
  kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${context}" \
    create namespace "${namespace}" 2>/dev/null || true

  # 자동으로 privileged PSA 적용 (필요한 namespace)
  if is_privileged_namespace "${namespace}"; then
    kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${context}" \
      label namespace "${namespace}" \
      pod-security.kubernetes.io/enforce=privileged \
      pod-security.kubernetes.io/audit=privileged \
      pod-security.kubernetes.io/warn=privileged \
      --overwrite 2>/dev/null || true
  fi
}

# Ensure namespace exists with privileged PSA
ensure_namespace_privileged() {
  local namespace="$1"
  local cluster="${2:-mgmt}"
  local context="kubernetes-admin@${cluster}"

  ensure_namespace "${namespace}" "${cluster}"

  log_info "Setting privileged PSA for namespace: ${namespace}"
  kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${context}" \
    label namespace "${namespace}" \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged \
    --overwrite 2>/dev/null || true
}

# Wait for cloud-init and verify node readiness
wait_for_node_ready() {
  local node_name="$1"
  local max_retries=30
  local retry_interval=10

  # VM SSH 연결 가능할 때까지 대기
  log_info "Waiting for VM ${node_name} to become reachable..."
  local attempt=0
  while ! multipass exec "${node_name}" -- true 2>/dev/null; do
    attempt=$((attempt + 1))
    if [[ ${attempt} -ge ${max_retries} ]]; then
      error_exit "VM ${node_name} not reachable after $((max_retries * retry_interval))s"
    fi
    log_info "VM ${node_name} not ready yet, retrying... (${attempt}/${max_retries})"
    sleep ${retry_interval}
  done
  log_info "VM ${node_name} is reachable (after ${attempt} retries)"

  log_info "Waiting for cloud-init to complete on ${node_name}..."
  multipass exec "${node_name}" -- bash -c "cloud-init status --wait"

  log_info "Verifying Kubernetes components on ${node_name}..."
  multipass exec "${node_name}" -- bash -c \
    "which kubeadm && which kubectl && which kubelet && systemctl is-active containerd"

  log_info "Node ${node_name} is ready ✓"
}

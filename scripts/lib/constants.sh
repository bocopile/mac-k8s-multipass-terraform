#!/bin/bash
# Constants and Configuration Values
# Provides centralized configuration for all scripts

# =============================================================================
# Namespace Constants
# =============================================================================
readonly NAMESPACE_KUBE_SYSTEM="kube-system"
readonly NAMESPACE_CILIUM="cilium-system"
readonly NAMESPACE_MONITORING="monitoring"
readonly NAMESPACE_OBSERVABILITY="observability"
readonly NAMESPACE_SECURITY="security"
readonly NAMESPACE_BACKUP="backup"
readonly NAMESPACE_VAULT="vault"
readonly NAMESPACE_ARGOCD="argocd"
readonly NAMESPACE_ISTIO="istio-system"

# =============================================================================
# Timeout Values (seconds)
# =============================================================================
readonly TIMEOUT_DEPLOYMENT=180
readonly TIMEOUT_STATEFULSET=180
readonly TIMEOUT_LB_IP=120
readonly TIMEOUT_POD_READY=120
readonly TIMEOUT_HELM_INSTALL=300

# =============================================================================
# Helm Repository URLs
# =============================================================================
readonly HELM_REPO_BITNAMI="https://charts.bitnami.com/bitnami"
readonly HELM_REPO_PROMETHEUS="https://prometheus-community.github.io/helm-charts"
readonly HELM_REPO_GRAFANA="https://grafana.github.io/helm-charts"
readonly HELM_REPO_VMWARE_TANZU="https://vmware-tanzu.github.io/helm-charts"
readonly HELM_REPO_HASHICORP="https://helm.releases.hashicorp.com"
readonly HELM_REPO_JETSTACK="https://charts.jetstack.io"
readonly HELM_REPO_CILIUM="https://helm.cilium.io/"
readonly HELM_REPO_METALLB="https://metallb.github.io/metallb"
readonly HELM_REPO_KYVERNO="https://kyverno.github.io/kyverno/"
readonly HELM_REPO_FALCO="https://falcosecurity.github.io/charts"
readonly HELM_REPO_ARGO="https://argoproj.github.io/argo-helm"
readonly HELM_REPO_ISTIO="https://istio-release.storage.googleapis.com/charts"
readonly HELM_REPO_KIALI="https://kiali.org/helm-charts"
readonly HELM_REPO_OPENTELEMETRY="https://open-telemetry.github.io/opentelemetry-helm-charts"
readonly HELM_REPO_K8SGPT="https://charts.k8sgpt.ai/"
readonly HELM_REPO_ROBUSTA="https://robusta-charts.storage.googleapis.com"
readonly HELM_REPO_BOTKUBE="https://charts.botkube.io"
readonly HELM_REPO_EXTERNAL_SECRETS="https://charts.external-secrets.io"
readonly HELM_REPO_PROMETHEUS_COMMUNITY="${HELM_REPO_PROMETHEUS}"

# =============================================================================
# Registry & Artifact Repository Constants
# Harbor: 컨테이너 이미지 레지스트리 (harbor-vm, HTTP 포트 80)
# Nexus:  라이브러리 저장소 Maven/npm/raw (nexus-vm, HTTP 포트 8081)
# =============================================================================
readonly HARBOR_REGISTRY="harbor.bocopile.io"
readonly NEXUS_URL="nexus.bocopile.io:8081"
readonly NEXUS_MAVEN_URL="http://${NEXUS_URL}/repository/maven-public"
readonly NEXUS_NPM_URL="http://${NEXUS_URL}/repository/npm-proxy"

# =============================================================================
# Domain Constants
# =============================================================================
readonly BASE_DOMAIN="bocopile.io"
readonly DOMAIN_GRAFANA="grafana.${BASE_DOMAIN}"
readonly DOMAIN_PROMETHEUS="prometheus.${BASE_DOMAIN}"
readonly DOMAIN_ALERTMANAGER="alertmanager.${BASE_DOMAIN}"
readonly DOMAIN_ARGOCD="argocd.${BASE_DOMAIN}"
readonly DOMAIN_VAULT="vault.${BASE_DOMAIN}"
readonly DOMAIN_LOKI="loki.${BASE_DOMAIN}"
readonly DOMAIN_TEMPO="tempo.${BASE_DOMAIN}"
readonly DOMAIN_KIALI="kiali.${BASE_DOMAIN}"
readonly DOMAIN_JAEGER="jaeger.${BASE_DOMAIN}"
readonly DOMAIN_MINIO="minio.${BASE_DOMAIN}"
readonly DOMAIN_HARBOR="harbor.${BASE_DOMAIN}"
readonly DOMAIN_NEXUS="nexus.${BASE_DOMAIN}"

# =============================================================================
# Resource Defaults (for demo environment)
# =============================================================================
# Small workload defaults
readonly RESOURCES_SMALL_REQUESTS_MEMORY="64Mi"
readonly RESOURCES_SMALL_REQUESTS_CPU="50m"
readonly RESOURCES_SMALL_LIMITS_MEMORY="128Mi"
readonly RESOURCES_SMALL_LIMITS_CPU="250m"

# Medium workload defaults
readonly RESOURCES_MEDIUM_REQUESTS_MEMORY="128Mi"
readonly RESOURCES_MEDIUM_REQUESTS_CPU="100m"
readonly RESOURCES_MEDIUM_LIMITS_MEMORY="256Mi"
readonly RESOURCES_MEDIUM_LIMITS_CPU="500m"

# Large workload defaults
readonly RESOURCES_LARGE_REQUESTS_MEMORY="256Mi"
readonly RESOURCES_LARGE_REQUESTS_CPU="100m"
readonly RESOURCES_LARGE_LIMITS_MEMORY="512Mi"
readonly RESOURCES_LARGE_LIMITS_CPU="500m"

# =============================================================================
# Storage Defaults
# =============================================================================
readonly STORAGE_CLASS_DEFAULT="local-path"
readonly STORAGE_CLASS_RETAIN="local-path-retain"

# Storage sizes (demo environment)
readonly STORAGE_SIZE_SMALL="5Gi"
readonly STORAGE_SIZE_MEDIUM="10Gi"
readonly STORAGE_SIZE_LARGE="20Gi"

# =============================================================================
# Cluster Roles
# =============================================================================
readonly ROLE_CONTROL_PLANE="control-plane"
readonly ROLE_WORKER="worker"

# =============================================================================
# Helper Functions
# =============================================================================

# Get all namespaces as array
get_platform_namespaces() {
  echo "${NAMESPACE_MONITORING} ${NAMESPACE_OBSERVABILITY} ${NAMESPACE_SECURITY} ${NAMESPACE_BACKUP} ${NAMESPACE_VAULT} ${NAMESPACE_ARGOCD}"
}

# Get mgmt-only namespaces
get_mgmt_namespaces() {
  echo "${NAMESPACE_OBSERVABILITY} ${NAMESPACE_BACKUP} ${NAMESPACE_VAULT}"
}

# =============================================================================
# Default Tool Versions
# Referenced by: addons/scripts/install-cilium.sh, addons/scripts/install-metallb.sh
# =============================================================================
readonly CILIUM_VERSION_DEFAULT="1.19.0"
readonly METALLB_VERSION_DEFAULT="0.15.3"

# Check if namespace should be privileged
is_privileged_namespace() {
  local namespace="$1"
  case "${namespace}" in
    "${NAMESPACE_KUBE_SYSTEM}"|"${NAMESPACE_CILIUM}"|"${NAMESPACE_MONITORING}"|"${NAMESPACE_VAULT}"|\
    "${NAMESPACE_BACKUP}"|"${NAMESPACE_SECURITY}"|"local-path-storage")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

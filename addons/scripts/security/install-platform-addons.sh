#!/bin/bash
set -euo pipefail

# Usage: install-platform-addons.sh
# mgmt 클러스터에 플랫폼 부가 도구를 설치합니다:
#   - Trivy Operator (이미지/K8s 취약점 스캔)
#   - K8sGPT Operator (AI 클러스터 진단)
#   - OpenCost (리소스 비용 가시화)
#   - VPA + Goldilocks (리소스 추천)
#   - Chaos Mesh (장애 주입 테스트)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../../scripts/lib/constants.sh"

# Setup
setup_common_vars

# =============================================================================
# 0. local-path-retain StorageClass 생성 (§6.2)
# =============================================================================
echo "=== Creating local-path-retain StorageClass on mgmt ==="
$(get_kubectl_cmd mgmt) apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path-retain
provisioner: rancher.io/local-path
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
EOF

# =============================================================================
# Helm Repo 등록
# =============================================================================
echo "=== Adding Helm repositories ==="
helm repo add aquasecurity https://aquasecurity.github.io/helm-charts 2>/dev/null || true
helm repo add k8sgpt https://charts.k8sgpt.ai 2>/dev/null || true
helm repo add opencost https://opencost.github.io/opencost-helm-chart 2>/dev/null || true
helm repo add fairwinds-stable https://charts.fairwinds.com/stable 2>/dev/null || true
helm repo add chaos-mesh https://charts.chaos-mesh.org 2>/dev/null || true
helm repo update

# =============================================================================
# 1. Trivy Operator (~200MB)
# =============================================================================
echo ""
echo "=== [1/5] Installing Trivy Operator ==="

helm upgrade --install trivy-operator aquasecurity/trivy-operator \
  --namespace trivy-system --create-namespace \
  --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "kubernetes-admin@mgmt" \
  --set trivy.ignoreUnfixed=true \
  --set operator.scanJobsConcurrentLimit=2 \
  --set operator.metricsVulnIdEnabled=true \
  --set serviceMonitor.enabled=false \
  --set priorityClassName=platform-normal \
  --wait --timeout 180s

echo "Trivy Operator installed. VulnerabilityReports:"
$(get_kubectl_cmd mgmt) -n trivy-system get deploy trivy-operator -o wide

# =============================================================================
# 2. K8sGPT Operator (~128MB)
# =============================================================================
echo ""
echo "=== [2/5] Installing K8sGPT Operator ==="

helm upgrade --install k8sgpt-operator k8sgpt/k8sgpt-operator \
  --namespace k8sgpt --create-namespace \
  --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "kubernetes-admin@mgmt" \
  --set serviceMonitor.enabled=false \
  --set priorityClassName=platform-normal \
  --wait --timeout 120s

echo "K8sGPT Operator installed."
echo "NOTE: K8sGPT CR을 생성하여 AI 백엔드를 설정하세요."
echo "  예시: kubectl apply -f - <<EOF"
echo "  apiVersion: core.k8sgpt.ai/v1alpha1"
echo "  kind: K8sGPT"
echo "  metadata:"
echo "    name: k8sgpt"
echo "    namespace: k8sgpt"
echo "  spec:"
echo "    ai:"
echo "      backend: openai"
echo "      model: gpt-4"
echo "      secret:"
echo "        name: k8sgpt-secret"
echo "        key: openai-api-key"
echo "    noCache: false"
echo "  EOF"

# =============================================================================
# 3. OpenCost (~100MB)
# =============================================================================
echo ""
echo "=== [3/5] Installing OpenCost ==="

# Prometheus 엔드포인트 (기존 kube-prometheus-stack 연동)
PROM_ENDPOINT="http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"

helm upgrade --install opencost opencost/opencost \
  --namespace opencost --create-namespace \
  --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "kubernetes-admin@mgmt" \
  --set opencost.prometheus.internal.serviceName="kube-prometheus-stack-prometheus" \
  --set opencost.prometheus.internal.namespaceName="monitoring" \
  --set opencost.prometheus.internal.port=9090 \
  --set opencost.prometheus.external.url="${PROM_ENDPOINT}" \
  --set opencost.ui.enabled=true \
  --set serviceMonitor.enabled=false \
  --set priorityClassName=platform-normal \
  --wait --timeout 120s

echo "OpenCost installed. UI available via port-forward:"
echo "  $(get_kubectl_cmd mgmt) -n opencost port-forward svc/opencost 9090:9090"

# =============================================================================
# 4. VPA + Goldilocks (~300MB)
# =============================================================================
echo ""
echo "=== [4/5] Installing VPA + Goldilocks ==="

# VPA (Vertical Pod Autoscaler)
helm upgrade --install vpa fairwinds-stable/vpa \
  --namespace vpa --create-namespace \
  --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "kubernetes-admin@mgmt" \
  --set recommender.enabled=true \
  --set updater.enabled=false \
  --set admissionController.enabled=false \
  --set priorityClassName=platform-normal \
  --wait --timeout 120s

echo "VPA installed (recommender only, updater/admission disabled)."

# Goldilocks
helm upgrade --install goldilocks fairwinds-stable/goldilocks \
  --namespace goldilocks --create-namespace \
  --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "kubernetes-admin@mgmt" \
  --set dashboard.enabled=true \
  --set dashboard.service.type=ClusterIP \
  --set priorityClassName=platform-normal \
  --wait --timeout 120s

echo "Goldilocks installed. Dashboard:"
echo "  $(get_kubectl_cmd mgmt) -n goldilocks port-forward svc/goldilocks-dashboard 8080:80"
echo ""
echo "NOTE: 네임스페이스에 라벨 추가로 Goldilocks 활성화:"
echo "  $(get_kubectl_cmd mgmt) label ns <namespace> goldilocks.fairwinds.com/enabled=true"

# =============================================================================
# 5. Chaos Mesh (~200MB)
# =============================================================================
echo ""
echo "=== [5/5] Installing Chaos Mesh ==="

helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace chaos-mesh --create-namespace \
  --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "kubernetes-admin@mgmt" \
  --set dashboard.securityMode=false \
  --set dashboard.service.type=ClusterIP \
  --set controllerManager.enableFilterNamespace=true \
  --set controllerManager.priorityClassName=platform-normal \
  --wait --timeout 180s

echo "Chaos Mesh installed. Dashboard:"
echo "  $(get_kubectl_cmd mgmt) -n chaos-mesh port-forward svc/chaos-dashboard 2333:2333"

# =============================================================================
# 설치 요약
# =============================================================================
echo ""
echo "================================================================="
echo "  Platform Addons Installation Summary (mgmt cluster)"
echo "================================================================="
echo "  [OK] Trivy Operator    - trivy-system   namespace"
echo "  [OK] K8sGPT Operator   - k8sgpt         namespace"
echo "  [OK] OpenCost          - opencost        namespace"
echo "  [OK] VPA               - vpa             namespace"
echo "  [OK] Goldilocks        - goldilocks      namespace"
echo "  [OK] Chaos Mesh        - chaos-mesh      namespace"
echo "================================================================="
echo ""
echo "Estimated additional RAM: ~1.0 GB on mgmt-worker-0"
echo "Run 'scripts/verify-clusters.sh' to check cluster health."

#!/bin/bash
set -euo pipefail

# Usage: install-istio.sh [istio-version]
# Istio Service Mesh 설치 (Cilium CNI 통합 모드)
# - mgmt 클러스터: Ingress Gateway + Istiod
# - app1 클러스터: Full Mesh (Istiod + Gateway + Sidecar)
# - app2 클러스터: 선택적 (추후 결정)

ISTIO_VERSION="${1:-1.26.2}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../scripts/lib/constants.sh"

# Setup
setup_common_vars

# istioctl 설치 확인
if ! command -v istioctl &>/dev/null; then
  echo "ERROR: istioctl not found. Please install it first:"
  echo "  brew install istioctl"
  exit 1
fi

if ! ISTIOCTL_VERSION=$(istioctl version --remote=false --short 2>/dev/null); then
  echo "WARNING: Could not determine istioctl version"
  ISTIOCTL_VERSION="unknown"
fi
echo "Using istioctl version: ${ISTIOCTL_VERSION}"

# kubectl 확인
if ! command -v kubectl &>/dev/null; then
  echo "ERROR: kubectl not found. Please install it first:"
  echo "  brew install kubectl"
  exit 1
fi

# =============================================================================
# Istio 설치 대상 클러스터 정의
# =============================================================================
# mgmt, app1에만 설치 (app2는 선택적)
ISTIO_CLUSTERS="mgmt app1"

for CLUSTER in ${ISTIO_CLUSTERS}; do
  CONTEXT="kubernetes-admin@${CLUSTER}"

  echo ""
  echo "=== Installing Istio on ${CLUSTER} cluster ==="

  # =============================================================================
  # 1. Istio Operator 또는 IstioOperator CRD 생성
  # =============================================================================
  echo "[1/4] Creating IstioOperator configuration for ${CLUSTER}..."

  # Cluster별 설정 차별화
  if [[ "${CLUSTER}" == "mgmt" ]]; then
    PROFILE="default"
    ENABLE_SIDECAR="false"
  else
    PROFILE="default"
    ENABLE_SIDECAR="true"
  fi

  # IstioOperator 임시 파일 생성
  ISTIO_OPERATOR_FILE="${GENERATED_DIR}/istio-operator-${CLUSTER}.yaml"

  cat > "${ISTIO_OPERATOR_FILE}" <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istio-${CLUSTER}
  namespace: istio-system
spec:
  profile: ${PROFILE}

  # Istio CNI 플러그인 사용 (Cilium과 공존)
  components:
    cni:
      enabled: true
      namespace: kube-system

    # Ingress Gateway 설정
    ingressGateways:
    - name: istio-ingressgateway
      enabled: true
      k8s:
        service:
          type: LoadBalancer
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi

    # Egress Gateway (선택적, 필요 시 활성화)
    egressGateways:
    - name: istio-egressgateway
      enabled: false

    # Pilot (Istiod) 설정
    pilot:
      enabled: true
      k8s:
        resources:
          requests:
            cpu: 200m
            memory: 500Mi
          limits:
            cpu: 1000m
            memory: 1Gi
        env:
        # Cilium과의 통합을 위한 설정
        - name: PILOT_ENABLE_WORKLOAD_ENTRY_AUTOREGISTRATION
          value: "true"
        - name: PILOT_ENABLE_WORKLOAD_ENTRY_HEALTHCHECKS
          value: "true"

  # Mesh 설정
  meshConfig:
    # 기본 mTLS 모드
    defaultConfig:
      proxyMetadata:
        # Cilium과의 통합
        ISTIO_META_DNS_CAPTURE: "false"

    # 접근 로그 활성화 (관찰성)
    accessLogFile: /dev/stdout
    accessLogEncoding: JSON

    # Prometheus 통합
    enablePrometheusMerge: true

  # 전역 설정
  values:
    global:
      # Multi-cluster 설정
      meshID: mesh-${CLUSTER}
      multiCluster:
        clusterName: ${CLUSTER}

      # Proxy 설정
      proxy:
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 256Mi

      # Istio CNI 설정
      cni:
        enabled: true
        chained: true  # Cilium과 chaining

      # Sidecar injection 자동화
      istioNamespace: istio-system

    # Sidecar Injector 설정
    sidecarInjectorWebhook:
      enableNamespacesByDefault: ${ENABLE_SIDECAR}

      # Injection 제외 네임스페이스
      neverInjectSelector:
      - matchExpressions:
        - key: istio-injection
          operator: DoesNotExist

    # Telemetry 설정
    telemetry:
      enabled: true
      v2:
        enabled: true
        prometheus:
          enabled: true
EOF

  # =============================================================================
  # 2. Istio 설치
  # =============================================================================
  echo "[2/4] Installing Istio using istioctl..."

  istioctl install \
    --context "${CONTEXT}" \
    --kubeconfig "${KUBECONFIG_MULTI}" \
    --filename "${ISTIO_OPERATOR_FILE}" \
    --skip-confirmation \
    --verify

  # =============================================================================
  # 3. Istio 상태 확인
  # =============================================================================
  echo "[3/4] Verifying Istio installation..."

  if ! istioctl verify-install \
    --context "${CONTEXT}" \
    --kubeconfig "${KUBECONFIG_MULTI}"; then
    echo "WARNING: Istio verification failed, but installation may have succeeded"
    echo "Check manually: istioctl verify-install --context ${CONTEXT}"
  fi

  # Pod 상태 확인 (타임아웃 증가)
  echo "Waiting for istiod deployment..."
  if ! $(get_kubectl_cmd "${CLUSTER}") \
    -n istio-system wait --for=condition=available --timeout=300s \
    deployment/istiod; then
    echo "ERROR: istiod deployment failed to become ready"
    $(get_kubectl_cmd "${CLUSTER}") \
      -n istio-system get pods
    exit 1
  fi

  echo "Waiting for ingress gateway deployment..."
  $(get_kubectl_cmd "${CLUSTER}") \
    -n istio-system wait --for=condition=available --timeout=300s \
    deployment/istio-ingressgateway || echo "WARNING: Ingress gateway not ready"

  # =============================================================================
  # 4. Prometheus ServiceMonitor 생성 (관찰성 통합)
  # =============================================================================
  echo "[4/4] Creating Prometheus ServiceMonitor for Istio..."

  $(get_kubectl_cmd "${CLUSTER}") apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: istiod-metrics
  namespace: istio-system
  labels:
    app: istiod
spec:
  ports:
  - name: http-monitoring
    port: 15014
    targetPort: 15014
  selector:
    app: istiod
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: istio-component-monitor
  namespace: istio-system
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app: istiod
  endpoints:
  - port: http-monitoring
    interval: 30s
EOF

  echo "=== Istio installed successfully on ${CLUSTER} ==="
done

# =============================================================================
# 설치 요약
# =============================================================================
echo ""
echo "================================================================="
echo "  Istio Installation Summary"
echo "================================================================="
for CLUSTER in ${ISTIO_CLUSTERS}; do
  echo ""
  echo "Cluster: ${CLUSTER}"
  echo "  Istiod:"
  $(get_kubectl_cmd "${CLUSTER}") \
    -n istio-system get deploy istiod -o wide
  echo ""
  echo "  Ingress Gateway:"
  $(get_kubectl_cmd "${CLUSTER}") \
    -n istio-system get svc istio-ingressgateway -o wide
done
echo "================================================================="
echo ""
echo "Next steps:"
echo "  1. Label namespaces for sidecar injection:"
echo "     kubectl label namespace default istio-injection=enabled"
echo "  2. Apply Gateway and VirtualService resources"
echo "  3. Verify with: istioctl analyze --context <context>"
echo ""
echo "View Istio proxy status:"
echo "  istioctl proxy-status --context kubernetes-admin@app1"

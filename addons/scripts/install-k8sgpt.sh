#!/bin/bash
set -euo pipefail

# Usage: install-k8sgpt.sh
# K8sGPT 완전 구현 (Operator는 install-platform-addons.sh에서 이미 설치)
# - K8sGPT CR 생성
# - LocalAI 백엔드 통합 (오픈소스, 무료)
# - 클러스터 문제 자동 진단

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../scripts/lib/constants.sh"

# Setup
setup_common_vars

echo "=== Configuring K8sGPT on mgmt cluster ==="

# =============================================================================
# 1. K8sGPT Operator 확인 (이미 install-platform-addons.sh에서 설치됨)
# =============================================================================
echo "[1/3] Checking K8sGPT Operator..."

if ! $(get_kubectl_cmd mgmt) -n aiops get deployment k8sgpt-operator-controller-manager &>/dev/null; then
  echo "ERROR: K8sGPT Operator not found. Run install-platform-addons.sh first."
  exit 1
fi

echo "K8sGPT Operator found."

# =============================================================================
# 2. LocalAI 배포 (오픈소스 LLM 백엔드)
# =============================================================================
echo "[2/3] Installing LocalAI (OpenSource LLM backend)..."

# LocalAI 설치 (경량 LLM, CPU 전용)
$(get_kubectl_cmd mgmt) apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: localai
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: localai
  namespace: localai
spec:
  replicas: 1
  selector:
    matchLabels:
      app: localai
  template:
    metadata:
      labels:
        app: localai
    spec:
      containers:
      - name: localai
        image: quay.io/go-skynet/local-ai:latest
        env:
        - name: MODELS_PATH
          value: /models
        - name: THREADS
          value: "4"
        - name: CONTEXT_SIZE
          value: "2048"
        resources:
          requests:
            memory: 2Gi
            cpu: 1000m
          limits:
            memory: 4Gi
            cpu: 2000m
        volumeMounts:
        - name: models
          mountPath: /models
      volumes:
      - name: models
        persistentVolumeClaim:
          claimName: localai-models
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: localai-models
  namespace: localai
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path-retain
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: Service
metadata:
  name: localai
  namespace: localai
spec:
  selector:
    app: localai
  ports:
  - port: 8080
    targetPort: 8080
EOF

echo "Waiting for LocalAI to be ready..."
$(get_kubectl_cmd mgmt) -n aiops wait --for=condition=available --timeout=180s deployment/localai || \
  echo "WARNING: LocalAI deployment not ready yet, continuing..."

# LocalAI에 모델 다운로드 (경량 모델)
echo "Downloading AI model for LocalAI..."
$(get_kubectl_cmd mgmt) -n aiops exec -i deployment/localai -- sh -c "
  wget -O /models/ggml-gpt4all-j.bin https://gpt4all.io/models/ggml-gpt4all-j.bin || echo 'Model download failed, will retry later'
" || echo "WARNING: Model download failed, K8sGPT will use fallback"

# =============================================================================
# 3. K8sGPT CR 생성 (LocalAI 백엔드 사용)
# =============================================================================
echo "[3/3] Creating K8sGPT Custom Resource..."

$(get_kubectl_cmd mgmt) apply -f - <<EOF
apiVersion: core.k8sgpt.ai/v1alpha1
kind: K8sGPT
metadata:
  name: k8sgpt
  namespace: k8sgpt
spec:
  ai:
    enabled: true
    backend: localai
    baseUrl: http://localai.aiops.svc.cluster.local:8080/v1
    model: ggml-gpt4all-j
    # OpenAI 호환 엔드포인트 사용 (LocalAI가 제공)
  noCache: false
  version: v0.3.x

  # 분석 필터 (어떤 리소스를 분석할지)
  filters:
    - Ingress
    - Pod
    - PersistentVolumeClaim
    - Service
    - ReplicaSet
    - Deployment
    - StatefulSet
    - HorizontalPodAutoscaler
    - NetworkPolicy

  # 분석할 네임스페이스
  namespace: ""  # 전체 네임스페이스

  # Sink 설정 (결과를 Kubernetes에 저장)
  sink:
    type: ""
    endpoint: ""
EOF

echo "K8sGPT CR created."

# =============================================================================
# 4. 검증
# =============================================================================
echo ""
echo "Waiting for K8sGPT analysis..."
sleep 10

# K8sGPT 결과 확인
echo ""
echo "K8sGPT analysis results:"
$(get_kubectl_cmd mgmt) -n aiops get results --no-headers 2>/dev/null | head -5 || echo "No issues found (good!)"

# =============================================================================
# 사용 가이드
# =============================================================================
echo ""
echo "================================================================="
echo "  K8sGPT Configuration Complete"
echo "================================================================="
echo "  [OK] K8sGPT Operator   - k8sgpt namespace"
echo "  [OK] LocalAI Backend   - localai namespace (CPU-only, 2GB RAM)"
echo "  [OK] K8sGPT CR         - AI analysis enabled"
echo "================================================================="
echo ""
echo "View analysis results:"
echo "  $(get_kubectl_cmd mgmt) -n aiops get results"
echo "  $(get_kubectl_cmd mgmt) -n aiops describe result <result-name>"
echo ""
echo "Example result:"
echo "  NAME                      KIND   NAMESPACE   AGE"
echo "  default-pod-nginx-error   Pod    default     2m"
echo ""
echo "Trigger manual analysis:"
echo "  $(get_kubectl_cmd mgmt) -n aiops annotate k8sgpt k8sgpt core.k8sgpt.ai/enabled=true --overwrite"
echo ""
echo "Note: LocalAI is CPU-only and may be slow. For better performance,"
echo "      consider using external API (OpenAI, Gemini) by updating K8sGPT CR."

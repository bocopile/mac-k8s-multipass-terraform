#!/bin/bash
set -euo pipefail

# Usage: install-kyverno.sh [kyverno-version]
# app 클러스터에만 Kyverno 설치 (ADR-003: mgmt 제외)

KYVERNO_VERSION="${1:-3.3.4}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../../scripts/lib/constants.sh"

# Setup
setup_common_vars

# Helm repo 추가
add_helm_repo "kyverno" "${HELM_REPO_KYVERNO}"

CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  # ADR-003: mgmt 클러스터에는 Kyverno 미설치
  if [[ "${CLUSTER}" == "mgmt" ]]; then
    echo "=== Skipping mgmt cluster (ADR-003: PSA baseline only) ==="
    continue
  fi

  echo "=== Installing Kyverno ${KYVERNO_VERSION} on ${CLUSTER} ==="

  ensure_namespace "${NAMESPACE_SECURITY}" "${CLUSTER}"

  $(get_helm_cmd "${CLUSTER}") upgrade --install kyverno kyverno/kyverno \
    --version "${KYVERNO_VERSION}" \
    --namespace "${NAMESPACE_SECURITY}" \
    --set admissionController.replicas=1 \
    --set backgroundController.replicas=1 \
    --set cleanupController.replicas=1 \
    --set reportsController.replicas=1 \
    --set admissionController.priorityClassName=platform-normal \
    --set backgroundController.priorityClassName=platform-normal \
    --set cleanupController.priorityClassName=platform-normal \
    --set reportsController.priorityClassName=platform-normal \
    --wait --timeout "${TIMEOUT_DEPLOYMENT}s"

  echo "Waiting for Kyverno admission controller..."
  $(get_kubectl_cmd "${CLUSTER}") -n "${NAMESPACE_SECURITY}" wait deploy/kyverno-admission-controller \
    --for=condition=available --timeout="${TIMEOUT_POD_READY}s"

  # PodDisruptionBudget 생성 (admission webhook 보호)
  echo "Creating PodDisruptionBudgets for Kyverno on ${CLUSTER}..."
  $(get_kubectl_cmd "${CLUSTER}") apply -f - <<EOF
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: kyverno-admission-controller-pdb
  namespace: ${NAMESPACE_SECURITY}
spec:
  maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/component: admission-controller
      app.kubernetes.io/instance: kyverno
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: kyverno-background-controller-pdb
  namespace: ${NAMESPACE_SECURITY}
spec:
  maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/component: background-controller
      app.kubernetes.io/instance: kyverno
EOF

  # 기본 정책 적용 (§7.3 정책 범위)
  echo "Applying Kyverno policies on ${CLUSTER}..."

  # 1. 이미지 레지스트리 제한 (Harbor만 허용)
  $(get_kubectl_cmd "${CLUSTER}") apply -f - <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-image-registries
  annotations:
    policies.kyverno.io/title: Restrict Image Registries
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: validate-registries
      match:
        any:
          - resources:
              kinds:
                - Pod
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - cilium-system
                - kyverno
                - monitoring
                - observability
                - security
                - backup
                - cert-manager
                - external-secrets
      validate:
        message: "이미지는 Harbor 레지스트리(${HARBOR_REGISTRY}) 또는 공식 레지스트리만 허용됩니다."
        pattern:
          spec:
            containers:
              - image: "${HARBOR_REGISTRY}/* | registry.k8s.io/* | docker.io/library/* | quay.io/*"
EOF

  # 2. 리소스 제한 필수
  $(get_kubectl_cmd "${CLUSTER}") apply -f - <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-limits
  annotations:
    policies.kyverno.io/title: Require Resource Limits
    policies.kyverno.io/severity: medium
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: validate-resources
      match:
        any:
          - resources:
              kinds:
                - Pod
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - cilium-system
                - kyverno
                - monitoring
                - observability
                - security
                - backup
                - cert-manager
                - external-secrets
      validate:
        message: "모든 컨테이너에 resources.requests와 resources.limits가 필요합니다."
        pattern:
          spec:
            containers:
              - resources:
                  requests:
                    memory: "?*"
                    cpu: "?*"
                  limits:
                    memory: "?*"
EOF

  # 3. 권한 있는 컨테이너 금지
  $(get_kubectl_cmd "${CLUSTER}") apply -f - <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged-containers
  annotations:
    policies.kyverno.io/title: Disallow Privileged Containers
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: validate-privileged
      match:
        any:
          - resources:
              kinds:
                - Pod
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - cilium-system
                - kyverno
                - monitoring
                - observability
                - security
                - backup
                - cert-manager
                - external-secrets
      validate:
        message: "Privileged 컨테이너는 허용되지 않습니다."
        pattern:
          spec:
            containers:
              - securityContext:
                  privileged: "false"
EOF

  # 4. 라벨 필수 (audit 모드)
  $(get_kubectl_cmd "${CLUSTER}") apply -f - <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels
  annotations:
    policies.kyverno.io/title: Require Labels
    policies.kyverno.io/severity: low
spec:
  validationFailureAction: Audit
  background: true
  rules:
    - name: check-labels
      match:
        any:
          - resources:
              kinds:
                - Deployment
                - StatefulSet
      exclude:
        any:
          - resources:
              namespaces:
                - kube-system
                - cilium-system
                - kyverno
                - monitoring
                - observability
                - security
                - backup
                - cert-manager
                - external-secrets
      validate:
        message: "app과 version 라벨이 필요합니다."
        pattern:
          metadata:
            labels:
              app: "?*"
              version: "?*"
EOF

  echo "=== Kyverno installed on ${CLUSTER} with 4 policies ==="
done

echo ""
echo "=== Kyverno installation complete on app clusters ==="
echo "Policies applied:"
echo "  [enforce] restrict-image-registries"
echo "  [enforce] require-resource-limits"
echo "  [enforce] disallow-privileged-containers"
echo "  [audit]   require-labels"

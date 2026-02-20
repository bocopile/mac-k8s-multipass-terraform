#!/bin/bash
set -euo pipefail

# Usage: install-kyverno.sh [kyverno-version]
# app 클러스터에만 Kyverno 설치 (ADR-003: mgmt 제외)

KYVERNO_VERSION="${1:-3.3.4}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"
CLUSTERS_JSON="${GENERATED_DIR}/clusters.json"

if [[ ! -f "${CLUSTERS_JSON}" ]]; then
  echo "ERROR: clusters.json not found at ${CLUSTERS_JSON}"
  exit 1
fi

# Helm repo 추가
helm repo add kyverno https://kyverno.github.io/kyverno 2>/dev/null || true
helm repo update kyverno

CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  # ADR-003: mgmt 클러스터에는 Kyverno 미설치
  if [[ "${CLUSTER}" == "mgmt" ]]; then
    echo "=== Skipping mgmt cluster (ADR-003: PSA baseline only) ==="
    continue
  fi

  CONTEXT="kubernetes-admin@${CLUSTER}"
  KC="--kubeconfig ${KUBECONFIG_MULTI} --kube-context ${CONTEXT}"
  KC_KUBECTL="--kubeconfig ${KUBECONFIG_MULTI} --context ${CONTEXT}"

  echo "=== Installing Kyverno ${KYVERNO_VERSION} on ${CLUSTER} ==="

  helm upgrade --install kyverno kyverno/kyverno \
    --version "${KYVERNO_VERSION}" \
    --namespace security --create-namespace \
    ${KC} \
    --set admissionController.replicas=1 \
    --set backgroundController.replicas=1 \
    --set cleanupController.replicas=1 \
    --set reportsController.replicas=1 \
    --wait --timeout 180s

  echo "Waiting for Kyverno admission controller..."
  kubectl ${KC_KUBECTL} -n security wait deploy/kyverno-admission-controller \
    --for=condition=available --timeout=120s

  # 기본 정책 적용 (§7.3 정책 범위)
  echo "Applying Kyverno policies on ${CLUSTER}..."

  # 1. 이미지 레지스트리 제한 (Harbor만 허용)
  kubectl ${KC_KUBECTL} apply -f - <<'EOF'
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
                - observability
                - security
                - backup
                - cert-manager
                - external-secrets
      validate:
        message: "이미지는 Harbor 레지스트리(localhost:8443) 또는 공식 레지스트리만 허용됩니다."
        pattern:
          spec:
            containers:
              - image: "localhost:8443/* | registry.k8s.io/* | docker.io/library/* | quay.io/*"
EOF

  # 2. 리소스 제한 필수
  kubectl ${KC_KUBECTL} apply -f - <<'EOF'
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
  kubectl ${KC_KUBECTL} apply -f - <<'EOF'
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
  kubectl ${KC_KUBECTL} apply -f - <<'EOF'
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

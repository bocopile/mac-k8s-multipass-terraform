#!/bin/bash
set -euo pipefail

# Usage: install-priority-classes.sh
# 전 클러스터에 PriorityClass 리소스 생성 (스케줄링 우선순위)
# - platform-critical (1000000): Cilium, Vault, cert-manager
# - platform-normal   (100000):  기타 플랫폼 컴포넌트

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../../scripts/lib/constants.sh"

# Setup
setup_common_vars

CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  echo "=== Creating PriorityClasses on ${CLUSTER} ==="

  $(get_kubectl_cmd "${CLUSTER}") apply -f - <<'EOF'
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: platform-critical
value: 1000000
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: "플랫폼 핵심 컴포넌트 (Cilium, Vault, cert-manager)"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: platform-normal
value: 100000
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: "플랫폼 일반 컴포넌트 (ArgoCD, Prometheus, Loki 등)"
EOF

  echo "=== PriorityClasses created on ${CLUSTER} ==="
done

echo ""
echo "=== PriorityClass setup complete ==="
echo "  platform-critical: value=1000000  → Cilium, Vault, cert-manager"
echo "  platform-normal:   value=100000   → 기타 플랫폼 컴포넌트"
echo ""
echo "Cleanup (uninstall):"
echo "  kubectl delete priorityclass platform-critical platform-normal"

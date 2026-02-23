#!/bin/bash
set -euo pipefail

# Usage: install-argocd.sh
# mgmt 클러스터에 ArgoCD를 설치하고 app1/app2 클러스터를 등록합니다.
# - mgmt 클러스터에서 3개 클러스터의 GitOps 배포를 중앙 관리
# - §1.3 핵심 원칙 "GitOps: ArgoCD 기반 선언적 배포" 구현

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../scripts/lib/constants.sh"

# Setup
setup_common_vars

# =============================================================================
# Helm Repo 등록
# =============================================================================
add_helm_repo "argo" "${HELM_REPO_ARGO}"

# =============================================================================
# ArgoCD 네임스페이스 생성
# =============================================================================
ensure_namespace "${NAMESPACE_ARGOCD}" "mgmt"

# =============================================================================
# ArgoCD 설치
# =============================================================================
log_info "Installing ArgoCD on mgmt cluster"

$(get_helm_cmd mgmt) upgrade --install argocd argo/argo-cd \
  --namespace "${NAMESPACE_ARGOCD}" \
  --set server.service.type=ClusterIP \
  --set server.resources.requests.memory=128Mi \
  --set server.resources.requests.cpu=100m \
  --set server.resources.limits.memory=256Mi \
  --set server.resources.limits.cpu=200m \
  --set controller.resources.requests.memory=256Mi \
  --set controller.resources.requests.cpu=100m \
  --set controller.resources.limits.memory=512Mi \
  --set controller.resources.limits.cpu=500m \
  --set repoServer.resources.requests.memory=128Mi \
  --set repoServer.resources.requests.cpu=100m \
  --set repoServer.resources.limits.memory=256Mi \
  --set repoServer.resources.limits.cpu=200m \
  --set redis.resources.requests.memory=64Mi \
  --set redis.resources.requests.cpu=50m \
  --set redis.resources.limits.memory=128Mi \
  --set redis.resources.limits.cpu=100m \
  --set global.priorityClassName=platform-normal \
  --wait --timeout 300s

echo "ArgoCD installed."

# =============================================================================
# PodDisruptionBudget 생성 (자발적 중단 보호)
# maxUnavailable:0 + replica:1 → 노드 드레인 시 Pod 보호
# =============================================================================
log_info "Creating PodDisruptionBudgets for ArgoCD"

$(get_kubectl_cmd mgmt) apply -f - <<'EOF'
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: argocd-server-pdb
  namespace: argocd
spec:
  maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-server
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: argocd-repo-server-pdb
  namespace: argocd
spec:
  maxUnavailable: 0
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-repo-server
EOF

# =============================================================================
# ArgoCD 초기 관리자 비밀번호 확인
# =============================================================================
echo ""
echo "=== ArgoCD Admin Password ==="
ARGOCD_PASSWORD=$($(get_kubectl_cmd mgmt) -n "${NAMESPACE_ARGOCD}" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "(not found)")
echo "  Username: admin"
echo "  Password: $(get_kubectl_cmd mgmt) -n ${NAMESPACE_ARGOCD} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"

# =============================================================================
# ArgoCD CLI 설치 확인
# =============================================================================
if ! command -v argocd &>/dev/null; then
  echo ""
  echo "NOTE: ArgoCD CLI not found. Installing..."
  CLI_ARCH="amd64"
  if [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then
    CLI_ARCH="arm64"
  fi
  curl -sSL -o /usr/local/bin/argocd \
    "https://github.com/argoproj/argo-cd/releases/latest/download/argocd-darwin-${CLI_ARCH}" 2>/dev/null || true
  chmod +x /usr/local/bin/argocd 2>/dev/null || true
fi

# =============================================================================
# App 클러스터 등록
# =============================================================================
echo ""
echo "=== Registering app clusters with ArgoCD ==="

# ArgoCD 서버 포트포워드 (백그라운드)
$(get_kubectl_cmd mgmt) -n "${NAMESPACE_ARGOCD}" port-forward svc/argocd-server 8443:443 &>/dev/null &
PF_PID=$!
sleep 3

if command -v argocd &>/dev/null && [[ -n "${ARGOCD_PASSWORD}" && "${ARGOCD_PASSWORD}" != "(not found)" ]]; then
  # ArgoCD 로그인 (--insecure: localhost port-forward는 TLS 인증서가 없으므로 검증 스킵 필요)
  if ! argocd login localhost:8443 \
    --username admin \
    --password "${ARGOCD_PASSWORD}" \
    --insecure 2>/dev/null; then
    log_warn "ArgoCD login failed. Cluster registration will be skipped."
  else
    # app1 클러스터 등록
    log_info "Registering app1 cluster..."
    argocd cluster add "kubernetes-admin@app1" \
      --kubeconfig "${KUBECONFIG_MULTI}" \
      --name app1 \
      --yes 2>/dev/null || log_warn "app1 registration skipped or already registered"

    # app2 클러스터 등록
    log_info "Registering app2 cluster..."
    argocd cluster add "kubernetes-admin@app2" \
      --kubeconfig "${KUBECONFIG_MULTI}" \
      --name app2 \
      --yes 2>/dev/null || log_warn "app2 registration skipped or already registered"

    log_info "Listing registered clusters..."
    argocd cluster list || true
  fi
else
  echo "NOTE: ArgoCD CLI not available or password not found."
  echo "  Manual cluster registration required:"
  echo "  argocd cluster add kubernetes-admin@app1 --kubeconfig ${KUBECONFIG_MULTI} --name app1"
  echo "  argocd cluster add kubernetes-admin@app2 --kubeconfig ${KUBECONFIG_MULTI} --name app2"
fi

# 포트포워드 종료
kill ${PF_PID} 2>/dev/null || true

# =============================================================================
# 설치 요약
# =============================================================================
echo ""
echo "================================================================="
echo "  ArgoCD Installation Summary (mgmt cluster)"
echo "================================================================="
echo "  [OK] ArgoCD Server     - argocd namespace"
echo "  [OK] ArgoCD Controller - argocd namespace"
echo "  [OK] ArgoCD Repo Server - argocd namespace"
echo "  [OK] Redis             - argocd namespace"
echo "================================================================="
echo ""
echo "Access ArgoCD UI:"
echo "  $(get_kubectl_cmd mgmt) -n ${NAMESPACE_ARGOCD} port-forward svc/argocd-server 8080:443"
echo "  https://localhost:8080"
echo "  Username: admin"
echo "  Password: $(get_kubectl_cmd mgmt) -n ${NAMESPACE_ARGOCD} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "Estimated RAM: ~500MB on mgmt-worker-0"

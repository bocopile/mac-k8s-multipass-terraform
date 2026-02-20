#!/bin/bash
set -euo pipefail

# Usage: install-argocd.sh
# mgmt 클러스터에 ArgoCD를 설치하고 app1/app2 클러스터를 등록합니다.
# - mgmt 클러스터에서 3개 클러스터의 GitOps 배포를 중앙 관리
# - §1.3 핵심 원칙 "GitOps: ArgoCD 기반 선언적 배포" 구현

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"
CLUSTERS_JSON="${GENERATED_DIR}/clusters.json"

if [[ ! -f "${CLUSTERS_JSON}" ]]; then
  echo "ERROR: clusters.json not found at ${CLUSTERS_JSON}"
  exit 1
fi

# mgmt 클러스터 컨텍스트
MGMT_CONTEXT="kubernetes-admin@mgmt"
KC="--kubeconfig ${KUBECONFIG_MULTI} --kube-context ${MGMT_CONTEXT}"
KC_KUBECTL="--kubeconfig ${KUBECONFIG_MULTI} --context ${MGMT_CONTEXT}"

# =============================================================================
# Helm Repo 등록
# =============================================================================
echo "=== Adding ArgoCD Helm repository ==="
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update

# =============================================================================
# ArgoCD 네임스페이스 생성
# =============================================================================
kubectl ${KC_KUBECTL} create namespace argocd 2>/dev/null || true

# =============================================================================
# ArgoCD 설치
# =============================================================================
echo ""
echo "=== Installing ArgoCD on mgmt cluster ==="

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  ${KC} \
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
  --set configs.params."server\.insecure"=true \
  --wait --timeout 300s

echo "ArgoCD installed."

# =============================================================================
# ArgoCD 초기 관리자 비밀번호 확인
# =============================================================================
echo ""
echo "=== ArgoCD Admin Password ==="
ARGOCD_PASSWORD=$(kubectl ${KC_KUBECTL} -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "(not found)")
echo "  Username: admin"
echo "  Password: ${ARGOCD_PASSWORD}"

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
kubectl ${KC_KUBECTL} -n argocd port-forward svc/argocd-server 8443:443 &>/dev/null &
PF_PID=$!
sleep 3

if command -v argocd &>/dev/null && [[ -n "${ARGOCD_PASSWORD}" && "${ARGOCD_PASSWORD}" != "(not found)" ]]; then
  # ArgoCD 로그인
  argocd login localhost:8443 \
    --username admin \
    --password "${ARGOCD_PASSWORD}" \
    --insecure 2>/dev/null || true

  # app1 클러스터 등록
  echo "Registering app1 cluster..."
  argocd cluster add "kubernetes-admin@app1" \
    --kubeconfig "${KUBECONFIG_MULTI}" \
    --name app1 \
    --yes 2>/dev/null || echo "  (app1 registration skipped or already registered)"

  # app2 클러스터 등록
  echo "Registering app2 cluster..."
  argocd cluster add "kubernetes-admin@app2" \
    --kubeconfig "${KUBECONFIG_MULTI}" \
    --name app2 \
    --yes 2>/dev/null || echo "  (app2 registration skipped or already registered)"

  echo "Listing registered clusters..."
  argocd cluster list 2>/dev/null || true
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
echo "  kubectl ${KC_KUBECTL} -n argocd port-forward svc/argocd-server 8080:443"
echo "  https://localhost:8080"
echo "  Username: admin / Password: ${ARGOCD_PASSWORD}"
echo ""
echo "Estimated RAM: ~500MB on mgmt-worker-0"

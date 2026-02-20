#!/bin/bash
set -euo pipefail

# Usage: install-botkube.sh
# Botkube 설치 - Slack에서 Kubernetes 관리
# - Slack 통합
# - kubectl 명령어 실행
# - 알림 자동 전달
# - RBAC 및 승인 플로우

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"

if [[ ! -f "${KUBECONFIG_MULTI}" ]]; then
  echo "ERROR: kubeconfig-multi not found at ${GENERATED_DIR}"
  exit 1
fi

MGMT_CONTEXT="kubernetes-admin@mgmt"
KC="--kubeconfig ${KUBECONFIG_MULTI} --kube-context ${MGMT_CONTEXT}"

echo "=== Installing Botkube on mgmt cluster ==="

# =============================================================================
# Slack 토큰 확인
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SLACK SETUP REQUIRED"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Before continuing, you need to:"
echo ""
echo "1. Create a Slack App:"
echo "   https://api.slack.com/apps?new_app=1"
echo ""
echo "2. Add Bot Token Scopes:"
echo "   - app_mentions:read"
echo "   - chat:write"
echo "   - channels:read"
echo "   - files:write"
echo ""
echo "3. Install App to Workspace and get Bot Token (xoxb-...)"
echo ""
echo "4. Create Slack channel (e.g., #kubernetes-alerts)"
echo ""
echo "5. Invite bot to channel:"
echo "   /invite @Botkube"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Slack 토큰 입력 받기
read -p "Enter Slack Bot Token (xoxb-...): " SLACK_TOKEN
if [[ -z "${SLACK_TOKEN}" ]]; then
  echo "ERROR: Slack token is required"
  echo "Skipping Botkube installation. Run this script again with Slack token."
  exit 1
fi

read -p "Enter Slack Channel Name (e.g., kubernetes-alerts): " SLACK_CHANNEL
if [[ -z "${SLACK_CHANNEL}" ]]; then
  SLACK_CHANNEL="kubernetes-alerts"
  echo "Using default channel: ${SLACK_CHANNEL}"
fi

# =============================================================================
# 1. Helm Repo 추가
# =============================================================================
echo ""
echo "[1/3] Adding Botkube Helm repository..."
helm repo add botkube https://charts.botkube.io 2>/dev/null || true
helm repo update botkube

# =============================================================================
# 2. Botkube 설치
# =============================================================================
echo "[2/3] Installing Botkube..."

helm upgrade --install botkube botkube/botkube \
  --namespace aiops --create-namespace \
  ${KC} \
  --set settings.clusterName=mgmt \
  --set communications.default-group.slack.enabled=true \
  --set communications.default-group.slack.token="${SLACK_TOKEN}" \
  --set communications.default-group.slack.channels.default.name="${SLACK_CHANNEL}" \
  --set communications.default-group.slack.channels.default.notification.disabled=false \
  --set executors.kubectl-read-only.kubectl.enabled=true \
  --set 'executors.kubectl-read-only.kubectl.commands.verbs={get,describe,logs,top}' \
  --set executors.kubectl-read-only.kubectl.defaultNamespace=default \
  --set executors.kubectl-admin.kubectl.enabled=true \
  --set 'executors.kubectl-admin.kubectl.commands.verbs={get,describe,logs,delete,edit,apply,restart,scale}' \
  --set executors.kubectl-admin.kubectl.restrictAccess.enabled=true \
  --set sources.k8s-events.kubernetes.enabled=true \
  --set 'sources.k8s-events.kubernetes.namespaces.include={default,production,staging,monitoring}' \
  --set sources.k8s-events.kubernetes.event.types[0]=error \
  --set sources.k8s-events.kubernetes.event.types[1]=warning \
  --set sources.k8s-recommendations.recommendations.enabled=true \
  --set rbac.create=true \
  --set serviceAccount.create=true \
  --wait --timeout 180s

echo "Botkube installed."

# =============================================================================
# 3. 검증
# =============================================================================
echo "[3/3] Verifying Botkube installation..."

# Pod 확인
kubectl ${KC} -n aiops wait --for=condition=ready --timeout=120s pod -l app.kubernetes.io/name=botkube

echo ""
echo "Botkube is ready!"

# =============================================================================
# 사용 가이드
# =============================================================================
echo ""
echo "================================================================="
echo "  Botkube Installation Complete"
echo "================================================================="
echo "  [OK] Botkube Runner    - botkube namespace"
echo "  [OK] Slack Integration - Channel: #${SLACK_CHANNEL}"
echo "  [OK] RBAC              - Read-only + Admin (approval required)"
echo "================================================================="
echo ""
echo "Test Botkube in Slack:"
echo ""
echo "  1. Go to Slack channel: #${SLACK_CHANNEL}"
echo ""
echo "  2. Test commands:"
echo "     @botkube ping"
echo "     @botkube get pods"
echo "     @botkube get nodes"
echo "     @botkube help"
echo ""
echo "Read-only commands (no approval):"
echo "  - get, describe, logs, top"
echo ""
echo "Admin commands (approval required):"
echo "  - delete, edit, apply, restart, scale"
echo ""
echo "Example workflow:"
echo "  You: @botkube get pods -n production"
echo "  Botkube: [Lists pods]"
echo ""
echo "  You: @botkube logs my-pod -n production"
echo "  Botkube: [Shows logs]"
echo ""
echo "  You: @botkube restart deployment my-app -n production"
echo "  Botkube: ⚠️ Approval required. React with ✅ to approve."
echo ""
echo "Configure approvers:"
echo "  kubectl ${KC} -n aiops edit configmap botkube-config"
echo ""
echo "View Botkube logs:"
echo "  kubectl ${KC} -n aiops logs deployment/botkube -f"

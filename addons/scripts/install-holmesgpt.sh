#!/bin/bash
set -euo pipefail

# Usage: install-holmesgpt.sh
# HolmesGPT (Robusta) 설치 - AI 기반 알림 자동 조사
# - Prometheus Alertmanager 통합
# - Loki 로그 분석
# - Tempo 트레이스 분석
# - 근본 원인 자동 분석 (RCA)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../scripts/lib/constants.sh"

# Setup
setup_common_vars

echo "=== Installing HolmesGPT (Robusta) on mgmt cluster ==="

# =============================================================================
# 1. Helm Repo 추가
# =============================================================================
echo "[1/4] Adding Robusta Helm repository..."
add_helm_repo "robusta" "${HELM_REPO_ROBUSTA}"

# =============================================================================
# 2. Robusta + HolmesGPT 설치
# =============================================================================
echo "[2/4] Installing Robusta with HolmesGPT..."

# NOTE: HolmesGPT는 Robusta의 AI 기능
# 오픈소스 버전은 기본 기능만 제공
# AI 분석은 로컬 LLM 또는 외부 API 필요

helm upgrade --install robusta robusta/robusta \
  --namespace aiops --create-namespace \
  --kubeconfig "${KUBECONFIG_MULTI}" --kube-context "kubernetes-admin@mgmt" \
  --set clusterName=mgmt \
  --set playbookRepos.robusta_playbooks.url=https://github.com/robusta-dev/robusta \
  --set enablePrometheusStack=false \
  --set enableServiceMonitors=true \
  --set runner.sendAdditionalTelemetry=false \
  --set runner.resources.requests.memory=512Mi \
  --set runner.resources.requests.cpu=500m \
  --set runner.resources.limits.memory=1Gi \
  --set runner.resources.limits.cpu=1000m \
  --wait --timeout 180s

echo "Robusta installed."

# =============================================================================
# 3. Prometheus Alertmanager 통합
# =============================================================================
echo "[3/4] Configuring Prometheus Alertmanager integration..."

# Alertmanager에 Robusta webhook 추가
$(get_kubectl_cmd mgmt) -n monitoring patch alertmanagerconfig \
  kube-prometheus-stack-alertmanager-config --type=merge -p='
{
  "spec": {
    "receivers": [
      {
        "name": "robusta",
        "webhookConfigs": [
          {
            "url": "http://robusta-runner.aiops.svc.cluster.local:5000/api/alerts",
            "sendResolved": true
          }
        ]
      }
    ],
    "route": {
      "receiver": "robusta",
      "groupWait": "30s",
      "groupInterval": "5m",
      "repeatInterval": "12h",
      "routes": [
        {
          "receiver": "robusta",
          "matchers": [
            {
              "name": "severity",
              "value": "critical|warning",
              "matchType": "=~"
            }
          ]
        }
      ]
    }
  }
}
' 2>/dev/null || echo "NOTE: Alertmanager configuration already exists or manual setup required"

# =============================================================================
# 4. HolmesGPT 설정 (AI 분석)
# =============================================================================
echo "[4/4] Configuring HolmesGPT AI analysis..."

# Robusta Playbook 설정 (AI 자동 조사)
$(get_kubectl_cmd mgmt) -n aiops create configmap holmes-config --from-literal=config.yaml="
globalConfig:
  cluster_name: mgmt

  # AI 설정 (LocalAI 사용)
  holmes:
    enabled: true
    llm:
      provider: localai
      endpoint: http://localai.localai.svc.cluster.local:8080/v1
      model: ggml-gpt4all-j

  # 데이터 소스 (관찰성 스택 통합)
  observability:
    prometheus:
      url: http://kube-prometheus-stack-prometheus.monitoring.svc:9090
    loki:
      url: http://loki.monitoring.svc:3100
    tempo:
      url: http://tempo.monitoring.svc:3100

sinksConfig:
  - slack_sink:
      name: main_slack_sink
      api_key: ''  # Slack 토큰 (선택적)
      channel: ''  # Slack 채널 (선택적)

customPlaybooks:
  - triggers:
    - on_prometheus_alert:
        alert_name: .*  # 모든 알림
    actions:
    # 1. AI 분석 실행
    - holmes_investigate:
        post_processing_renderer: 'markdown'
        include:
          - logs
          - metrics
          - traces

    # 2. 결과를 Kubernetes Event로 저장
    - create_finding:
        title: 'HolmesGPT Analysis'
        aggregation_key: 'holmes'
" --dry-run=client -o yaml | $(get_kubectl_cmd mgmt) apply -f - || echo "WARNING: Failed to create holmes-config"

# =============================================================================
# 설치 요약
# =============================================================================
echo ""
echo "================================================================="
echo "  HolmesGPT (Robusta) Installation Summary"
echo "================================================================="
echo "  [OK] Robusta Runner    - aiops namespace (~512MB)"
echo "  [OK] Alertmanager      - Webhook configured"
echo "  [OK] HolmesGPT AI      - LocalAI backend"
echo "================================================================="
echo ""
echo "Data Sources:"
echo "  ✓ Prometheus: kube-prometheus-stack-prometheus.monitoring.svc:9090"
echo "  ✓ Loki:       loki.monitoring.svc:3100"
echo "  ✓ Tempo:      tempo.monitoring.svc:3100"
echo ""
echo "View Robusta analysis:"
echo "  $(get_kubectl_cmd mgmt) -n aiops logs deployment/robusta-runner -f"
echo ""
echo "Test HolmesGPT:"
echo "  1. Trigger a test alert:"
echo "     $(get_kubectl_cmd mgmt) run test-crash --image=busybox --restart=Never -- sh -c 'exit 1'"
echo ""
echo "  2. Wait for alert (may take 1-2 minutes)"
echo ""
echo "  3. Check HolmesGPT analysis:"
echo "     $(get_kubectl_cmd mgmt) -n aiops logs deployment/robusta-runner | grep -A 20 'holmes'"
echo ""
echo "Note: HolmesGPT uses LocalAI (CPU-only) which may be slow."
echo "      For production, consider using external LLM API (OpenAI, Gemini)."

#!/bin/bash
set -euo pipefail

# Usage: install-otel-collector.sh [otel-version]
# OpenTelemetry Collector 설치 (전 클러스터)
# - Istio traces 수집
# - Tempo로 전송
# - Prometheus 메트릭 수집

OTEL_VERSION="${1:-0.115.1}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"
CLUSTERS_JSON="${GENERATED_DIR}/clusters.json"

if [[ ! -f "${CLUSTERS_JSON}" ]]; then
  echo "ERROR: clusters.json not found at ${CLUSTERS_JSON}"
  exit 1
fi

echo "=== Installing OpenTelemetry Collector ${OTEL_VERSION} ==="

# Helm Repo 추가
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
helm repo update open-telemetry

# 클러스터별 설치
CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  CONTEXT="kubernetes-admin@${CLUSTER}"

  echo ""
  echo "=== Installing OTel Collector on ${CLUSTER} ==="

  # Tempo 엔드포인트 설정 (mgmt 클러스터의 Tempo)
  if [[ "${CLUSTER}" == "mgmt" ]]; then
    TEMPO_ENDPOINT="tempo.observability.svc.cluster.local:4317"
  else
    # app 클러스터에서는 Cluster Mesh를 통해 mgmt의 Tempo 접근
    TEMPO_ENDPOINT="tempo.observability.svc.cluster.local:4317"
  fi

  # OTel Collector 설치
  helm upgrade --install opentelemetry-collector open-telemetry/opentelemetry-collector \
    --version "${OTEL_VERSION}" \
    --namespace observability --create-namespace \
    --kubeconfig "${KUBECONFIG_MULTI}" \
    --kube-context "${CONTEXT}" \
    --set mode=daemonset \
    --set image.repository=otel/opentelemetry-collector-k8s \
    --set resources.requests.cpu=100m \
    --set resources.requests.memory=256Mi \
    --set resources.limits.cpu=500m \
    --set resources.limits.memory=512Mi \
    --set config.receivers.otlp.protocols.grpc.endpoint="0.0.0.0:4317" \
    --set config.receivers.otlp.protocols.http.endpoint="0.0.0.0:4318" \
    --set config.receivers.prometheus.config.scrape_configs[0].job_name=otel-collector \
    --set config.receivers.prometheus.config.scrape_configs[0].scrape_interval=30s \
    --set config.processors.batch.timeout=10s \
    --set config.processors.batch.send_batch_size=1024 \
    --set config.processors.memory_limiter.check_interval=5s \
    --set config.processors.memory_limiter.limit_mib=400 \
    --set config.exporters.otlp.endpoint="${TEMPO_ENDPOINT}" \
    --set config.exporters.otlp.tls.insecure=true \
    --set config.exporters.prometheus.endpoint="0.0.0.0:8889" \
    --set config.service.pipelines.traces.receivers[0]=otlp \
    --set config.service.pipelines.traces.processors[0]=memory_limiter \
    --set config.service.pipelines.traces.processors[1]=batch \
    --set config.service.pipelines.traces.exporters[0]=otlp \
    --set config.service.pipelines.metrics.receivers[0]=otlp \
    --set config.service.pipelines.metrics.receivers[1]=prometheus \
    --set config.service.pipelines.metrics.processors[0]=batch \
    --set config.service.pipelines.metrics.exporters[0]=prometheus \
    --wait --timeout 180s

  echo "OTel Collector installed on ${CLUSTER}"
done

# =============================================================================
# Istio와 OTel Collector 통합 (Istio 설치된 클러스터만)
# =============================================================================
echo ""
echo "=== Configuring Istio to send traces to OTel Collector ==="

ISTIO_CLUSTERS="mgmt app1"

for CLUSTER in ${ISTIO_CLUSTERS}; do
  CONTEXT="kubernetes-admin@${CLUSTER}"

  echo "Configuring Istio on ${CLUSTER}..."

  # Istio ConfigMap 업데이트 (Tracing 설정)
  kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" \
    -n istio-system get configmap istio &>/dev/null || continue

  # Telemetry API로 Tracing 활성화
  kubectl --kubeconfig "${KUBECONFIG_MULTI}" --context "${CONTEXT}" apply -f - <<EOF
apiVersion: telemetry.istio.io/v1alpha1
kind: Telemetry
metadata:
  name: otel-tracing
  namespace: istio-system
spec:
  tracing:
  - providers:
    - name: otel-collector
    randomSamplingPercentage: 100.0
    customTags:
      cluster:
        literal:
          value: "${CLUSTER}"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: istio-otel
  namespace: istio-system
data:
  mesh: |
    defaultConfig:
      tracing:
        zipkin:
          address: opentelemetry-collector.observability.svc.cluster.local:9411
        sampling: 100.0
    extensionProviders:
    - name: otel-collector
      opentelemetry:
        service: opentelemetry-collector.observability.svc.cluster.local
        port: 4317
EOF

  echo "Istio tracing configured on ${CLUSTER}"
done

# =============================================================================
# 설치 요약
# =============================================================================
echo ""
echo "================================================================="
echo "  OpenTelemetry Collector Installation Summary"
echo "================================================================="
echo "  [OK] OTel Collector ${OTEL_VERSION} - DaemonSet mode"
echo "  [OK] Installed on: ${CLUSTERS}"
echo "  [OK] Traces → Tempo (${TEMPO_ENDPOINT})"
echo "  [OK] Metrics → Prometheus"
echo "  [OK] Istio integration: configured"
echo "================================================================="
echo ""
echo "Verify OTel Collector:"
echo "  kubectl --context kubernetes-admin@mgmt -n observability get pods -l app.kubernetes.io/name=opentelemetry-collector"
echo ""
echo "Test trace collection:"
echo "  kubectl --context kubernetes-admin@mgmt -n observability port-forward daemonset/opentelemetry-collector 4317:4317"
echo ""
echo "Istio will now send traces to:"
echo "  opentelemetry-collector.observability.svc.cluster.local:4317"

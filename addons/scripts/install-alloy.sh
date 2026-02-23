#!/bin/bash
set -euo pipefail

# Usage: install-alloy.sh
# Grafana Alloy를 모든 클러스터에 DaemonSet으로 설치합니다.
# Promtail + Prometheus Agent + OTel Collector를 단일 에이전트로 통합합니다.
# - 로그 수집: loki.source.kubernetes → Loki (전체 로그, ADR-006)
#              loki.source.kubernetes → otelcol bridge → OpenSearch (선별 로그, 선택적)
# - 트레이스 수집: otelcol.receiver.otlp → Tempo
# - 메트릭 수집: prometheus.scrape → Thanos remote_write (app 클러스터만)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load libraries
source "${SCRIPT_DIR}/../../scripts/lib/common.sh"
source "${SCRIPT_DIR}/../../scripts/lib/constants.sh"

# Setup
setup_common_vars

# Helm repo 등록
add_helm_repo "grafana" "${HELM_REPO_GRAFANA}"

# =============================================================================
# 사전 요구사항 확인
# =============================================================================
LOKI_LB_IP=""
if [[ -f "${GENERATED_DIR}/loki-lb-ip" ]]; then
  LOKI_LB_IP=$(cat "${GENERATED_DIR}/loki-lb-ip")
  echo "Loki LB IP: ${LOKI_LB_IP}"
else
  echo "WARNING: ${GENERATED_DIR}/loki-lb-ip not found."
  echo "  app 클러스터에서 in-cluster Loki 주소를 사용합니다 (Cluster Mesh 필요)."
fi

THANOS_RECEIVE_IP=""
if [[ -f "${GENERATED_DIR}/thanos-receive-ip" ]]; then
  THANOS_RECEIVE_IP=$(cat "${GENERATED_DIR}/thanos-receive-ip")
  echo "Thanos Receive IP: ${THANOS_RECEIVE_IP}"
else
  echo "WARNING: ${GENERATED_DIR}/thanos-receive-ip not found."
  echo "  app 클러스터에서 메트릭 remote_write가 비활성화됩니다."
fi

# OpenSearch LoadBalancer IP (선택적 - 없으면 OpenSearch 이중화 비활성화)
OPENSEARCH_LB_IP=""
if [[ -f "${GENERATED_DIR}/opensearch-lb-ip" ]]; then
  OPENSEARCH_LB_IP=$(cat "${GENERATED_DIR}/opensearch-lb-ip")
  echo "OpenSearch LB IP: ${OPENSEARCH_LB_IP}"
else
  echo "INFO: OpenSearch LB IP not found. OpenSearch dual-write 비활성화."
  echo "  OpenSearch 설치 후 재실행: addons/install.sh opensearch alloy"
fi

# Tempo gRPC 엔드포인트 (Cluster Mesh로 전 클러스터에서 접근 가능)
TEMPO_GRPC_ENDPOINT="tempo.${NAMESPACE_OBSERVABILITY}.svc.cluster.local:4317"

# =============================================================================
# 클러스터별 설치
# =============================================================================
CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")

for CLUSTER in ${CLUSTERS}; do
  echo ""
  echo "=== Installing Grafana Alloy on ${CLUSTER} ==="

  # 클러스터별 설정
  if [[ "${CLUSTER}" == "mgmt" ]]; then
    LOKI_URL="http://loki.${NAMESPACE_OBSERVABILITY}.svc.cluster.local:3100"
    ENABLE_METRICS="false"
    THANOS_REMOTE_WRITE_URL=""
    # mgmt는 OpenSearch와 같은 클러스터이므로 in-cluster 주소 사용
    if [[ -n "${OPENSEARCH_LB_IP}" ]]; then
      OPENSEARCH_URL="http://opensearch.${NAMESPACE_OBSERVABILITY}.svc.cluster.local:9200"
      ENABLE_OPENSEARCH="true"
    else
      OPENSEARCH_URL=""
      ENABLE_OPENSEARCH="false"
    fi
  else
    if [[ -n "${LOKI_LB_IP}" ]]; then
      LOKI_URL="http://${LOKI_LB_IP}:3100"
    else
      LOKI_URL="http://loki.${NAMESPACE_OBSERVABILITY}.svc.cluster.local:3100"
      echo "  WARNING: Loki LB IP 없음. Cluster Mesh를 통한 in-cluster 주소 사용."
    fi

    if [[ -n "${THANOS_RECEIVE_IP}" ]]; then
      ENABLE_METRICS="true"
      THANOS_REMOTE_WRITE_URL="http://${THANOS_RECEIVE_IP}:19291/api/v1/receive"
    else
      ENABLE_METRICS="false"
      THANOS_REMOTE_WRITE_URL=""
      echo "  WARNING: Thanos IP 없음. ${CLUSTER} 메트릭 수집 비활성화."
    fi

    # app 클러스터는 LoadBalancer IP로 OpenSearch 접근
    if [[ -n "${OPENSEARCH_LB_IP}" ]]; then
      OPENSEARCH_URL="http://${OPENSEARCH_LB_IP}:9200"
      ENABLE_OPENSEARCH="true"
    else
      OPENSEARCH_URL=""
      ENABLE_OPENSEARCH="false"
    fi
  fi

  # Namespace 생성 (Alloy는 노드 로그 접근을 위해 privileged PSA 필요)
  ensure_namespace_privileged "${NAMESPACE_OBSERVABILITY}" "${CLUSTER}"

  # =============================================================================
  # Alloy 설정 파일 생성
  # 주의: single-quoted heredoc으로 bash 변수 확장 방지 (placeholder 사용)
  # =============================================================================
  ALLOY_CONFIG_FILE="${GENERATED_DIR}/alloy-config-${CLUSTER}.alloy"

  # OpenSearch dual-write 활성화 여부에 따라 forward_to 플레이스홀더 결정
  if [[ "${ENABLE_OPENSEARCH}" == "true" ]]; then
    OS_FORWARD_TO=", otelcol.receiver.loki.os_bridge.receiver"
  else
    OS_FORWARD_TO=""
  fi

  # 기본 config: 로그 수집 + 트레이스 수집
  cat > "${ALLOY_CONFIG_FILE}" <<'ALLOY_EOF'
// =============================================================================
// Grafana Alloy - Unified Observability Agent
// Replaces: Promtail + Prometheus Agent + OTel Collector
// =============================================================================

// ---------------------------------------------------------------------------
// Pod Discovery & Relabeling
// ---------------------------------------------------------------------------
discovery.kubernetes "pods" {
  role = "pod"
}

discovery.relabel "pods" {
  targets = discovery.kubernetes.pods.targets

  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    action        = "replace"
    target_label  = "namespace"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    action        = "replace"
    target_label  = "pod"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_container_name"]
    action        = "replace"
    target_label  = "container"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_node_name"]
    action        = "replace"
    target_label  = "node"
  }
  rule {
    action       = "replace"
    target_label = "cluster"
    replacement  = "__CLUSTER__"
  }
}

// ---------------------------------------------------------------------------
// Log Collection: Kubernetes Pods → Loki (전체) + OpenSearch (선별, 선택적)
// ---------------------------------------------------------------------------
loki.source.kubernetes "pods" {
  targets    = discovery.relabel.pods.output
  forward_to = [loki.write.loki.receiver__OS_FORWARD_TO__]
}

loki.write "loki" {
  endpoint {
    url = "__LOKI_URL__/loki/api/v1/push"
  }
  external_labels = {
    cluster = "__CLUSTER__",
  }
}

// ---------------------------------------------------------------------------
// Trace Collection: OTLP Receiver → Tempo
// ---------------------------------------------------------------------------
otelcol.receiver.otlp "default" {
  grpc {
    endpoint = "0.0.0.0:4317"
  }
  http {
    endpoint = "0.0.0.0:4318"
  }
  output {
    traces = [otelcol.processor.memory_limiter.default.input]
  }
}

otelcol.processor.memory_limiter "default" {
  check_interval         = "1s"
  limit_percentage       = 65
  spike_limit_percentage = 20
  output {
    traces = [otelcol.processor.batch.default.input]
  }
}

otelcol.processor.batch "default" {
  output {
    traces = [otelcol.exporter.otlp.tempo.input]
  }
}

otelcol.exporter.otlp "tempo" {
  client {
    endpoint = "__TEMPO_ENDPOINT__"
    tls {
      insecure = true
    }
  }
}
ALLOY_EOF

  # Placeholder 치환 (| 구분자로 URL 내 / 충돌 방지)
  sed -i.bak \
    -e "s|__CLUSTER__|${CLUSTER}|g" \
    -e "s|__LOKI_URL__|${LOKI_URL}|g" \
    -e "s|__TEMPO_ENDPOINT__|${TEMPO_GRPC_ENDPOINT}|g" \
    -e "s|__OS_FORWARD_TO__|${OS_FORWARD_TO}|g" \
    "${ALLOY_CONFIG_FILE}"
  rm -f "${ALLOY_CONFIG_FILE}.bak"

  # =============================================================================
  # app 클러스터: 메트릭 수집 (kubelet + cAdvisor → Thanos)
  # =============================================================================
  if [[ "${ENABLE_METRICS}" == "true" ]]; then
    # double-quoted heredoc: bash 변수 ${THANOS_REMOTE_WRITE_URL}, ${CLUSTER} 확장
    # Alloy regex 캡처그룹 참조는 \$1 로 이스케이프
    cat >> "${ALLOY_CONFIG_FILE}" <<METRICS_BLOCK

// ---------------------------------------------------------------------------
// Metrics Collection: Kubernetes → Thanos (App Clusters Only)
// ---------------------------------------------------------------------------
discovery.kubernetes "nodes" {
  role = "node"
}

discovery.relabel "kubelet" {
  targets = discovery.kubernetes.nodes.targets

  rule {
    action = "labelmap"
    regex  = "__meta_kubernetes_node_label_(.+)"
  }
  rule {
    target_label = "__address__"
    replacement  = "kubernetes.default.svc:443"
  }
  rule {
    source_labels = ["__meta_kubernetes_node_name"]
    regex         = "(.+)"
    target_label  = "__metrics_path__"
    replacement   = "/api/v1/nodes/\$1/proxy/metrics"
  }
}

prometheus.scrape "kubelet" {
  targets         = discovery.relabel.kubelet.output
  job_name        = "kubelet"
  scheme          = "https"
  scrape_interval = "30s"
  tls_config {
    ca_file              = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    insecure_skip_verify = true
  }
  bearer_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
  forward_to        = [prometheus.remote_write.thanos.receiver]
}

discovery.relabel "cadvisor" {
  targets = discovery.kubernetes.nodes.targets

  rule {
    action = "labelmap"
    regex  = "__meta_kubernetes_node_label_(.+)"
  }
  rule {
    target_label = "__address__"
    replacement  = "kubernetes.default.svc:443"
  }
  rule {
    source_labels = ["__meta_kubernetes_node_name"]
    regex         = "(.+)"
    target_label  = "__metrics_path__"
    replacement   = "/api/v1/nodes/\$1/proxy/metrics/cadvisor"
  }
}

prometheus.scrape "cadvisor" {
  targets         = discovery.relabel.cadvisor.output
  job_name        = "cadvisor"
  scheme          = "https"
  scrape_interval = "30s"
  tls_config {
    ca_file              = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    insecure_skip_verify = true
  }
  bearer_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
  forward_to        = [prometheus.remote_write.thanos.receiver]
}

prometheus.remote_write "thanos" {
  endpoint {
    url = "${THANOS_REMOTE_WRITE_URL}"
    queue_config {
      max_samples_per_send = 1000
      batch_send_deadline  = "30s"
    }
  }
  external_labels = {
    cluster = "${CLUSTER}",
  }
}
METRICS_BLOCK
  fi

  # =============================================================================
  # OpenSearch dual-write 파이프라인 추가 (선택적)
  # loki.source.kubernetes → otelcol.receiver.loki (bridge)
  #   → otelcol.processor.filter (security 네임스페이스만)
  #   → otelcol.exporter.elasticsearch (OpenSearch)
  # =============================================================================
  if [[ "${ENABLE_OPENSEARCH}" == "true" ]]; then
    cat >> "${ALLOY_CONFIG_FILE}" <<OPENSEARCH_BLOCK

// ---------------------------------------------------------------------------
// OpenSearch Dual-Write Pipeline (Security & Audit Logs)
// Loki format → OTLP bridge → filter → OpenSearch
// ---------------------------------------------------------------------------

// Bridge: Loki log format → OTLP logs (in-process, no HTTP port needed)
otelcol.receiver.loki "os_bridge" {
  forward_to = [otelcol.processor.filter.security.input]
}

// Filter: 보안/감사 관련 네임스페이스 로그만 OpenSearch로 전송
// Drop condition: namespace가 보안 관련이 아닌 경우 제외
otelcol.processor.filter "security" {
  error_mode = "ignore"
  logs {
    log_record = [
      "not IsMatch(attributes[\"namespace\"], \"security|kube-system|istio-system|audit|cert-manager|vault\")",
    ]
  }
  output {
    logs = [otelcol.exporter.elasticsearch.opensearch.input]
  }
}

// Export: OpenSearch (Elasticsearch 호환 API)
otelcol.exporter.elasticsearch "opensearch" {
  endpoints = ["${OPENSEARCH_URL}"]
  index     = "logs-${CLUSTER}"
  logs_dynamic_index {
    enabled = true
  }
  retry {
    enabled         = true
    max_requests    = 3
    initial_interval = "1s"
    max_interval    = "30s"
  }
}
OPENSEARCH_BLOCK
  fi

  # =============================================================================
  # Helm으로 Alloy 설치
  # =============================================================================
  $(get_helm_cmd "${CLUSTER}") upgrade --install alloy grafana/alloy \
    --namespace "${NAMESPACE_OBSERVABILITY}" \
    --set controller.type=daemonset \
    --set-file alloy.configMap.content="${ALLOY_CONFIG_FILE}" \
    --set alloy.resources.requests.memory=128Mi \
    --set alloy.resources.requests.cpu=50m \
    --set alloy.resources.limits.memory=256Mi \
    --set alloy.resources.limits.cpu=200m \
    --set rbac.create=true \
    --set serviceAccount.create=true \
    --set controller.priorityClassName=platform-normal \
    --wait --timeout 180s

  rm -f "${ALLOY_CONFIG_FILE}"
  echo "Alloy installed on ${CLUSTER}."
done

# =============================================================================
# Istio 트레이싱 통합 (Alloy로 업데이트)
# =============================================================================
echo ""
echo "=== Updating Istio tracing configuration to use Alloy ==="

for CLUSTER in mgmt app1; do
  if ! $(get_kubectl_cmd "${CLUSTER}") get namespace istio-system &>/dev/null; then
    echo "Istio not installed on ${CLUSTER}, skipping."
    continue
  fi

  echo "Configuring Istio tracing on ${CLUSTER}..."
  ALLOY_OTLP_ENDPOINT="alloy.${NAMESPACE_OBSERVABILITY}.svc.cluster.local"

  $(get_kubectl_cmd "${CLUSTER}") apply -f - <<EOF
apiVersion: telemetry.istio.io/v1alpha1
kind: Telemetry
metadata:
  name: alloy-tracing
  namespace: istio-system
spec:
  tracing:
  - providers:
    - name: alloy-otel
    randomSamplingPercentage: 10
EOF

  echo "NOTE: Istio MeshConfig에 extensionProvider 수동 추가 필요:"
  echo "  $(get_kubectl_cmd "${CLUSTER}") -n istio-system edit configmap istio"
  echo "  meshConfig.extensionProviders 에 추가:"
  echo "    - name: alloy-otel"
  echo "      opentelemetry:"
  echo "        service: ${ALLOY_OTLP_ENDPOINT}"
  echo "        port: 4317"
done

# =============================================================================
# 설치 요약
# =============================================================================
echo ""
echo "================================================================="
echo "  Grafana Alloy Installation Summary"
echo "================================================================="
echo "  [OK] Alloy DaemonSet - 전 클러스터:${NAMESPACE_OBSERVABILITY}"
echo ""
echo "  통합 대상:"
echo "    ✅ Promtail        → loki.source.kubernetes (로그)"
echo "    ✅ OTel Collector  → otelcol.receiver.otlp (트레이스)"
echo "    ✅ Prometheus Agent→ prometheus.scrape (메트릭, app 클러스터)"
if [[ -n "${OPENSEARCH_LB_IP}" ]]; then
echo ""
echo "  OpenSearch dual-write:"
echo "    ✅ security|kube-system|istio-system 로그 → OpenSearch (${OPENSEARCH_LB_IP})"
fi
echo "================================================================="
echo ""
echo "검증:"
CLUSTERS=$(jq -r 'keys[]' "${CLUSTERS_JSON}")
for CLUSTER in ${CLUSTERS}; do
  echo "  $(get_kubectl_cmd "${CLUSTER}") -n ${NAMESPACE_OBSERVABILITY} get daemonset alloy"
done
echo ""
echo "로그 확인 (Grafana):"
echo "  $(get_kubectl_cmd mgmt) -n ${NAMESPACE_MONITORING} port-forward svc/kube-prometheus-stack-grafana 3000:80"
echo "  → Explore → Loki → {cluster=\"app1\"}"

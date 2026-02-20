#!/bin/bash

# 모든 주요 WebUI 서비스를 한 번에 port-forward
# Ctrl+C로 모두 종료

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="${SCRIPT_DIR}/../generated"
KUBECONFIG_MULTI="${GENERATED_DIR}/kubeconfig-multi"

if [[ ! -f "${KUBECONFIG_MULTI}" ]]; then
  echo "ERROR: kubeconfig-multi not found"
  exit 1
fi

export KUBECONFIG="${KUBECONFIG_MULTI}"
CONTEXT="kubernetes-admin@mgmt"

echo "========================================="
echo "Starting Port-Forward for All Services"
echo "========================================="
echo ""

# Cleanup function
cleanup() {
  echo ""
  echo "Stopping all port-forwards..."
  jobs -p | xargs kill 2>/dev/null
  exit 0
}

trap cleanup SIGINT SIGTERM

# Grafana
kubectl port-forward --context "${CONTEXT}" -n observability svc/kube-prometheus-stack-grafana 3000:80 &
sleep 1

# Prometheus
kubectl port-forward --context "${CONTEXT}" -n observability svc/kube-prometheus-stack-prometheus 9090:9090 &
sleep 1

# AlertManager
kubectl port-forward --context "${CONTEXT}" -n observability svc/kube-prometheus-stack-alertmanager 9093:9093 &
sleep 1

# ArgoCD
kubectl port-forward --context "${CONTEXT}" -n argocd svc/argocd-server 8080:443 &
sleep 1

# Kiali
kubectl port-forward --context "${CONTEXT}" -n istio-system svc/kiali 20001:20001 &
sleep 1

# Vault UI
kubectl port-forward --context "${CONTEXT}" -n vault svc/vault-ui 8200:8200 &
sleep 1

# Tempo
kubectl port-forward --context "${CONTEXT}" -n observability svc/tempo 3100:3100 &
sleep 1

# Thanos Query
kubectl port-forward --context "${CONTEXT}" -n observability svc/thanos-query 9091:9090 &
sleep 1

# MinIO Console (LoadBalancer이지만 port-forward도 가능)
kubectl port-forward --context "${CONTEXT}" -n backup svc/minio 9001:9001 &
sleep 1

echo ""
echo "========================================="
echo "✅ All port-forwards started!"
echo "========================================="
echo ""
echo "Services available at:"
echo "  Grafana:      http://localhost:3000       (admin/admin)"
echo "  Prometheus:   http://localhost:9090"
echo "  AlertManager: http://localhost:9093"
echo "  ArgoCD:       https://localhost:8080      (admin/[secret])"
echo "  Kiali:        http://localhost:20001"
echo "  Vault UI:     http://localhost:8200       ([root-token])"
echo "  Tempo:        http://localhost:3100"
echo "  Thanos Query: http://localhost:9091"
echo "  MinIO Console: http://localhost:9001      (minioadmin/minioadmin123)"
echo ""
echo "========================================="
echo ""
echo "Press Ctrl+C to stop all port-forwards"
echo ""

# Wait for user interrupt
wait

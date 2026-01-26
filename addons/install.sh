#!/bin/bash
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo add argo https://argoproj.github.io/argo-helm
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo add kiali https://kiali.org/helm-charts
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo add metallb https://metallb.github.io/metallb
helm repo add containeroo https://charts.containeroo.ch
helm repo update

# MetalLB
helm upgrade --install metallb metallb/metallb -n metallb-system --create-namespace
sleep 40 #Wait for metalLB
kubectl apply -f values/metallb/metallb-config.yaml

# 로컬 동적 프로바이더
helm upgrade --install my-local-path-provisioner containeroo/local-path-provisioner --version 0.0.22 -n local-path-storage --create-namespace --values values/rancher/local-path.yaml
# Istio
helm upgrade --install istio-base istio/base -n istio-system --create-namespace -f values/istio/istio-values.yaml
helm upgrade --install istiod istio/istiod -n istio-system -f values/istio/istio-values.yaml
helm upgrade --install istio-ingress istio/gateway -n istio-ingress --create-namespace -f values/istio/istio-values.yaml

# ArgoCD
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace -f values/argocd/argocd-values.yaml

# Monitoring
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring --create-namespace -f values/monitoring/monitoring-values.yaml

# Logging
helm upgrade --install loki grafana/loki-stack -n logging --create-namespace -f values/logging/loki-values.yaml
helm upgrade --install promtail grafana/promtail -n logging --create-namespace -f values/logging/promtail-values.yaml

# Tracing
helm upgrade --install jaeger jaegertracing/jaeger -n tracing --create-namespace -f values/tracing/jaeger-values.yaml
helm upgrade --install otel open-telemetry/opentelemetry-collector -n tracing -f values/tracing/otel-values.yaml
helm upgrade --install kiali kiali/kiali-server -n istio-system -f values/tracing/kiali-values.yaml

# Vault
helm upgrade --install vault hashicorp/vault -n vault --create-namespace -f values/vault/vault-values.yaml

# --- LoadBalancer IP to /etc/hosts mapping ---
echo "[INFO] Waiting for LoadBalancer IPs to be assigned..."
#sleep 60  # Wait for IPs to be assigned

HOSTS_FILE="./hosts.generated"
echo "" > "$HOSTS_FILE"

# DOMAIN:SERVICE.NAMESPACE
SERVICE_MAP="argocd.bocopile.io:argocd-server.argocd grafana.bocopile.io:kube-prometheus-stack-grafana.monitoring jaeger.bocopile.io:jaeger-query.tracing kiali.bocopile.io:kiali.istio-system vault.bocopile.io:vault.vault "

for entry in $SERVICE_MAP; do
  domain=${entry%%:*}
  svc_ns=${entry##*:}
  svc_name=${svc_ns%%.*}
  svc_ns_only=${svc_ns##*.}
  ip=$(kubectl get svc -n "$svc_ns_only" "$svc_name" -o jsonpath="{.status.loadBalancer.ingress[0].ip}")
  if [[ -n "$ip" ]]; then
    echo "$ip $domain" >> "$HOSTS_FILE"
    echo "[OK] $domain -> $ip"
  else
    echo "[WARN] No IP found for $domain"
  fi
done

echo ""
echo "[INFO] Generated $HOSTS_FILE with current LoadBalancer IP mappings."
echo "[INFO] To apply, run: sudo cp $HOSTS_FILE /etc/hosts"

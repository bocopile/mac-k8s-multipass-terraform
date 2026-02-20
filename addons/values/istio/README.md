# Istio Configuration

> **Service Mesh via istioctl (not Helm)**

Istio is installed using `istioctl` with IstioOperator CRD, not Helm charts.

---

## 📁 Configuration Files

| File | Purpose | Target Cluster |
|------|---------|---------------|
| `istio-operator-mgmt.yaml` | Gateway only, no sidecar injection | mgmt |
| `istio-operator-app.yaml` | Full mesh with sidecar injection | app1, app2 |

---

## 🚀 Installation

### mgmt Cluster (Gateway only)

```bash
istioctl install \
  --context kubernetes-admin@mgmt \
  --kubeconfig generated/kubeconfig-multi \
  -f addons/values/istio/istio-operator-mgmt.yaml \
  --skip-confirmation
```

**Features**:
- ✅ Ingress Gateway (LoadBalancer)
- ✅ Istiod (control plane)
- ❌ Sidecar injection (disabled)
- **Use case**: External access to platform services (Grafana, ArgoCD)

### app1/app2 Clusters (Full Mesh)

```bash
# app1
istioctl install \
  --context kubernetes-admin@app1 \
  --kubeconfig generated/kubeconfig-multi \
  -f addons/values/istio/istio-operator-app.yaml \
  --set values.global.meshID=mesh-app1 \
  --set values.global.multiCluster.clusterName=app1 \
  --skip-confirmation

# app2
istioctl install \
  --context kubernetes-admin@app2 \
  --kubeconfig generated/kubeconfig-multi \
  -f addons/values/istio/istio-operator-app.yaml \
  --set values.global.meshID=mesh-app2 \
  --set values.global.multiCluster.clusterName=app2 \
  --skip-confirmation
```

**Features**:
- ✅ Ingress Gateway
- ✅ Istiod
- ✅ Sidecar injection (automatic for all namespaces)
- ✅ mTLS (Mutual TLS)
- **Use case**: Production-grade traffic management, observability, security

---

## 🔧 Sidecar Injection Control

### Enable injection for a namespace

```bash
kubectl label namespace default istio-injection=enabled
```

### Disable injection for a namespace

```bash
kubectl label namespace kube-system istio-injection=disabled
```

### Verify injection

```bash
kubectl get namespace -L istio-injection
```

---

## 📊 Key Configuration Differences

| Setting | mgmt | app1/app2 |
|---------|------|-----------|
| **Sidecar Injection** | Disabled | Enabled (default) |
| **Profile** | default | default |
| **Ingress Gateway** | LoadBalancer | LoadBalancer |
| **Egress Gateway** | Disabled | Disabled |
| **CNI Mode** | Chained (Cilium) | Chained (Cilium) |
| **Mesh ID** | mesh-mgmt | mesh-app1, mesh-app2 |
| **Access Logs** | JSON to stdout | JSON to stdout |

---

## 🔐 mTLS Configuration

### Enforce strict mTLS (app clusters)

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
```

Apply:
```bash
kubectl apply -f mtls-strict.yaml --context kubernetes-admin@app1
```

---

## 🌐 Gateway Configuration

### Create Gateway for external traffic

```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: grafana-gateway
  namespace: monitoring
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - grafana.local
```

### Create VirtualService

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: grafana
  namespace: monitoring
spec:
  hosts:
    - grafana.local
  gateways:
    - grafana-gateway
  http:
    - route:
        - destination:
            host: kube-prometheus-stack-grafana
            port:
              number: 80
```

---

## 📚 References

- [Istio Documentation](https://istio.io/latest/docs/)
- [IstioOperator API](https://istio.io/latest/docs/reference/config/istio.operator.v1alpha1/)
- [Istio + Cilium Integration](https://istio.io/latest/docs/setup/additional-setup/cni/)
- [Multi-Cluster Setup](https://istio.io/latest/docs/setup/install/multicluster/)

---

## ⚠️ Important Notes

### 1. Cilium Integration

Istio CNI is configured to chain with Cilium:
- `cni.enabled: true`
- `cni.chained: true`
- `ISTIO_META_DNS_CAPTURE: "false"` (let Cilium handle DNS)

### 2. Resource Usage

Per-pod sidecar overhead:
- CPU: 50m (request) → 200m (limit)
- Memory: 128Mi (request) → 256Mi (limit)

**Example**: 10 pods = +500m CPU, +1.3Gi RAM

### 3. Upgrades

Always use `istioctl` for upgrades:

```bash
# Check current version
istioctl version

# Download new version
curl -L https://istio.io/downloadIstio | sh -

# Upgrade
istioctl upgrade -f istio-operator-mgmt.yaml
```

---

**Version**: Istio 1.29.0 (compatible with Kubernetes 1.35)
**Last Updated**: 2026-02-20

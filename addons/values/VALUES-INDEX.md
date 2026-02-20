# Addon Values Files Index

> **Values 파일 생성 현황**
>
> Last Updated: 2026-02-20

---

## ✅ 생성 완료 (19개 + 6개 config files)

### Helm Values Files

| Addon | Values File | Chart | Status |
|-------|------------|-------|--------|
| Vault | `vault/vault-values.yaml` | hashicorp/vault | ✅ Created |
| ArgoCD | `argocd/argocd-values.yaml` | argo/argo-cd | ✅ Created |
| Prometheus Stack | `prometheus/prometheus-stack-values.yaml` | prometheus-community/kube-prometheus-stack | ✅ Created |
| Prometheus Agent | `prometheus/prometheus-agent-values.yaml` | prometheus-community/kube-prometheus-stack | ✅ Created |
| Loki | `loki/loki-values.yaml` | grafana/loki | ✅ Created |
| Thanos | `thanos/thanos-values.yaml` | bitnami/thanos | ✅ Created |
| Kyverno | `kyverno/kyverno-values.yaml` | kyverno/kyverno | ✅ Created |
| MinIO | `minio/minio-values.yaml` | bitnami/minio | ✅ Created |
| cert-manager | `cert-manager/cert-manager-values.yaml` | jetstack/cert-manager | ✅ Created |
| External Secrets | `eso/eso-values.yaml` | external-secrets/external-secrets | ✅ Created |
| Velero | `velero/velero-values.yaml` | vmware-tanzu/velero | ✅ Created |
| Tetragon | `tetragon/tetragon-values.yaml` | cilium/tetragon | ✅ Created |
| Tempo | `tempo/tempo-values.yaml` | grafana/tempo | ✅ Created |
| OpenTelemetry | `otel/otel-collector-values.yaml` | open-telemetry/opentelemetry-collector | ✅ Created |
| Kiali | `kiali/kiali-values.yaml` | kiali/kiali-operator | ✅ Created |
| Falco | `falco/falco-values.yaml` | falcosecurity/falco | ✅ Created |
| K8sGPT Operator | `k8sgpt/k8sgpt-operator-values.yaml` | k8sgpt/k8sgpt-operator | ✅ Created |
| Robusta (HolmesGPT) | `robusta/robusta-values.yaml` | robusta/robusta | ✅ Created |
| Botkube | `botkube/botkube-values.yaml` | botkube/botkube | ✅ Created |

### Configuration Files (CRD/IstioOperator)

| Addon | Config File | Type | Status |
|-------|------------|------|--------|
| MetalLB | `metallb/metallb-config.yaml` | IPAddressPool + L2Advertisement CRD | ✅ Created |
| cert-manager | `cert-manager/clusterissuers.yaml` | ClusterIssuer CRD | ✅ Created |
| External Secrets | `eso/clustersecretstore.yaml` | ClusterSecretStore CRD | ✅ Created |
| Istio (mgmt) | `istio/istio-operator-mgmt.yaml` | IstioOperator | ✅ Created |
| Istio (app) | `istio/istio-operator-app.yaml` | IstioOperator | ✅ Created |
| Velero | `velero/schedules.yaml` | Schedule CRD | ✅ Created |

---

## 🚫 Values 파일 불필요 (Non-Helm Addons)

| Addon | 설치 방식 | 설명 |
|-------|---------|------|
| Cilium | `cilium install` CLI | Helm Chart 사용 가능하나 CLI 권장 |
| Gateway API | `kubectl apply` | CRD만 설치 (Helm 불필요) |
| Cluster Mesh | `cilium clustermesh` CLI | Cilium CLI 기능 |
| Vault PKI | `kubectl exec` + Vault CLI | 스크립트 기반 설정 |
| Platform Addons | 여러 Helm Chart 조합 | 개별 addon별로 values 관리 |

---

## 📊 생성 우선순위

### 🔴 High Priority (필수, 자주 커스터마이징)

1. **MetalLB** - IP pool 설정이 환경마다 다름
2. **cert-manager** - ClusterIssuer 설정 필요
3. **External Secrets** - Vault 연동 설정
4. **Prometheus Agent** - remote_write 엔드포인트 설정
5. **Istio (3개)** - Service Mesh 설정이 복잡
6. **Velero** - Backup 위치 및 스케줄 설정

### 🟡 Medium Priority (커스터마이징 가능성 있음)

1. **Tetragon** - 보안 정책 설정
2. **Tempo** - Trace retention 설정
3. **OpenTelemetry** - Exporter 설정
4. **Kiali** - Service Mesh 대시보드 설정
5. **Falco** - Runtime security 룰 설정

### 🟢 Low Priority (기본값 사용 가능)

1. **K8sGPT** - LocalAI 연동만 설정하면 됨
2. **Robusta** - 기본 설정으로 충분
3. **Botkube** - Slack 토큰만 설정

---

## 📝 다음 단계

### 1. High Priority Values 파일 생성

```bash
# MetalLB
cat > addons/values/metallb/metallb-values.yaml

# cert-manager
cat > addons/values/cert-manager/cert-manager-values.yaml

# External Secrets
cat > addons/values/eso/eso-values.yaml

# Istio
cat > addons/values/istio/istio-base-values.yaml
cat > addons/values/istio/istiod-values.yaml
cat > addons/values/istio/istio-ingress-values.yaml

# Velero
cat > addons/values/velero/velero-values.yaml
```

### 2. Install 스크립트 수정

```bash
# Before
helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  --set server.dataStorage.size=10Gi \
  --set server.resources.requests.memory=256Mi

# After
helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  -f addons/values/vault/vault-values.yaml
```

### 3. 환경별 Values 파일 추가

```bash
# Development (기본)
addons/values/vault/vault-values.yaml

# Production
addons/values/vault/vault-prod-values.yaml
```

---

## 🔗 관련 문서

- [README.md](README.md) - Values 파일 사용 가이드
- [../scripts/](../scripts/) - Addon 설치 스크립트
- [../README.md](../README.md) - Addon 전체 문서

---

**생성 완료**: 19 / 19 Helm-based addons (100%) ✅
**총 파일 수**: 25 files (19 Helm values + 6 config/CRD files)

---

## ✅ High Priority 완료 (6/6)

1. ✅ MetalLB - IP pool configuration template (CRD)
2. ✅ cert-manager - Values + ClusterIssuer templates (self-signed + Vault)
3. ✅ External Secrets - Values + ClusterSecretStore template
4. ✅ Prometheus Agent - Remote write to Thanos configuration
5. ✅ Istio (2 files + README) - mgmt + app IstioOperator configurations
6. ✅ Velero - Values + backup schedule templates

## ✅ Medium Priority 완료 (5/5)

1. ✅ Tetragon - eBPF security observability with TracingPolicy support
2. ✅ Tempo - Distributed tracing with OTLP/Jaeger/Zipkin receivers
3. ✅ OpenTelemetry - Unified observability collector (metrics, logs, traces)
4. ✅ Kiali - Istio service mesh dashboard with Prometheus/Grafana/Tempo integration
5. ✅ Falco - Runtime security with custom rules and Falcosidekick

## ✅ Low Priority 완료 (3/3)

1. ✅ K8sGPT Operator - AI-powered Kubernetes diagnostics with LocalAI integration
2. ✅ Robusta (HolmesGPT) - AI incident response with automated playbooks
3. ✅ Botkube - ChatOps for Kubernetes with Slack/Teams/Discord support

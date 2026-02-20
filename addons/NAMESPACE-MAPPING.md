# Namespace Mapping Quick Reference

> **빠른 참조**: 현재 → 제안 namespace 매핑

---

## 📊 mgmt Cluster

| Addon | 현재 | 제안 | 상태 | 비고 |
|-------|------|------|------|------|
| **Observability Stack** |||||
| Prometheus Stack | `monitoring` | `observability` | 🔄 Rename | 또는 monitoring 유지 |
| Loki | `loki` | `observability` | ✨ Move | |
| Thanos | `thanos` | `observability` | ✨ Move | |
| Tempo | `monitoring` | `observability` | ✨ Move | |
| OTel Collector | `monitoring` | `observability` | ✨ Move | |
| Promtail | `promtail` | `observability` | ✨ Move | |
| **Service Mesh** |||||
| Istio | `istio-system` | `istio-system` | ✅ Keep | 표준 위치 |
| Kiali | `istio-system` | `istio-system` | ✅ Keep | |
| **Security & Secrets** |||||
| Vault | `vault` | `vault` | ✅ Keep | 격리 유지 |
| External Secrets | `external-secrets` | `security` | ✨ Move | mgmt에는 설치 안 함 |
| **GitOps** |||||
| ArgoCD | `argocd` | `argocd` | ✅ Keep | 표준 위치 |
| **AI Operations** |||||
| K8sGPT Operator | `k8sgpt` | `aiops` | ✨ Move | |
| LocalAI | `localai` | `aiops` | ✨ Move | |
| Robusta (HolmesGPT) | `robusta` | `aiops` | ✨ Move | |
| Botkube | `botkube` | `aiops` | ✨ Move | |
| **Backup & Storage** |||||
| Velero | `velero` | `backup` | ✨ Move | |
| MinIO | `minio` | `backup` | ✨ Move | |
| **Platform Tools** |||||
| OpenCost | `opencost` | `platform-tools` | ✨ Move | |
| VPA | `vpa` | `platform-tools` | ✨ Move | |
| Goldilocks | `goldilocks` | `platform-tools` | ✨ Move | |
| Chaos Mesh | `chaos-mesh` | `platform-tools` | ✨ Move | |
| Trivy Operator | `trivy-system` | `platform-tools` | ✨ Move | |
| **Infrastructure** |||||
| cert-manager | `cert-manager` | `cert-manager` | ✅ Keep | 표준 위치 |
| Tetragon | `kube-system` | `kube-system` | ✅ Keep | System addon |
| MetalLB | `metallb-system` | `kube-system` | 🔄 Optional | 또는 metallb-system 유지 |

**Summary**: 22 namespaces → **9 namespaces** (59% 감소)

---

## 📊 app1/app2 Clusters

| Addon | 현재 | 제안 | 상태 | 비고 |
|-------|------|------|------|------|
| **Observability** |||||
| Prometheus Agent | `monitoring` | `observability` | 🔄 Rename | 또는 monitoring 유지 |
| OTel Collector | `monitoring` | `observability` | ✨ Move | |
| Promtail | `promtail` | `observability` | ✨ Move | |
| **Service Mesh** |||||
| Istio | `istio-system` | `istio-system` | ✅ Keep | 표준 위치 |
| Kiali | `istio-system` | `istio-system` | ✅ Keep | |
| **Security** |||||
| External Secrets | `external-secrets` | `security` | ✨ Move | |
| Kyverno | `kyverno` | `security` | ✨ Move | |
| Falco | `falco` | `security` | ✨ Move | |
| **Backup** |||||
| Velero | `velero` | `backup` | ✨ Move | |
| **Infrastructure** |||||
| cert-manager | `cert-manager` | `cert-manager` | ✅ Keep | 표준 위치 |
| Tetragon | `kube-system` | `kube-system` | ✅ Keep | System addon |
| MetalLB | `metallb-system` | `kube-system` | 🔄 Optional | 또는 metallb-system 유지 |

**Summary**: 10 namespaces → **6 namespaces** (40% 감소)

---

## 🎨 Namespace 색상 코드 (Lens/K9s)

```yaml
# Lens/K9s namespace colors
observability: blue       # 관측성
security: red            # 보안
aiops: purple            # AI 운영
backup: orange           # 백업
platform-tools: green    # 플랫폼 도구
istio-system: cyan       # Service Mesh
argocd: yellow           # GitOps
vault: magenta           # Secrets
cert-manager: gray       # 인증서
kube-system: white       # 시스템
```

---

## 📝 스크립트 변경 예시

### Before (현재)

```bash
# install-loki.sh
helm upgrade --install loki grafana/loki \
  --namespace loki \
  --create-namespace \
  -f addons/values/loki/loki-values.yaml

# install-thanos.sh
helm upgrade --install thanos bitnami/thanos \
  --namespace thanos \
  --create-namespace \
  -f addons/values/thanos/thanos-values.yaml

# install-k8sgpt.sh
kubectl create namespace k8sgpt
kubectl create namespace localai
# ... 2개 namespace 사용
```

### After (제안)

```bash
# install-loki.sh
helm upgrade --install loki grafana/loki \
  --namespace observability \
  --create-namespace \
  -f addons/values/loki/loki-values.yaml

# install-thanos.sh
helm upgrade --install thanos bitnami/thanos \
  --namespace observability \
  --create-namespace \
  -f addons/values/thanos/thanos-values.yaml

# install-k8sgpt.sh
kubectl create namespace aiops
# LocalAI도 같은 namespace 사용
```

---

## 🔧 Values 파일 변경 예시

### prometheus-stack-values.yaml

```yaml
# Before
additionalDataSources:
  - name: Loki
    type: loki
    url: http://loki-gateway.loki.svc:3100
  - name: Tempo
    type: tempo
    url: http://tempo.monitoring.svc:3100

# After
additionalDataSources:
  - name: Loki
    type: loki
    url: http://loki-gateway.observability.svc:3100
  - name: Tempo
    type: tempo
    url: http://tempo.observability.svc:3100
```

### otel-collector-values.yaml

```yaml
# Before
exporters:
  loki:
    endpoint: http://loki-gateway.loki.svc/loki/api/v1/push
  otlp/tempo:
    endpoint: tempo.monitoring.svc:4317

# After
exporters:
  loki:
    endpoint: http://loki-gateway.observability.svc/loki/api/v1/push
  otlp/tempo:
    endpoint: tempo.observability.svc:4317
```

### k8sgpt-operator-values.yaml

```yaml
# Before (CR)
spec:
  localAI:
    url: http://localai.localai.svc:8080

# After (CR)
spec:
  localAI:
    url: http://localai.aiops.svc:8080
```

### velero-values.yaml

```yaml
# Before
configuration:
  backupStorageLocation:
    - config:
        s3Url: http://minio.minio.svc:9000

# After
configuration:
  backupStorageLocation:
    - config:
        s3Url: http://minio.backup.svc:9000
```

---

## 🚦 적용 방법 선택

### Option 1: 즉시 전체 적용 (Aggressive)

```bash
# 모든 addon 삭제
bash addons/uninstall.sh --all

# 스크립트 일괄 수정
sed -i '' 's/--namespace loki/--namespace observability/g' addons/scripts/install-loki.sh
sed -i '' 's/--namespace thanos/--namespace observability/g' addons/scripts/install-thanos.sh
# ... (반복)

# Values 파일 일괄 수정
sed -i '' 's/loki\.svc/observability.svc/g' addons/values/**/*.yaml
# ... (반복)

# 재설치
bash addons/install.sh --all
```

**소요 시간**: 30분 (삭제 + 수정 + 재설치)
**리스크**: 높음 (모든 데이터 손실)

---

### Option 2: 점진적 적용 (Conservative)

```bash
# Week 1: Observability 통합
bash addons/uninstall.sh loki thanos promtail
# 스크립트 수정
bash addons/install.sh loki thanos promtail

# Week 2: AIOps 통합
bash addons/uninstall.sh k8sgpt holmesgpt botkube
# 스크립트 수정
bash addons/install.sh k8sgpt holmesgpt botkube

# Week 3: Platform Tools 통합
# ... (계속)
```

**소요 시간**: 3주 (주당 1-2시간)
**리스크**: 낮음 (단계별 검증)

---

### Option 3: 신규 클러스터만 적용 (Safest)

```bash
# 기존 클러스터: AS-IS 유지
# 신규 클러스터: TO-BE 적용

# .env 파일에 버전 플래그 추가
NAMESPACE_VERSION=v2  # v1 (legacy) or v2 (consolidated)

# 스크립트에서 조건부 처리
if [ "$NAMESPACE_VERSION" = "v2" ]; then
  NAMESPACE="observability"
else
  NAMESPACE="loki"
fi
```

**소요 시간**: 초기 설정 2시간, 이후 0시간
**리스크**: 없음 (기존 환경 영향 없음)

---

## 🎯 권장 사항

### 현재 환경이 개발/테스트 환경인 경우

→ **Option 1 (즉시 전체 적용)** 추천
- 데이터 손실 영향 낮음
- 빠른 구조 개선

### 현재 환경이 운영 환경인 경우

→ **Option 2 (점진적 적용)** 추천
- 단계별 검증 가능
- 롤백 계획 수립 가능

### 기존 환경을 건드리고 싶지 않은 경우

→ **Option 3 (신규 클러스터만)** 추천
- Zero risk
- 향후 표준으로 활용

---

## 📋 체크리스트

적용 전 확인 사항:

- [ ] 현재 namespace 구조 백업 (`kubectl get ns -o yaml > namespaces-backup.yaml`)
- [ ] 모든 addon values 파일 백업
- [ ] PersistentVolume 데이터 백업 (Loki, Thanos, MinIO)
- [ ] 스크립트 변경 사항 Git commit
- [ ] Values 파일 변경 사항 Git commit
- [ ] Rollback 계획 수립
- [ ] 테스트 환경에서 먼저 검증

적용 후 검증:

- [ ] 모든 Pod이 Running 상태인지 확인
- [ ] Service 간 통신 정상 동작 확인 (Grafana → Loki/Tempo)
- [ ] Prometheus가 모든 target을 scrape하는지 확인
- [ ] External Secrets가 Vault에서 secret을 가져오는지 확인
- [ ] Velero가 MinIO에 백업을 저장하는지 확인
- [ ] AI tools가 LocalAI와 통신하는지 확인

---

**Last Updated**: 2026-02-20

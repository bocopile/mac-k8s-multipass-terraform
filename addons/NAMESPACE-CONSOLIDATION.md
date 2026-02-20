# Namespace Consolidation Plan

> **현재 문제점**: 25+ 개의 개별 namespace로 분산되어 관리 복잡도 증가
>
> **목표**: 기능별로 namespace를 그룹화하여 관리 효율성 향상

---

## 📊 현재 Namespace 구조 (AS-IS)

### mgmt Cluster (22개 namespace)

| Namespace | Addons | 비고 |
|-----------|--------|------|
| `monitoring` | prometheus-stack, tempo, otel-collector | ✅ 이미 통합됨 |
| `istio-system` | istio, kiali | ✅ 이미 통합됨 |
| `vault` | vault | 단독 |
| `argocd` | argocd | 단독 |
| `loki` | loki | 단독 |
| `thanos` | thanos | 단독 |
| `minio` | minio | 단독 |
| `cert-manager` | cert-manager | 단독 |
| `external-secrets` | eso | 단독 |
| `k8sgpt` | k8sgpt-operator | 단독 |
| `localai` | localai | 단독 |
| `robusta` | holmesgpt | 단독 |
| `botkube` | botkube | 단독 |
| `velero` | velero | 단독 |
| `trivy-system` | trivy-operator | 단독 |
| `opencost` | opencost | 단독 |
| `vpa` | vpa | 단독 |
| `goldilocks` | goldilocks | 단독 |
| `chaos-mesh` | chaos-mesh | 단독 |
| `kube-system` | tetragon | Kubernetes core |
| `metallb-system` | metallb | 시스템 addon |
| `promtail` | promtail | 단독 |

### app1/app2 Clusters (10개 namespace)

| Namespace | Addons | 비고 |
|-----------|--------|------|
| `monitoring` | prometheus-agent, otel-collector | ✅ 이미 통합됨 |
| `istio-system` | istio, kiali | ✅ 이미 통합됨 |
| `cert-manager` | cert-manager | 단독 |
| `external-secrets` | eso | 단독 |
| `kyverno` | kyverno | 단독 |
| `falco` | falco | 단독 |
| `velero` | velero | 단독 |
| `kube-system` | tetragon | Kubernetes core |
| `metallb-system` | metallb | 시스템 addon |
| `promtail` | promtail | 단독 |

---

## 🎯 제안: 기능별 Namespace 그룹화 (TO-BE)

### mgmt Cluster (9개 namespace로 축소)

| Namespace | Addons | 목적 | 변경 사항 |
|-----------|--------|------|-----------|
| **observability** | prometheus-stack, loki, tempo, thanos, otel-collector, promtail | 통합 관측성 플랫폼 | ✨ loki, thanos, promtail 통합 |
| **istio-system** | istio, kiali | Service Mesh | ✅ 유지 |
| **security** | vault, external-secrets | Secrets 관리 | ✨ ESO를 vault와 통합 |
| **gitops** | argocd | GitOps 배포 | ✅ 유지 (argocd 표준) |
| **aiops** | k8sgpt, localai, robusta, botkube | AI 운영 자동화 | ✨ 4개 addon 통합 |
| **backup** | velero, minio | 백업 & 스토리지 | ✨ minio를 velero와 통합 |
| **platform-tools** | opencost, vpa, goldilocks, chaos-mesh, trivy-operator | 플랫폼 유틸리티 | ✨ 5개 addon 통합 |
| **cert-manager** | cert-manager | 인증서 관리 | ✅ 유지 (cluster-wide) |
| **kube-system** | tetragon, metallb | 시스템 컴포넌트 | ✨ metallb 통합 |

### app1/app2 Clusters (6개 namespace로 축소)

| Namespace | Addons | 목적 | 변경 사항 |
|-----------|--------|------|-----------|
| **observability** | prometheus-agent, otel-collector, promtail | 관측성 에이전트 | ✨ promtail 통합 |
| **istio-system** | istio, kiali | Service Mesh | ✅ 유지 |
| **security** | external-secrets, kyverno, falco | 보안 & 정책 | ✨ 3개 addon 통합 |
| **backup** | velero | 백업 | ✅ 유지 |
| **cert-manager** | cert-manager | 인증서 관리 | ✅ 유지 |
| **kube-system** | tetragon, metallb | 시스템 컴포넌트 | ✨ metallb 통합 |

---

## 📐 Namespace 설계 원칙

### ✅ 그룹화 기준

1. **기능적 연관성**: 같은 목적을 가진 컴포넌트 통합
2. **데이터 흐름**: 서로 통신하는 컴포넌트 근접 배치
3. **생명주기 동일**: 함께 설치/업그레이드/삭제되는 컴포넌트
4. **RBAC 경계**: 같은 권한 수준의 컴포넌트

### ❌ 그룹화하지 않는 경우

1. **Kubernetes 표준 위치**: cert-manager, istio-system, argocd
2. **보안 격리 필요**: vault (고립 유지)
3. **Cluster-wide 리소스**: kube-system, metallb-system
4. **다른 클러스터 배포**: mgmt-only vs all-clusters

---

## 🔄 마이그레이션 전략

### Phase 1: Observability 통합 (Low Risk)

```bash
# mgmt cluster
kubectl create namespace observability

# Loki 마이그레이션
helm uninstall loki -n loki
helm install loki grafana/loki -n observability -f addons/values/loki/loki-values.yaml

# Thanos 마이그레이션
helm uninstall thanos -n thanos
helm install thanos bitnami/thanos -n observability -f addons/values/thanos/thanos-values.yaml

# Promtail 마이그레이션 (all clusters)
helm uninstall promtail -n promtail
helm install promtail grafana/promtail -n observability -f addons/values/loki/promtail-values.yaml

# Prometheus Stack은 이미 monitoring namespace
# monitoring → observability rename (optional)
```

**영향도**: 낮음 (서비스 간 통신은 FQDN 사용, namespace 변경 영향 없음)

### Phase 2: AIOps 통합 (Low Risk)

```bash
# mgmt cluster
kubectl create namespace aiops

# K8sGPT
helm uninstall k8sgpt-operator -n k8sgpt
helm install k8sgpt-operator k8sgpt/k8sgpt-operator -n aiops

# LocalAI
kubectl delete namespace localai
kubectl apply -f addons/scripts/install-k8sgpt.sh (수정 필요)

# Robusta
helm uninstall robusta -n robusta
helm install robusta robusta/robusta -n aiops

# Botkube
helm uninstall botkube -n botkube
helm install botkube botkube/botkube -n aiops
```

**영향도**: 낮음 (독립적인 AI 도구들)

### Phase 3: Security 통합 (Medium Risk)

```bash
# app1/app2 clusters
kubectl create namespace security

# External Secrets
helm uninstall external-secrets -n external-secrets
helm install external-secrets external-secrets/external-secrets -n security

# Kyverno
helm uninstall kyverno -n kyverno
helm install kyverno kyverno/kyverno -n security

# Falco
helm uninstall falco -n falco
helm install falco falcosecurity/falco -n security
```

**영향도**: 중간 (ESO의 ClusterSecretStore는 cluster-wide이므로 영향 없음)

### Phase 4: Platform Tools 통합 (Low Risk)

```bash
# mgmt cluster
kubectl create namespace platform-tools

# OpenCost, VPA, Goldilocks, Chaos Mesh, Trivy
# (각 addon helm uninstall → helm install)
```

**영향도**: 낮음 (독립적인 도구들)

### Phase 5: Backup & Storage 통합 (Medium Risk)

```bash
# mgmt cluster
kubectl create namespace backup

# MinIO 마이그레이션
helm uninstall minio -n minio
helm install minio bitnami/minio -n backup

# Velero 재설정 (MinIO endpoint 업데이트)
# s3Url: http://minio.backup.svc:9000 (변경됨)
```

**영향도**: 중간 (Velero의 MinIO endpoint 업데이트 필요)

---

## 📋 변경 필요 파일 목록

### 1. Terraform Variables (선택사항)

현재 terraform은 VM 프로비저닝만 담당하므로 변경 불필요

### 2. Addon Install Scripts (필수)

**수정 필요 파일**: `addons/scripts/install-*.sh` (총 23개)

| Script | 현재 Namespace | 신규 Namespace | 변경 |
|--------|---------------|---------------|------|
| `install-loki.sh` | loki | observability | `--namespace loki` → `--namespace observability` |
| `install-thanos.sh` | thanos | observability | `--namespace thanos` → `--namespace observability` |
| `install-promtail.sh` | promtail | observability | `--namespace promtail` → `--namespace observability` |
| `install-k8sgpt.sh` | k8sgpt, localai | aiops | 2개 namespace → 1개 통합 |
| `install-holmesgpt.sh` | robusta | aiops | `--namespace robusta` → `--namespace aiops` |
| `install-botkube.sh` | botkube | aiops | `--namespace botkube` → `--namespace aiops` |
| `install-eso.sh` | external-secrets | security | `--namespace external-secrets` → `--namespace security` |
| `install-kyverno.sh` | kyverno | security | `--namespace kyverno` → `--namespace security` |
| `install-falco.sh` | falco | security | `--namespace falco` → `--namespace security` |
| `install-minio.sh` | minio | backup | `--namespace minio` → `--namespace backup` |
| `install-metallb.sh` | metallb-system | kube-system | metallb 설치 방식 변경 |
| `install-opencost.sh` | opencost | platform-tools | 통합 |
| `install-vpa.sh` | vpa | platform-tools | 통합 |
| `install-goldilocks.sh` | goldilocks | platform-tools | 통합 |
| `install-chaos-mesh.sh` | chaos-mesh | platform-tools | 통합 |
| `install-trivy.sh` | trivy-system | platform-tools | 통합 |

### 3. Helm Values Files (필수)

**영향받는 values 파일**:

```bash
# Prometheus datasource 업데이트
addons/values/prometheus/prometheus-stack-values.yaml
- Loki datasource: http://loki-gateway.loki.svc → http://loki-gateway.observability.svc
- Tempo datasource: http://tempo.monitoring.svc → http://tempo.observability.svc

# Loki promtail 설정
addons/values/loki/promtail-values.yaml (별도 생성 필요)
- loki.url: http://loki-gateway.loki.svc → http://loki-gateway.observability.svc

# Thanos Query 설정
addons/values/thanos/thanos-values.yaml
- (FQDN이므로 영향 없음)

# Tempo traces-to-metrics
addons/values/tempo/tempo-values.yaml
- remoteWriteUrl: monitoring → observability로 변경 가능

# OTel Collector exporters
addons/values/otel/otel-collector-values.yaml
- Loki endpoint: loki.svc → observability namespace로 업데이트
- Tempo endpoint: tempo.svc → observability namespace로 업데이트

# Velero S3 configuration
addons/values/velero/velero-values.yaml
- s3Url: http://minio.minio.svc:9000 → http://minio.backup.svc:9000

# ESO ClusterSecretStore
addons/values/eso/clustersecretstore.yaml
- vault.server: http://vault.vault.svc:8200 (변경 없음, vault는 유지)

# K8sGPT LocalAI backend
addons/values/k8sgpt/k8sgpt-operator-values.yaml
- localAI.url: http://localai.localai.svc:8080 → http://localai.aiops.svc:8080

# Robusta LocalAI backend
addons/values/robusta/robusta-values.yaml
- localai.url: http://localai.localai.svc:8080 → http://localai.aiops.svc:8080
```

### 4. ArgoCD Applications (있다면)

현재는 없지만, 향후 ArgoCD로 addon 관리 시:
- Application manifest의 `destination.namespace` 업데이트

---

## ✅ 장점

1. **관리 효율성 향상**
   - 25개 → 9개 namespace (mgmt), 10개 → 6개 (app clusters)
   - `kubectl get pods --all-namespaces` 출력 간소화

2. **RBAC 단순화**
   - Observability 팀: `observability` namespace에 대한 권한
   - Security 팀: `security` namespace에 대한 권한
   - Platform 팀: `platform-tools` namespace에 대한 권한

3. **NetworkPolicy 최적화**
   - 같은 namespace 내 pod 간 통신 자동 허용
   - namespace 간 통신만 명시적으로 정의

4. **리소스 쿼터 관리**
   - namespace별 ResourceQuota 설정 용이
   - 기능별 리소스 할당 추적

5. **모니터링 개선**
   - Prometheus namespace label로 쉽게 필터링
   - 기능별 메트릭 집계 간편

---

## ⚠️ 주의사항

### 1. 표준 Namespace는 유지

- **cert-manager**: cert-manager (Kubernetes 표준)
- **istio-system**: Service Mesh 표준 위치
- **argocd**: ArgoCD 커뮤니티 표준

### 2. Vault 격리 유지

```yaml
# Vault는 보안상 독립 namespace 유지 권장
namespace: vault  # 변경 안 함
```

이유:
- Secrets 중앙 저장소로서 격리 필요
- RBAC 최소 권한 원칙
- 감사(Audit) 로그 분리

### 3. kube-system 사용 최소화

```bash
# Tetragon, MetalLB만 kube-system 사용
# DaemonSet이며 privileged 권한 필요
```

### 4. FQDN 통신 확인

```bash
# 대부분의 addon은 FQDN 사용하므로 영향 없음
# 예: http://service-name.namespace.svc.cluster.local
```

---

## 🚀 권장 적용 순서

### Option A: 점진적 마이그레이션 (권장)

1. ✅ **Phase 1**: Observability 통합 (1주차)
2. ✅ **Phase 2**: AIOps 통합 (2주차)
3. ✅ **Phase 3**: Platform Tools 통합 (3주차)
4. ⏸️ **Phase 4**: Security 통합 (검증 후)
5. ⏸️ **Phase 5**: Backup 통합 (검증 후)

### Option B: 신규 클러스터에만 적용

```bash
# 기존 클러스터는 유지
# 새로 생성하는 클러스터부터 신규 namespace 구조 적용
```

### Option C: 전체 재설치 (가장 간단)

```bash
# 모든 addon 삭제 후 신규 namespace로 재설치
bash addons/uninstall.sh --all
# 스크립트 수정
bash addons/install.sh --all
```

---

## 📊 비용 분석

### 변경 비용

- **스크립트 수정**: 23개 파일 × 5분 = ~2시간
- **Values 업데이트**: 10개 파일 × 10분 = ~2시간
- **테스트 & 검증**: 4시간
- **문서 업데이트**: 1시간

**총 예상 시간**: 9시간

### 운영 효율 향상

- **Namespace 관리**: 60% 감소 (25개 → 9개)
- **RBAC 설정 시간**: 50% 감소
- **트러블슈팅 시간**: 30% 감소 (명확한 경계)

**ROI**: 초기 투자 9시간 → 월 5시간 절감

---

## 🎯 결론 및 권장사항

### 즉시 적용 가능 (Low Risk)

✅ **Observability 통합** (loki, thanos, promtail → observability)
✅ **AIOps 통합** (k8sgpt, localai, robusta, botkube → aiops)
✅ **Platform Tools 통합** (opencost, vpa, goldilocks, chaos-mesh, trivy → platform-tools)

### 신중한 검토 필요 (Medium Risk)

⚠️ **Security 통합** (eso, kyverno, falco → security)
⚠️ **Backup 통합** (minio, velero → backup)

### 유지 권장 (Standards)

🔒 **cert-manager** (표준 위치)
🔒 **istio-system** (Service Mesh 표준)
🔒 **argocd** (GitOps 표준)
🔒 **vault** (보안 격리)

---

**다음 단계**:
1. 위 제안 검토 및 승인
2. 수정된 install 스크립트 생성
3. Dev 환경 테스트
4. Production 적용

---

**작성일**: 2026-02-20
**버전**: 1.0

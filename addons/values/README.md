# Addon Helm Values

> **Helm Chart 커스텀 설정 파일**

이 디렉토리는 각 addon의 Helm values 파일을 포함합니다. 기본값은 로컬 개발 환경에 최적화되어 있습니다.

---

## 📁 디렉토리 구조

```
values/
├── README.md                           # 본 문서
├── vault/
│   └── vault-values.yaml              # Vault 설정
├── argocd/
│   └── argocd-values.yaml             # ArgoCD 설정
├── prometheus/
│   └── prometheus-stack-values.yaml   # Prometheus Stack 설정
├── loki/
│   └── loki-values.yaml               # Loki 설정
├── thanos/
│   └── thanos-values.yaml             # Thanos 설정
├── minio/
│   └── minio-values.yaml              # MinIO 설정
├── kyverno/
│   └── kyverno-values.yaml            # Kyverno 설정
└── ... (기타 addon별 디렉토리)
```

---

## 🎯 Values 파일 사용법

### 1. 기본 사용 (values 파일 적용)

설치 스크립트를 수정하여 values 파일을 사용:

```bash
# AS-IS: inline --set 사용
helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  --set server.dataStorage.size=10Gi \
  --set server.resources.requests.memory=256Mi \
  # ...

# TO-BE: values 파일 사용
helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  -f addons/values/vault/vault-values.yaml
```

### 2. 값 오버라이드

Values 파일과 inline --set을 함께 사용 가능 (inline이 우선):

```bash
helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  -f addons/values/vault/vault-values.yaml \
  --set server.dataStorage.size=20Gi  # 파일의 10Gi를 20Gi로 오버라이드
```

### 3. 여러 Values 파일 병합

```bash
helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  -f addons/values/vault/vault-values.yaml \
  -f addons/values/vault/vault-custom.yaml  # 커스텀 설정 추가
```

마지막 파일이 가장 높은 우선순위를 가집니다.

---

## 📦 Available Values Files

### 🔐 Secrets

| Addon | Values File | Chart | 설명 |
|-------|------------|-------|------|
| Vault | [vault/vault-values.yaml](vault/vault-values.yaml) | hashicorp/vault | Secret 저장소 |

**주요 설정**:
- Storage: `local-path-retain` 10Gi
- Mode: Standalone (no HA)
- UI: Enabled
- Resources: 256Mi RAM / 100m CPU

---

### 🔄 GitOps

| Addon | Values File | Chart | 설명 |
|-------|------------|-------|------|
| ArgoCD | [argocd/argocd-values.yaml](argocd/argocd-values.yaml) | argo/argo-cd | GitOps CD 엔진 |

**주요 설정**:
- Server: ClusterIP (insecure mode)
- Controller: 512Mi RAM
- RepoServer: 256Mi RAM
- Redis: 128Mi RAM

---

### 📊 Observability

| Addon | Values File | Chart | 설명 |
|-------|------------|-------|------|
| Prometheus Stack | [prometheus/prometheus-stack-values.yaml](prometheus/prometheus-stack-values.yaml) | prometheus-community/kube-prometheus-stack | Full 관찰성 스택 |
| Thanos | [thanos/thanos-values.yaml](thanos/thanos-values.yaml) | bitnami/thanos | 장기 메트릭 저장 |
| Loki | [loki/loki-values.yaml](loki/loki-values.yaml) | grafana/loki | 로그 수집/저장 |

**Prometheus Stack 주요 설정**:
- Retention: 7일 / 5GB
- Storage: `local-path-retain` 10Gi
- Grafana: Enabled (admin/admin)
- Alertmanager: Enabled

**Thanos 주요 설정**:
- Receive: LoadBalancer (remote write 수신)
- Query: ClusterIP
- Retention: 15일
- Storage: 20Gi (receive) + 10Gi (compactor)

**Loki 주요 설정**:
- Mode: SingleBinary
- Retention: 7일 (168h)
- Storage: `local-path-retain` 10Gi
- Schema: v13 (TSDB)

---

### 🛡️ Security

| Addon | Values File | Chart | 설명 |
|-------|------------|-------|------|
| Kyverno | [kyverno/kyverno-values.yaml](kyverno/kyverno-values.yaml) | kyverno/kyverno | 정책 엔진 |

**주요 설정**:
- All controllers: 1 replica
- Policies: 별도 YAML로 관리 (values 파일에는 미포함)

---

### 💾 Backup

| Addon | Values File | Chart | 설명 |
|-------|------------|-------|------|
| MinIO | [minio/minio-values.yaml](minio/minio-values.yaml) | bitnami/minio | S3 호환 스토리지 |

**주요 설정**:
- Credentials: minioadmin / minioadmin123
- Mode: Standalone
- Storage: `local-path` 50Gi
- Service: LoadBalancer (9000, 9001)
- Default bucket: velero-backups

---

## 🔧 Values 파일 커스터마이징

### 환경별 설정 관리

프로덕션 환경을 위한 별도 values 파일 생성:

```bash
# 개발 환경
addons/values/vault/vault-values.yaml

# 프로덕션 환경
addons/values/vault/vault-prod-values.yaml
```

프로덕션 values 파일 예시:
```yaml
# vault-prod-values.yaml
server:
  dataStorage:
    size: 100Gi  # 개발: 10Gi → 프로덕션: 100Gi

  resources:
    requests:
      memory: 1Gi  # 개발: 256Mi → 프로덕션: 1Gi
      cpu: 500m
    limits:
      memory: 2Gi
      cpu: 1000m

  ha:
    enabled: true  # 개발: false → 프로덕션: true
    replicas: 3
```

설치 시:
```bash
# 개발 환경
helm upgrade --install vault hashicorp/vault \
  -f addons/values/vault/vault-values.yaml

# 프로덕션 환경
helm upgrade --install vault hashicorp/vault \
  -f addons/values/vault/vault-values.yaml \
  -f addons/values/vault/vault-prod-values.yaml
```

---

## 📝 Values 파일 작성 가이드

### 1. 주석 작성

```yaml
# 명확한 설명 추가
server:
  # Data retention (default: 7d)
  # Production: 30d recommended
  retention: 7d

  # Storage configuration
  dataStorage:
    storageClass: local-path-retain  # Use Retain policy for data safety
    size: 10Gi
```

### 2. 기본값 우선

Helm Chart의 기본값을 최대한 활용하고, 변경이 필요한 항목만 명시:

```yaml
# ❌ 나쁜 예: 모든 값을 명시
server:
  enabled: true  # Chart 기본값
  replicas: 1    # Chart 기본값
  port: 8080     # Chart 기본값
  ...

# ✅ 좋은 예: 변경하는 값만 명시
server:
  resources:
    requests:
      memory: 256Mi  # 기본값과 다름
```

### 3. 계층 구조 유지

```yaml
# ✅ 계층 구조 명확
prometheus:
  prometheusSpec:
    retention: 7d
    resources:
      requests:
        memory: 512Mi
```

---

## 🔍 Helm Chart 기본값 확인

각 Chart의 전체 기본값 확인:

```bash
# 기본값 다운로드
helm show values hashicorp/vault > /tmp/vault-default-values.yaml

# 특정 섹션만 확인
helm show values hashicorp/vault | grep -A 10 "resources:"
```

---

## 📚 참고 자료

| Chart | 문서 | Repository |
|-------|------|-----------|
| Vault | https://developer.hashicorp.com/vault/docs/platform/k8s/helm | https://github.com/hashicorp/vault-helm |
| ArgoCD | https://argo-cd.readthedocs.io/en/stable/operator-manual/installation/ | https://github.com/argoproj/argo-helm |
| Prometheus | https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack | https://prometheus-community.github.io/helm-charts |
| Loki | https://grafana.com/docs/loki/latest/setup/install/helm/ | https://grafana.github.io/helm-charts |
| Thanos | https://github.com/bitnami/charts/tree/main/bitnami/thanos | https://charts.bitnami.com/bitnami |
| Kyverno | https://kyverno.io/docs/installation/methods/ | https://kyverno.github.io/kyverno/ |
| MinIO | https://github.com/bitnami/charts/tree/main/bitnami/minio | https://charts.bitnami.com/bitnami |

---

## ⚠️ 주의사항

### 1. StorageClass 설정

```yaml
# ⚠️ 로컬 환경 (개발)
storageClass: local-path-retain

# ✅ 클라우드 환경 (프로덕션)
storageClass: gp3  # AWS EBS gp3
# 또는
storageClass: standard-rwo  # GCP Persistent Disk
```

### 2. 리소스 제한

로컬 환경은 리소스가 제한적이므로 최소한으로 설정:

```yaml
# 로컬 환경 (개발)
resources:
  requests:
    memory: 256Mi
  limits:
    memory: 512Mi

# 프로덕션
resources:
  requests:
    memory: 1Gi
  limits:
    memory: 2Gi
```

### 3. 민감 정보

Values 파일에 비밀번호를 직접 입력하지 말 것:

```yaml
# ❌ 나쁜 예
auth:
  rootPassword: "my-secret-password"

# ✅ 좋은 예 (Secret 참조)
auth:
  existingSecret: minio-auth-secret
```

또는 설치 시 오버라이드:

```bash
helm upgrade --install minio bitnami/minio \
  -f addons/values/minio/minio-values.yaml \
  --set auth.rootPassword="${MINIO_PASSWORD}"
```

---

**Version**: 5.0.0
**Last Updated**: 2026-02-20

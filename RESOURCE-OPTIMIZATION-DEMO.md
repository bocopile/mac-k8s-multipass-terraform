# Resource Optimization for Demo Environment

> **Mac M1 Max 환경 기준 리소스 최적화**
>
> Host: Apple M1 Max (10코어, 64GB RAM, 540GB 디스크)
> Purpose: 시연 및 데모 환경

---

## 🖥️ 호스트 환경

| 리소스 | 최소 | 권장 | **현재 (Mac)** | 여유 |
|-------|------|------|---------------|------|
| **CPU** | 8코어 | 10코어 이상 | **10코어** | ✅ 충분 |
| **RAM** | 32GB | 64GB | **64GB** | ✅ 충분 |
| **디스크** | 256GB SSD | 512GB 이상 | **540GB** | ✅ 충분 |
| **OS** | macOS 13+ | macOS 14+ | **Darwin 25.3.0** | ✅ 충분 |

**결론**: 현재 Mac 환경은 권장 스펙을 만족합니다.

---

## 📊 현재 리소스 할당 (운영 환경 기준)

### VM 리소스

| VM | vCPU | RAM | Disk | 역할 |
|----|------|-----|------|------|
| **mgmt-control-0** | 2 | 4GB | 20GB | Control Plane |
| **mgmt-worker-0** | 4 | 12GB | 40GB | Platform Services |
| **app1-control-0** | 2 | 4GB | 20GB | Control Plane |
| **app1-worker-0** | 3 | 8GB | 30GB | App Workloads |
| **app2-control-0** | 2 | 4GB | 20GB | Control Plane |
| **app2-worker-0** | 3 | 8GB | 30GB | App Workloads |
| **합계** | **16 vCPU** | **40GB RAM** | **160GB Disk** | |

**문제점**:
- ⚠️ **CPU 초과 할당**: 16 vCPU > 10 코어 (160% 할당)
- ⚠️ **RAM 여유**: 40GB / 64GB = 62% 사용 (양호)
- ⚠️ **Disk 여유**: 160GB / 540GB = 30% 사용 (양호)

---

## 🎯 시연 환경 최적화 방안

### Option A: 축소형 (권장 - 시연 목적)

**목표**: CPU 과할당 해소, 빠른 배포

| VM | vCPU | RAM | Disk | 변경 |
|----|------|-----|------|------|
| **mgmt-control-0** | 2 | 3GB ⬇️ | 15GB ⬇️ | -1GB RAM, -5GB Disk |
| **mgmt-worker-0** | 3 ⬇️ | 8GB ⬇️ | 30GB ⬇️ | -1 vCPU, -4GB RAM, -10GB Disk |
| **app1-control-0** | 1 ⬇️ | 2GB ⬇️ | 15GB ⬇️ | -1 vCPU, -2GB RAM, -5GB Disk |
| **app1-worker-0** | 2 ⬇️ | 6GB ⬇️ | 20GB ⬇️ | -1 vCPU, -2GB RAM, -10GB Disk |
| **app2-control-0** | 1 ⬇️ | 2GB ⬇️ | 15GB ⬇️ | -1 vCPU, -2GB RAM, -5GB Disk |
| **app2-worker-0** | 2 ⬇️ | 6GB ⬇️ | 20GB ⬇️ | -1 vCPU, -2GB RAM, -10GB Disk |
| **합계** | **11 vCPU** ✅ | **27GB RAM** ✅ | **115GB Disk** ✅ | |

**효과**:
- ✅ CPU: 11 vCPU < 10 코어 (여전히 약간 초과하지만 acceptable)
- ✅ RAM: 27GB / 64GB = 42% 사용 (충분한 여유)
- ✅ Disk: 115GB / 540GB = 21% 사용 (충분한 여유)

### Option B: 최소형 (극단적 축소)

**목표**: 리소스 최소화, 기능 검증만 가능

| VM | vCPU | RAM | Disk |
|----|------|-----|------|
| **mgmt-control-0** | 2 | 2GB | 15GB |
| **mgmt-worker-0** | 2 | 6GB | 25GB |
| **app1-control-0** | 1 | 2GB | 15GB |
| **app1-worker-0** | 2 | 4GB | 20GB |
| **app2** | ❌ 제거 | ❌ 제거 | ❌ 제거 |
| **합계** | **7 vCPU** | **14GB RAM** | **75GB Disk** |

**주의**: app2 제거 시 multi-cluster 시연 불가

---

## 💾 MinIO 스토리지 최적화

### 현재 설정 (운영 환경 기준)

```yaml
persistence:
  size: 50Gi  # ⚠️ 시연 환경에 과다
```

**예상 사용량 (운영 환경)**:
- Velero 백업: ~30-50GB (90일 보관)
- Thanos 메트릭: ~15-20GB (무제한 보관)
- Loki 로그 (미래): ~10-15GB
- Tempo 트레이스 (미래): ~5-10GB
- **총 예상**: ~60-95GB

### 시연 환경 최적화

**예상 사용량 (시연 7일 기준)**:
- Velero 백업: ~2-3GB (3일 보관)
- Thanos 메트릭: ~2-3GB (7일 보관)
- Loki 로그 (미래): ~1-2GB
- Tempo 트레이스 (미래): ~1GB
- **총 예상**: ~6-9GB

**권장 설정**:

| 항목 | 운영 환경 | 시연 환경 | 변경 |
|------|----------|----------|------|
| **Storage Size** | 50Gi | **15Gi** ⬇️ | -35Gi (70% 축소) |
| **Memory Request** | 256Mi | **128Mi** ⬇️ | -50% |
| **Memory Limit** | 512Mi | **256Mi** ⬇️ | -50% |
| **CPU Request** | 100m | **50m** ⬇️ | -50% |
| **CPU Limit** | 500m | **250m** ⬇️ | -50% |

---

## 🔧 적용 방법

### 1. MinIO 최적화 적용

#### 방법 A: Values 파일 수정

`addons/values/minio/minio-values.yaml` 수정:

```yaml
# MinIO Helm Values (Demo Environment)
# Optimized for demonstration and testing

auth:
  rootUser: minioadmin
  rootPassword: minioadmin123

mode: standalone

# Persistence (OPTIMIZED FOR DEMO)
persistence:
  enabled: true
  storageClass: local-path
  size: 15Gi  # ⬅️ 50Gi → 15Gi (70% 축소)

service:
  type: LoadBalancer
  ports:
    api: 9000
    console: 9001

defaultBuckets: "velero-backups,thanos,loki-logs,tempo-traces"

# Resources (OPTIMIZED FOR DEMO)
resources:
  requests:
    memory: 128Mi  # ⬅️ 256Mi → 128Mi
    cpu: 50m       # ⬅️ 100m → 50m
  limits:
    memory: 256Mi  # ⬅️ 512Mi → 256Mi
    cpu: 250m      # ⬅️ 500m → 250m
```

#### 방법 B: Install 스크립트 수정

`addons/scripts/install-minio.sh` 수정:

```bash
helm upgrade --install minio bitnami/minio \
  --namespace backup --create-namespace \
  ${KC} \
  --set auth.rootUser=minioadmin \
  --set auth.rootPassword=minioadmin123 \
  --set mode=standalone \
  --set persistence.enabled=true \
  --set persistence.storageClass=local-path \
  --set persistence.size=15Gi \                    # ⬅️ 변경
  --set service.type=LoadBalancer \
  --set service.ports.api=9000 \
  --set service.ports.console=9001 \
  --set defaultBuckets="velero-backups,thanos" \
  --set resources.requests.memory=128Mi \          # ⬅️ 변경
  --set resources.requests.cpu=50m \               # ⬅️ 변경
  --set resources.limits.memory=256Mi \            # ⬅️ 변경
  --set resources.limits.cpu=250m \                # ⬅️ 변경
  --wait --timeout 180s
```

재설치:
```bash
bash addons/scripts/install-minio.sh
```

---

### 2. 기타 Addon 최적화 (선택사항)

#### Loki (7d 로그 보관)

```yaml
# 현재
persistence:
  size: 10Gi

# 시연 환경 (5일 보관)
persistence:
  size: 5Gi  # ⬅️ 50% 축소
```

#### Tempo (7d 트레이스 보관)

```yaml
# 현재
persistence:
  size: 10Gi

# 시연 환경 (3일 보관)
persistence:
  size: 5Gi  # ⬅️ 50% 축소
```

#### Thanos (Receive TSDB)

```yaml
# 현재
receive:
  persistence:
    size: 20Gi

# 시연 환경 (7일 보관)
receive:
  persistence:
    size: 10Gi  # ⬅️ 50% 축소
```

#### Prometheus Stack

```yaml
# 현재
prometheus:
  prometheusSpec:
    retention: 7d
    retentionSize: 5GB

# 시연 환경 (3일 보관)
prometheus:
  prometheusSpec:
    retention: 3d        # ⬅️ 축소
    retentionSize: 2GB   # ⬅️ 축소
```

---

## 📋 전체 스토리지 사용량 비교

### 운영 환경 (원본)

| 컴포넌트 | 크기 | 보관 기간 | 합계 |
|----------|------|-----------|------|
| MinIO | 50Gi | - | 50Gi |
| Prometheus | 10Gi | 7일 | 10Gi |
| Loki | 10Gi | 7일 | 10Gi |
| Tempo | 10Gi | 7일 | 10Gi |
| Thanos Receive | 20Gi | 15일 | 20Gi |
| Thanos Compactor | 10Gi | - | 10Gi |
| Vault | 10Gi | - | 10Gi |
| **총합** | | | **120Gi** |

### 시연 환경 (최적화 후)

| 컴포넌트 | 크기 | 보관 기간 | 합계 |
|----------|------|-----------|------|
| MinIO | **15Gi** ⬇️ | - | 15Gi |
| Prometheus | **5Gi** ⬇️ | 3일 | 5Gi |
| Loki | **5Gi** ⬇️ | 5일 | 5Gi |
| Tempo | **5Gi** ⬇️ | 3일 | 5Gi |
| Thanos Receive | **10Gi** ⬇️ | 7일 | 10Gi |
| Thanos Compactor | **5Gi** ⬇️ | - | 5Gi |
| Vault | 10Gi | - | 10Gi |
| **총합** | | | **55Gi** ⬇️ |

**절감**: 120Gi → 55Gi (**54% 축소**)

---

## 🎯 권장 사항

### 즉시 적용 (필수)

1. ✅ **MinIO 축소**: 50Gi → 15Gi
   - 시연 7일 기준 충분
   - 디스크 공간 35Gi 절약

2. ✅ **MinIO 리소스 축소**: Memory/CPU 50% 축소
   - 시연 환경에서 과다 할당 해소

### 선택 적용 (권장)

3. 🟡 **Prometheus 축소**: 7d → 3d, 5GB → 2GB
   - 시연 목적상 3일이면 충분

4. 🟡 **Loki/Tempo 축소**: 10Gi → 5Gi
   - 로그/트레이스 단기 보관만 필요

5. 🟡 **Thanos 축소**: 20Gi → 10Gi
   - MinIO로 장기 보관하므로 Receive TSDB 축소 가능

### 고려사항

- ⚠️ **VM CPU 초과 할당**: 16 vCPU → 11 vCPU 축소 권장
  - Terraform variables.tf 수정 필요
  - VM 재생성 필요 (시간 소요)

- ✅ **RAM/Disk 여유**: 충분하므로 추가 조치 불필요

---

## 📊 최종 리소스 할당 (시연 환경)

### VM 리소스 (Option A 적용 시)

| 리소스 | 현재 (운영) | 시연 환경 | 절감 |
|--------|------------|----------|------|
| **총 vCPU** | 16 | **11** | 31% ⬇️ |
| **총 RAM** | 40GB | **27GB** | 33% ⬇️ |
| **총 Disk** | 160GB | **115GB** | 28% ⬇️ |

### 스토리지 (Addon 전체)

| 항목 | 현재 | 시연 환경 | 절감 |
|------|------|----------|------|
| **MinIO** | 50Gi | **15Gi** | 70% ⬇️ |
| **Observability** | 50Gi | **25Gi** | 50% ⬇️ |
| **기타** | 20Gi | **15Gi** | 25% ⬇️ |
| **총합** | 120Gi | **55Gi** | 54% ⬇️ |

---

## 🚀 적용 순서

### 1단계: MinIO만 축소 (5분)

```bash
# Values 파일 수정
nano addons/values/minio/minio-values.yaml
# persistence.size: 50Gi → 15Gi
# resources 수정

# 재설치
helm uninstall minio -n backup
bash addons/scripts/install-minio.sh
```

### 2단계: Observability 스택 축소 (10분)

```bash
# 각 values 파일 수정
nano addons/values/prometheus/prometheus-stack-values.yaml
nano addons/values/loki/loki-values.yaml
nano addons/values/tempo/tempo-values.yaml
nano addons/values/thanos/thanos-values.yaml

# 재설치
bash addons/scripts/install-prometheus-stack.sh
bash addons/scripts/install-loki.sh
bash addons/scripts/install-tempo.sh
bash addons/scripts/install-thanos.sh
```

### 3단계: VM 축소 (선택사항, 30분)

```bash
# Terraform variables 수정
nano variables.tf

# VM 재생성
terraform destroy -target=module.multipass
terraform apply
```

---

## ✅ 검증

### 스토리지 사용량 확인

```bash
# MinIO 실제 사용량
kubectl exec -n backup -it deploy/minio -- mc du local/velero-backups
kubectl exec -n backup -it deploy/minio -- mc du local/thanos

# PVC 사용량 확인
kubectl get pvc -A
kubectl top pvc -A  # metrics-server 필요
```

### 리소스 사용량 확인

```bash
# Pod 리소스 사용량
kubectl top pods -A

# Node 리소스 사용량
kubectl top nodes
```

---

**Last Updated**: 2026-02-20
**Optimization Level**: **Demo Environment**
**Estimated Savings**: 54% storage, 31% CPU, 33% RAM

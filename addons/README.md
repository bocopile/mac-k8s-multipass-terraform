# Kubernetes Addons

> **플랫폼 부가 기능 (Optional Components)**

이 디렉토리는 Kubernetes 클러스터에 추가로 설치할 수 있는 애드온들을 관리합니다.

---

## 📁 디렉토리 구조

```
addons/
├── install.sh          # 일괄 설치 스크립트
├── uninstall.sh        # 일괄 삭제 스크립트
├── verify.sh           # 상태 검증 스크립트
├── README.md           # 본 문서
├── scripts/            # 개별 애드온 설치 스크립트
│   ├── install-vault.sh
│   ├── install-eso.sh
│   ├── install-argocd.sh
│   ├── install-prometheus-stack.sh
│   ├── install-thanos.sh
│   ├── install-loki.sh
│   ├── install-tempo.sh
│   ├── install-istio.sh
│   ├── install-kiali.sh
│   ├── install-kyverno.sh
│   ├── install-falco.sh
│   ├── install-k8sgpt.sh
│   ├── install-holmesgpt.sh
│   ├── install-botkube.sh
│   ├── install-minio.sh
│   └── install-velero.sh
└── values/             # Helm values 파일 (향후 추가)
    ├── vault/
    ├── argocd/
    ├── prometheus/
    └── ...
```

---

## 🚀 빠른 시작

### 1. 모든 애드온 설치

```bash
# 전체 설치 (botkube 제외)
bash addons/install.sh --all
```

### 2. 카테고리별 설치

```bash
# 관찰성 스택만 설치
bash addons/install.sh --category observability

# 보안 도구만 설치
bash addons/install.sh --category security

# AI 운영 도구만 설치
bash addons/install.sh --category aiops
```

### 3. 특정 애드온만 설치

```bash
# Vault + ArgoCD만 설치
bash addons/install.sh vault argocd

# Prometheus 스택 + Loki만 설치
bash addons/install.sh prometheus-stack loki
```

### 4. 상태 검증

```bash
# 모든 애드온 상태 확인
bash addons/verify.sh --all

# 특정 애드온만 확인
bash addons/verify.sh vault argocd prometheus-stack
```

### 5. 애드온 삭제

```bash
# 전체 삭제
bash addons/uninstall.sh --all

# 특정 애드온만 삭제
bash addons/uninstall.sh vault argocd
```

---

## 📦 애드온 카테고리

### 🏗️ Infrastructure (인프라 기초)

| 애드온 | 용도 | 배치 | 리소스 |
|--------|------|------|--------|
| **cilium** | CNI (Container Network Interface) | 전체 | ~350MB/클러스터 |
| **tetragon** | eBPF 런타임 보안 | 전체 | ~100MB/노드 |
| **metallb** | L2 로드밸런서 | 전체 | ~80MB/클러스터 |
| **gateway-api** | Gateway API CRDs (Ingress 대체) | 전체 | ~minimal |
| **cert-manager** | TLS 인증서 자동 관리 | 전체 | ~100MB/클러스터 |
| **clustermesh** | Cilium Cluster Mesh (멀티클러스터 네트워킹) | 전체 | ~minimal |

```bash
bash addons/install.sh --category infrastructure
```

> **참고**: Infrastructure addons는 일반적으로 Terraform에서 자동 설치됩니다. 수동 재설치가 필요할 때만 사용하세요.

### 🔐 Secrets (시크릿 관리)

| 애드온 | 용도 | 배치 | 리소스 |
|--------|------|------|--------|
| **vault** | Secret 저장소 | mgmt | ~400MB |
| **vault-pki** | Vault PKI 설정 (cert-manager 통합) | mgmt | ~minimal |
| **eso** | External Secrets Operator | 전체 | ~100MB/클러스터 |

```bash
bash addons/install.sh --category secrets
```

### 🔄 GitOps

| 애드온 | 용도 | 배치 | 리소스 |
|--------|------|------|--------|
| **argocd** | GitOps CD 엔진 | mgmt | ~700MB |

```bash
bash addons/install.sh --category gitops
```

### 📊 Observability (관찰성)

| 애드온 | 용도 | 배치 | 리소스 |
|--------|------|------|--------|
| **prometheus-stack** | 메트릭 수집 (Full) | mgmt | ~700MB |
| **thanos** | 장기 메트릭 저장 | mgmt | ~512MB |
| **prometheus-agent** | 메트릭 수집 (Agent) | app1/app2 | ~200MB |
| **loki** | 로그 수집 | mgmt + app | ~400MB |
| **tempo** | 분산 추적 | mgmt | ~256MB |
| **otel-collector** | OpenTelemetry | mgmt + app | ~256MB |

```bash
bash addons/install.sh --category observability
```

### 🕸️ Service Mesh

| 애드온 | 용도 | 배치 | 리소스 |
|--------|------|------|--------|
| **istio** | Service Mesh (mTLS, L7) | mgmt + app1 | ~650MB |
| **kiali** | Service Mesh 관찰성 | mgmt | ~128MB |

```bash
bash addons/install.sh --category servicemesh
```

### 🛡️ Security (보안)

| 애드온 | 용도 | 배치 | 리소스 |
|--------|------|------|--------|
| **kyverno** | 정책 엔진 | app1/app2 | ~200MB |
| **falco** | 런타임 보안 | app1/app2 | ~200MB |
| **platform-addons** | Trivy, K8sGPT Operator, OpenCost, VPA, Chaos Mesh | mgmt | ~1GB |

```bash
bash addons/install.sh --category security
```

### 🤖 AIOps (AI 운영 도구)

| 애드온 | 용도 | 배치 | 리소스 |
|--------|------|------|--------|
| **k8sgpt** | 클러스터 진단 (LocalAI 포함) | mgmt | ~2.1GB |
| **holmesgpt** | AI 알림 조사 (Robusta) | mgmt | ~512MB |
| **botkube** | ChatOps (Slack) | mgmt | ~256MB |

```bash
bash addons/install.sh --category aiops
```

> **참고**: `k8sgpt` 설치 시 LocalAI LLM 백엔드가 함께 설치되며 `holmesgpt`와 공유됩니다.

### 💾 Backup (백업)

| 애드온 | 용도 | 배치 | 리소스 |
|--------|------|------|--------|
| **minio** | S3 호환 스토리지 | mgmt | ~256MB |
| **velero** | 클러스터 백업 | 전체 | ~256MB/클러스터 |

```bash
bash addons/install.sh --category backup
```

---

## 📋 전체 애드온 목록

### 설치 가능한 애드온 확인

```bash
bash addons/install.sh --list
```

출력 예시:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Available Addons
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[secrets]
  ✓ vault
  ✓ eso

[gitops]
  ✓ argocd

[observability]
  ✓ prometheus-stack
  ✓ thanos
  ✓ prometheus-agent
  ✓ loki
  ✓ tempo
  ✓ otel-collector

[servicemesh]
  ✓ istio
  ✓ kiali

[security]
  ✓ kyverno
  ✓ falco
  ✓ platform-addons

[aiops]
  ✓ k8sgpt
  ✓ holmesgpt
  ✓ botkube

[backup]
  ✓ minio
  ✓ velero

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 🔧 개별 애드온 수동 설치

애드온별로 개별 설치도 가능합니다:

```bash
# Vault 설치
bash addons/scripts/install-vault.sh

# ArgoCD 설치
bash addons/scripts/install-argocd.sh

# Prometheus Stack 설치
bash addons/scripts/install-prometheus-stack.sh
```

---

## ⚙️ 설치 순서 (의존성)

애드온은 다음 순서로 설치됩니다:

```
1. vault
2. eso                  (vault 의존)
3. argocd
4. platform-addons      (Trivy, K8sGPT Operator, OpenCost, VPA, Chaos Mesh)
5. k8sgpt               (platform-addons 의존, LocalAI 배포)
6. thanos
7. prometheus-stack
8. prometheus-agent     (thanos 의존)
9. loki
10. tempo
11. otel-collector
12. istio
13. kiali               (istio 의존)
14. kyverno
15. falco
16. holmesgpt           (prometheus-stack, loki, tempo, k8sgpt 의존)
17. botkube             (선택적, Slack 토큰 필요)
18. minio
19. velero              (minio 의존)
```

`install.sh`는 자동으로 의존성 순서를 고려하여 설치합니다.

---

## 🗑️ 삭제 순서

삭제는 **역순**으로 진행됩니다:

```bash
# 모든 애드온 삭제 (역순)
bash addons/uninstall.sh --all
```

---

## 📊 리소스 요구사항

### mgmt 클러스터 (10GB+ 권장)

| 구성 요소 | RAM |
|----------|-----|
| Vault | 400 MB |
| ArgoCD | 700 MB |
| Prometheus Full | 700 MB |
| Thanos | 512 MB |
| Loki | 400 MB |
| Tempo | 256 MB |
| Istio (Istiod + Gateway) | 650 MB |
| Kiali | 128 MB |
| **LocalAI (AI 백엔드)** | 2048 MB |
| **K8sGPT** | 128 MB |
| **HolmesGPT** | 512 MB |
| Botkube (선택) | 256 MB |
| Platform Addons | 1000 MB |
| MinIO | 256 MB |
| Velero | 256 MB |
| **총합 (AI 포함)** | **~8.2 GB** |

### app1/app2 클러스터 (각 7GB)

| 구성 요소 | RAM |
|----------|-----|
| Prometheus Agent | 200 MB |
| Promtail (Loki) | 100 MB |
| OTel Collector | 256 MB |
| Kyverno | 200 MB |
| Falco | 200 MB |
| ESO | 50 MB |
| Velero | 128 MB |
| Istio Sidecar (Pod당) | 128 MB |
| **총합** | **~1.3 GB** |
| **애플리케이션 여유** | **~5.7 GB** |

---

## 🚨 주의사항

### 1. Botkube 설치

Botkube는 Slack Bot Token이 필요하므로 **수동 설치**를 권장합니다:

```bash
bash addons/scripts/install-botkube.sh
```

설치 중 Slack Token과 채널 이름을 입력해야 합니다.

### 2. AI 도구 리소스

AI 도구(K8sGPT + HolmesGPT)는 약 **3GB 추가 메모리**가 필요합니다:
- LocalAI: ~2GB (CPU 모드, ggml-gpt4all-j 모델)
- HolmesGPT (Robusta): ~512MB
- K8sGPT Operator: ~128MB

**권장**: mgmt-worker-0를 8GB → **10GB**로 증설

### 3. Istio Service Mesh

Istio는 mgmt + app1 클러스터에 배포되며:
- mgmt: Istiod + Ingress Gateway (~650MB)
- app1: Full Mesh + Sidecar (애플리케이션 Pod당 +128MB)

### 4. 삭제 시 데이터 손실

`uninstall.sh`는 **네임스페이스를 완전히 삭제**합니다:
- PersistentVolume 데이터 삭제됨
- Vault Secret 삭제됨
- 백업 데이터 삭제됨

**중요 데이터는 반드시 백업 후 삭제하세요!**

---

## 🔍 트러블슈팅

### 설치 실패 시

```bash
# 특정 애드온 재설치
bash addons/uninstall.sh vault
bash addons/install.sh vault

# 로그 확인
kubectl --kubeconfig generated/kubeconfig-multi --kube-context kubernetes-admin@mgmt logs -n vault -l app.kubernetes.io/name=vault
```

### Pod이 Ready 상태가 안 될 때

```bash
# 상태 확인
bash addons/verify.sh --all

# Pod 상세 확인
kubectl --kubeconfig generated/kubeconfig-multi --kube-context kubernetes-admin@mgmt get pods -A | grep -v Running
```

### 리소스 부족

```bash
# 노드별 리소스 사용량 확인
kubectl --kubeconfig generated/kubeconfig-multi --kube-context kubernetes-admin@mgmt top nodes
kubectl --kubeconfig generated/kubeconfig-multi --kube-context kubernetes-admin@mgmt top pods -A --sort-by=memory
```

---

## 📚 관련 문서

- [ARCHITECTURE.md](../document/on-premise/ARCHITECTURE.md) - 전체 아키텍처 문서
- [개별 스크립트](./scripts/) - 각 애드온별 상세 설치 스크립트

---

## 🆚 addons vs addons-legacy

| 항목 | addons (현재) | addons-legacy (구버전) |
|-----|--------------|----------------------|
| 구조 | 멀티클러스터 (mgmt, app1, app2) | 단일 클러스터 |
| 자동화 | Terraform + Shell | 수동 Helm |
| CNI | Cilium Cluster Mesh | Flannel |
| Service Mesh | Istio + Cilium 병행 | Istio 단독 |
| 관찰성 | Prometheus Agent + Thanos | Prometheus Full 단독 |
| AI 도구 | K8sGPT, HolmesGPT, Botkube | 없음 |

**권장**: 새 프로젝트는 `addons/` 디렉토리를 사용하세요.

---

**Version**: 5.0.0
**Last Updated**: 2026-02-20

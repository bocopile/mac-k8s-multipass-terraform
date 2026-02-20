# Kubernetes Multi-Cluster Platform on macOS (Multipass + OpenTofu)

> **버전**: v4.0.0
> **Kubernetes**: v1.35 (Timbernetes)
> **IaC**: OpenTofu 1.11 (Terraform 호환)
> **업데이트**: 2026-02-20

macOS(Apple Silicon) 환경에서 **OpenTofu와 Shell Script**를 사용하여 프로덕션급 **Kubernetes 멀티클러스터 환경**을 자동으로 구축하는 IaC 프로젝트입니다.

## 🎯 프로젝트 특징

- 🚀 **완전 자동화**: OpenTofu로 인프라부터 플랫폼 서비스까지 원클릭 배포
- 🔒 **엔터프라이즈급 보안**: Vault + cert-manager PKI, Kyverno + Falco + Tetragon 다층 방어
- 📊 **통합 관찰성**: Prometheus + Thanos + Loki + Grafana 중앙 집중식 모니터링
- 🌐 **Service Mesh 지원**: Cilium Cluster Mesh + Istio (예정)
- ♻️ **GitOps 기반**: ArgoCD 선언적 배포
- 💾 **백업/복구**: Velero + MinIO 자동 백업

---

## 📦 클러스터 구성

### 3-Cluster 토폴로지

| 클러스터 | Control Plane | Worker | 용도 | RAM |
|---------|---------------|--------|------|-----|
| **mgmt** | 1대 (4GB) | 1대 (10GB) | 플랫폼 서비스 (Vault, Prometheus, Loki, ArgoCD, Grafana) | 14GB |
| **app1** | 1대 (3GB) | 1대 (4GB) | 애플리케이션 워크로드 | 7GB |
| **app2** | 1대 (3GB) | 1대 (4GB) | 애플리케이션 워크로드 | 7GB |
| **총계** | **3대** | **3대** | **6 Nodes** | **28GB** |

### 네트워크 설계

```
┌─────────────────────────────────────────────────────────┐
│  macOS Host (Mac Studio M1 Max, 64GB RAM)              │
│  ┌───────────────────────────────────────────────────┐  │
│  │  Multipass Bridge Network (192.168.64.0/24)      │  │
│  │                                                   │  │
│  │  ┌──────────────┐  ┌──────────────┐  ┌─────────┐ │  │
│  │  │ mgmt cluster │  │ app1 cluster │  │  app2   │ │  │
│  │  │ pod: 10.100  │  │ pod: 10.101  │  │ 10.102  │ │  │
│  │  │ svc: 10.96   │  │ svc: 10.97   │  │ 10.98   │ │  │
│  │  └──────┬───────┘  └──────┬───────┘  └────┬────┘ │  │
│  │         └──────────────────┴───────────────┘      │  │
│  │              Cilium Cluster Mesh (VXLAN)         │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

---

## 🛠 사전 설치 요구사항

### 필수 도구
```bash
# OpenTofu (Terraform 오픈소스 대체)
brew install opentofu  # v1.11+

# (선택) Terraform 호환성을 위한 alias
echo 'alias terraform="tofu"' >> ~/.zshrc
source ~/.zshrc

# Multipass
brew install multipass  # v1.15.1+

# Helm
brew install helm

# kubectl
brew install kubectl

# jq (스크립트용)
brew install jq

# (선택) Istio CLI
brew install istioctl  # v1.29.0+
```

### 호스트 머신 스펙

| 리소스 | 최소 | 권장 |
|--------|------|------|
| **CPU** | 8코어 | 10코어 이상 |
| **RAM** | 32GB | 64GB |
| **디스크** | 256GB SSD | 512GB 이상 |
| **OS** | macOS 13+ | macOS 14+ |

---

## 🚀 빠른 시작

### 1. 저장소 클론
```bash
git clone https://github.com/your-org/mac-k8s-multipass-terraform.git
cd mac-k8s-multipass-terraform
```

### 2. 인프라 배포 (Phase 1)
```bash
# OpenTofu 초기화
tofu init

# 실행 계획 확인
tofu plan

# 인프라 배포 (VM + Kubernetes 클러스터)
tofu apply -auto-approve
```

**Phase 1에서 배포되는 항목:**
1. ✅ VM 생성 (6개 노드 - Multipass)
2. ✅ Kubernetes 클러스터 초기화 (kubeadm)
3. ✅ Worker 노드 Join
4. ✅ Kubeconfig 병합 (`~/kubeconfig-multi`)

**소요 시간**: 약 10-15분

### 3. Addon 설치 (Phase 2)
```bash
# 전체 Addon 설치
bash addons/install.sh --all

# 또는 카테고리별 설치
bash addons/install.sh --category networking      # Cilium, MetalLB
bash addons/install.sh --category observability   # Prometheus, Loki, Tempo, Grafana
bash addons/install.sh --category security        # Vault, Kyverno, Falco

# 또는 개별 설치
bash addons/install.sh vault argocd prometheus-stack
```

**Phase 2에서 설치되는 Addon:**
1. 네트워킹: Cilium CNI + Cluster Mesh, MetalLB, Gateway API
2. PKI & Secrets: cert-manager, Vault, External Secrets Operator
3. 관찰성: Prometheus Stack, Thanos, Loki, Tempo, Grafana, Kiali
4. Service Mesh: Istio, OpenTelemetry Collector
5. 보안: Kyverno, Falco, Tetragon
6. Platform: ArgoCD, K8sGPT, MinIO, Velero

**소요 시간**: 약 20-30분

자세한 Addon 설치 가이드는 [addons/README.md](addons/README.md)를 참조하세요.

### 4. kubeconfig 설정
```bash
# 병합된 kubeconfig 사용
export KUBECONFIG=~/kubeconfig-multi

# 클러스터 확인
kubectl config get-contexts
kubectl get nodes --all-namespaces
```

### 5. 검증
```bash
# 클러스터 상태 확인
./scripts/verify-clusters.sh

# Cilium Cluster Mesh 상태
cilium clustermesh status --context kubernetes-admin@mgmt
```

---

## 📂 프로젝트 구조

```
.
├── main.tf                    # OpenTofu 메인 구성
├── variables.tf               # 버전 및 설정 변수
├── locals.tf                  # 클러스터 정의 (DRY 원칙)
├── outputs.tf                 # 출력 정보
├── versions.tf                # OpenTofu/Terraform 버전 제약
├── templates/                 # cloud-init 템플릿
│   └── cloud-init-k8s.yaml.tpl
├── scripts/                   # 설치 스크립트 (28개)
│   ├── cluster-init.sh        # Kubernetes 초기화
│   ├── cluster-join.sh        # Worker 조인
│   ├── install-cilium.sh      # Cilium CNI + Cluster Mesh
│   ├── install-metallb.sh     # LoadBalancer
│   ├── install-cert-manager.sh
│   ├── install-vault.sh
│   ├── setup-vault-pki.sh     # Vault PKI Phase 2
│   ├── install-istio.sh       # Istio Service Mesh
│   ├── install-tempo.sh       # 분산 추적 백엔드
│   ├── install-otel-collector.sh  # 텔레메트리 수집
│   ├── install-kiali.sh       # Istio 관찰성 대시보드
│   ├── install-prometheus-stack.sh
│   ├── install-loki.sh
│   ├── install-argocd.sh
│   └── ...
├── generated/                 # 생성된 파일 (kubeconfig, join 스크립트 등)
└── document/                  # 설계 문서
    └── on-premise/
        ├── ARCHITECTURE.md           # 전체 아키텍처
        ├── IMPLEMENTATION-GUIDE.md   # 구현 가이드
        └── OPERATIONS-RUNBOOK.md     # 운영 런북
```

---

## 🔧 설치되는 플랫폼 서비스

### 전체 클러스터 (mgmt + app1 + app2)

| 구성 요소 | 버전 | 용도 |
|----------|------|------|
| **Cilium** | 1.19.0 | CNI + Cluster Mesh + Hubble |
| **Tetragon** | 1.3.0 | eBPF 런타임 보안 |
| **MetalLB** | v0.15.3 | LoadBalancer L2 모드 |
| **cert-manager** | v1.19.3 | PKI 관리 |
| **External Secrets Operator** | 0.14.3 | Vault 통합 |

### mgmt 클러스터 (플랫폼 중앙 허브)

| 구성 요소 | 네임스페이스 | 용도 |
|----------|-------------|------|
| **Vault** | vault | 시크릿/PKI 중앙 저장소 |
| **kube-prometheus-stack** | monitoring | Prometheus + Grafana + Alertmanager |
| **Thanos** | monitoring | 멀티클러스터 메트릭 집계 |
| **Loki** | monitoring | 로그 중앙 집계 |
| **ArgoCD** | argocd | GitOps 컨트롤러 |
| **MinIO** | minio | 백업 저장소 (S3 호환) |
| **Velero** | velero | 백업/복구 |
| **Trivy Operator** | trivy-system | 이미지/K8s 취약점 스캔 |
| **K8sGPT** | k8sgpt | AI 클러스터 진단 |
| **OpenCost** | opencost | 리소스 비용 가시화 |
| **VPA + Goldilocks** | vpa, goldilocks | 리소스 추천 |
| **Chaos Mesh** | chaos-mesh | 장애 주입 테스트 |

### app1/app2 클러스터 (워크로드)

| 구성 요소 | 용도 |
|----------|------|
| **Prometheus Agent** | 메트릭 수집 → Thanos Remote Write |
| **Promtail** | 로그 수집 → Loki |
| **Kyverno** | 정책 엔진 (enforce 모드) |
| **Falco** | 런타임 보안 |

### 🤖 AI 운영 도구 (mgmt 클러스터)

| 도구 | 네임스페이스 | 용도 | 상태 |
|------|-------------|------|------|
| **K8sGPT** | k8sgpt | Pod/Deployment 문제 자동 진단 | ✅ 자동 설치 |
| **HolmesGPT** | robusta | Prometheus 알림 근본 원인 분석 (RCA) | ✅ 자동 설치 |
| **kubectl-ai** | - | AI 기반 kubectl 명령어 생성 (로컬 CLI) | ⚠️ 수동 설치 |
| **Botkube** | botkube | Slack에서 클러스터 관리 | ⚠️ 선택적 (Slack 토큰 필요) |
| **LocalAI** | localai | 오픈소스 LLM 백엔드 (CPU 전용) | ✅ 자동 설치 |

#### AI 도구 사용법

**K8sGPT - 문제 진단**
```bash
# 분석 결과 확인
kubectl --context kubernetes-admin@mgmt -n k8sgpt get results

# 상세 정보
kubectl --context kubernetes-admin@mgmt -n k8sgpt describe result <result-name>
```

**HolmesGPT - 알림 조사**
```bash
# HolmesGPT 분석 로그 확인
kubectl --context kubernetes-admin@mgmt -n robusta logs deployment/robusta-runner -f | grep holmes

# Prometheus 알림 발생 시 자동으로 근본 원인 분석
```

**kubectl-ai - 로컬 설치 (선택적)**
```bash
# kubectl krew 플러그인 관리자 설치
brew install krew

# kubectl-ai 설치
kubectl krew install ai

# 사용 예시
kubectl ai "show me pods that are crashlooping"
kubectl ai "create a deployment for nginx with 3 replicas"
```

**Botkube - Slack 통합 (선택적)**
```bash
# Slack 토큰 준비 후 수동 설치
./scripts/install-botkube.sh

# Slack에서 사용
@botkube get pods
@botkube logs my-pod -n production
```

---

## 🌐 네트워크 및 서비스 접근

### LoadBalancer IP 범위 (MetalLB)

| 클러스터 | IP 범위 |
|---------|---------|
| mgmt | 192.168.64.200-210 |
| app1 | 192.168.64.211-220 |
| app2 | 192.168.64.221-230 |

### 주요 서비스 접속

```bash
# Grafana (mgmt)
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 \
  --context kubernetes-admin@mgmt
# http://localhost:3000 (admin/prom-operator)

# ArgoCD (mgmt)
kubectl port-forward -n argocd svc/argocd-server 8080:443 \
  --context kubernetes-admin@mgmt
# https://localhost:8080 (admin/<password>)

# Vault UI (mgmt)
kubectl port-forward -n vault svc/vault-ui 8200:8200 \
  --context kubernetes-admin@mgmt
# http://localhost:8200

# Hubble UI (Cilium)
cilium hubble ui --context kubernetes-admin@mgmt
```

---

## 🔐 보안 및 PKI

### 2-Phase PKI 부트스트랩 (ADR-004)

1. **Phase 1 (현재)**: Self-signed ClusterIssuer
   - cert-manager가 자체 서명 CA 생성
   - 초기 부트스트랩용

2. **Phase 2 (Istio 추가 시 전환 예정)**: Vault Issuer
   - Vault PKI Secrets Engine을 cert-manager Issuer로 설정
   - Istio Gateway 인증서 자동 발급/갱신
   - 중앙 집중식 인증서 관리

### 보안 계층

```
┌─────────────────────────────────────────┐
│  Layer 1: Pod Security Admission (PSA)  │  Kubernetes 기본
├─────────────────────────────────────────┤
│  Layer 2: Kyverno Policy Engine         │  정책 enforce
├─────────────────────────────────────────┤
│  Layer 3: Falco Runtime Security        │  행위 탐지
├─────────────────────────────────────────┤
│  Layer 4: Tetragon eBPF Observability   │  커널 레벨 감시
└─────────────────────────────────────────┘
```

---

## 📊 모니터링 및 관찰성

### 메트릭 수집 아키텍처

```
app1/app2 클러스터                     mgmt 클러스터
┌──────────────────┐                  ┌─────────────────┐
│ Prometheus Agent │ ─Remote Write─→  │ Thanos Receive  │
│ (로컬 WAL 2h)    │                  │                 │
└──────────────────┘                  └────────┬────────┘
                                              │
┌──────────────────┐                  ┌───────▼─────────┐
│ Promtail         │ ─────Push────→   │ Loki            │
│                  │                  │                 │
└──────────────────┘                  └────────┬────────┘
                                              │
                                      ┌───────▼─────────┐
                                      │ Grafana         │
                                      │ (통합 대시보드) │
                                      └─────────────────┘
```

---

## 🛡️ 백업 및 복구

### Velero + MinIO

- **백업 주기**: 일일 자동 백업 (선택적)
- **보관 정책**: 7일
- **백업 대상**:
  - Kubernetes 리소스 (YAML)
  - PVC 데이터 (Restic)
- **RPO**: 24시간
- **RTO**: 1시간 (클러스터 재생성 기준)

```bash
# 수동 백업
velero backup create manual-backup \
  --include-namespaces default,monitoring \
  --kubeconfig ~/kubeconfig-multi \
  --context kubernetes-admin@mgmt

# 복구
velero restore create --from-backup manual-backup
```

---

## 🚧 전체 삭제

```bash
# OpenTofu로 모든 리소스 삭제
tofu destroy -auto-approve

# 생성된 파일 정리
rm -rf generated/ .terraform/ .terraform.lock.hcl *.tfstate*

# Multipass 정리 (이중 확인)
multipass delete --all --purge
```

---

## 📚 문서

- **[ARCHITECTURE.md](document/on-premise/ARCHITECTURE.md)**: 전체 아키텍처 설계 및 ADR
- **[IMPLEMENTATION-GUIDE.md](document/on-premise/IMPLEMENTATION-GUIDE.md)**: 단계별 구현 가이드
- **[OPERATIONS-RUNBOOK.md](document/on-premise/OPERATIONS-RUNBOOK.md)**: 운영 런북
- **[REFACTORING-TODO.md](REFACTORING-TODO.md)**: 개선 작업 목록

---

## 🔮 로드맵

### v4.1 (완료)
- [x] **Istio Service Mesh 추가** (v1.29.0, Kubernetes 1.35 호환)
- [x] **Vault PKI Phase 2 전환** (Istio Gateway 인증서 자동 관리)
- [x] **OpenTofu 마이그레이션** (Terraform → OpenTofu, MPL 2.0 라이선스)
- [x] **관찰성 스택 완성** (Tempo + OTel Collector + Kiali)
- [x] **코드 리팩토링** (for_each 적용, 517줄 → 462줄)

### v4.2 (계획)
- [ ] Horizontal Pod Autoscaler 자동 구성
- [ ] Network Policies 자동 생성
- [ ] Disaster Recovery 자동화

---

## 🤝 기여

이슈 및 Pull Request 환영합니다!

---

## 📄 라이선스

MIT License

---

## 📞 문의

프로젝트 관련 문의: [GitHub Issues](https://github.com/your-org/mac-k8s-multipass-terraform/issues)
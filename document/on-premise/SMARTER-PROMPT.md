# On-Premise Kubernetes 클러스터 구축 프롬프트

> **SMART+ER 프롬프트 프레임워크** 기반 작성
> **참조 문서**: [ARCHITECTURE.md](ARCHITECTURE.md)
> **IaC 소스**: 본 프롬프트의 모든 내용은 실제 Terraform / Shell Script / Helm Values 코드에서 도출

---

## S: 상황

- macOS(Apple Silicon) 호스트에서 로컬 Kubernetes 클러스터 환경을 구축해야 합니다
- 개발/학습/시연 목적의 플랫폼 엔지니어링 환경을 로컬에서 재현하는 프로젝트입니다
- Multipass VM 위에 kubeadm v1.35(Timbernetes)로 단일 HA 클러스터를 프로비저닝합니다
- Terraform(`null_resource` + `local-exec`)으로 VM 생성 → Shell Script로 클러스터 부트스트랩 → Helm CLI로 애드온 설치하는 3단계 파이프라인입니다
- 단일 클러스터 내에 Control Plane 3노드(HA) + Worker 3노드, 총 6개 VM으로 구성합니다

### 현재 IaC 프로젝트 구조

```
mac-k8s-multipass-terraform/
├── main.tf                           # VM 프로비저닝 + 클러스터 초기화 오케스트레이션
├── variables.tf                      # masters(3), workers(3), multipass_image(24.04)
├── versions.tf                       # Terraform >= 1.11.3, hashicorp/null ~> 3.2
├── init/
│   └── k8s.yaml                      # cloud-init: containerd + kubeadm v1.35 설치
├── shell/
│   ├── cluster-init.sh               # kubeadm init + Flannel CNI + join 스크립트 생성
│   ├── join-all.sh                   # CP/Worker 노드 조인 + kubeconfig 복사
│   ├── delete-vm.sh                  # Multipass VM 전체 삭제
│   ├── mysql-install.sh              # MySQL VM 구성 (부가)
│   └── redis-install.sh              # Redis VM 구성 (부가)
└── addons/
    ├── install.sh                    # 12개 Helm 애드온 순차 설치 + DNS 매핑
    ├── uninstall.sh                  # Helm 릴리스 역순 삭제 + /etc/hosts 정리
    ├── verify.sh                     # 12개 릴리스 상태/Pod/LB 검증
    └── values/
        ├── metallb/metallb-config.yaml
        ├── rancher/local-path.yaml
        ├── istio/istio-values.yaml
        ├── argocd/argocd-values.yaml
        ├── monitoring/monitoring-values.yaml
        ├── logging/loki-values.yaml
        ├── logging/promtail-values.yaml
        ├── tracing/jaeger-values.yaml
        ├── tracing/otel-values.yaml
        ├── tracing/kiali-values.yaml
        └── vault/vault-values.yaml
```

## M: 목표

- **`terraform apply` 한 번으로** Multipass VM 6개 생성 → kubeadm HA 클러스터 부트스트랩까지 완전 자동화
- **`bash addons/install.sh` 한 번으로** 12개 플랫폼 컴포넌트(서비스 메시, 관찰성, GitOps, 시크릿) 일괄 설치
- Istio 서비스 메시(mTLS) 기반의 제로 트러스트 네트워크 구현
- Prometheus + Grafana + Loki + Promtail + Jaeger + OpenTelemetry로 메트릭/로그/트레이스 3-Pillar 관찰성 확보
- MetalLB L2 모드로 LoadBalancer 서비스 제공, `*.bocopile.io` 도메인 매핑
- HashiCorp Vault(Dev Mode)로 시크릿 관리 기반 마련
- ArgoCD로 GitOps 배포 파이프라인 구축

## A: 단계별 수행

"중요: 각 단계가 완료되면 사용자에게 결과를 확인받고 다음 단계 진행 여부 확인해야 합니다."

### Phase 1: 호스트 환경 준비

- 필수 도구 설치 확인: Multipass, Terraform >= 1.11.3, Helm CLI, kubectl, jq
- `versions.tf`의 provider 요구사항 충족 확인

```hcl
# versions.tf
terraform {
  required_version = ">= 1.11.3"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
```

### Phase 2: VM 프로비저닝 (Terraform)

- `terraform init && terraform apply`로 6개 VM 자동 생성
- 실행 순서: masters(3) → workers(3) → init_cluster → join_all (depends_on 체인)

```hcl
# main.tf - 핵심 리소스 5개
resource "null_resource" "masters"      # Multipass VM 3개 (4GB/40GB/2CPU)
resource "null_resource" "workers"      # Multipass VM 3개 (4GB/50GB/2CPU)
resource "null_resource" "init_cluster" # cluster-init.sh 실행
resource "null_resource" "join_all"     # join-all.sh 실행
resource "null_resource" "cleanup"      # terraform destroy 시 VM 전체 삭제
```

- cloud-init(`init/k8s.yaml`)이 각 VM에서 자동 실행:
  - 커널 모듈 로드: `overlay`, `br_netfilter`
  - sysctl 설정: `bridge-nf-call-iptables=1`, `ip_forward=1`
  - containerd 설치 + `SystemdCgroup = true` 설정
  - kubeadm/kubelet/kubectl v1.35 설치 + `apt-mark hold`

### Phase 3: kubeadm 클러스터 부트스트랩 (Shell Script)

- `cluster-init.sh`: k8s-master-0에서 kubeadm init 실행

```bash
kubeadm init \
  --control-plane-endpoint "${MASTER_IP}:6443" \
  --upload-certs \
  --pod-network-cidr=10.244.0.0/16
```

- Flannel CNI 자동 배포 (`kube-flannel.yml`)
- join 스크립트 자동 생성 (worker용 `join.sh` + CP용 `join-controlplane.sh`)

- `join-all.sh`: 나머지 5개 노드 조인
  - CP 노드 1, 2 → `join-controlplane.sh`로 조인
  - Worker 노드 0~2 → `join.sh`로 조인
  - kubeconfig를 `~/kubeconfig`로 복사, `KUBECONFIG` 환경변수 설정

### Phase 4: 플랫폼 애드온 설치 (Helm CLI)

- `bash addons/install.sh`로 12개 컴포넌트 순차 설치
- 설치 순서 및 의존성:

```
1. MetalLB          → IP 풀 할당 (sleep 40 대기)
2. Local Path       → 동적 스토리지 프로비저너
3. Istio Base       → CRD 설치
4. Istiod           → 컨트롤 플레인
5. Istio Gateway    → Ingress 게이트웨이
6. ArgoCD           → GitOps
7. Prometheus Stack → 메트릭 + Grafana
8. Loki             → 로그 집계
9. Promtail         → 로그 수집
10. Jaeger          → 분산 트레이싱
11. OTel Collector  → 텔레메트리 파이프라인
12. Kiali           → 서비스 메시 시각화
13. Vault           → 시크릿 관리
```

- 설치 후 LoadBalancer IP → `*.bocopile.io` 도메인 매핑 파일(`hosts.generated`) 자동 생성

### Phase 5: 검증

- `bash addons/verify.sh`로 12개 릴리스 상태 일괄 점검
  - Helm 릴리스 존재 여부
  - 네임스페이스 존재 여부
  - Running Pod 수 / 전체 Pod 수
  - LoadBalancer 서비스 수

## R: 결과물

실제 IaC 코드로 구현된 결과물:

### 1. Terraform 모듈 (3파일)

| 파일 | 역할 |
|-----|------|
| `main.tf` | `null_resource` 5개로 VM 생성 → 클러스터 초기화 → 노드 조인 → 삭제 오케스트레이션 |
| `variables.tf` | `masters(3)`, `workers(3)`, `multipass_image("24.04")` |
| `versions.tf` | Terraform >= 1.11.3, `hashicorp/null ~> 3.2` |

### 2. Shell Script (5파일)

| 파일 | 역할 |
|-----|------|
| `shell/cluster-init.sh` | kubeadm init + Flannel CNI + join 스크립트 생성 |
| `shell/join-all.sh` | CP/Worker 조인 + kubeconfig 복사 |
| `shell/delete-vm.sh` | Multipass VM 전체 삭제 (`jq` 파이프라인) |
| `shell/mysql-install.sh` | MySQL 사용자/DB 설정 |
| `shell/redis-install.sh` | Redis 비밀번호 설정 |

### 3. Helm Values (11파일) + 설치/삭제/검증 스크립트 (3파일)

| 컴포넌트 | Helm Chart | 네임스페이스 | Values 파일 | 핵심 설정 |
|---------|-----------|------------|-----------|----------|
| **MetalLB** | metallb/metallb | metallb-system | `metallb-config.yaml` | L2 모드, IP 풀 `192.168.65.200-250` |
| **Local Path** | containeroo/local-path-provisioner | local-path-storage | `local-path.yaml` | 기본 SC, Delete 정책, WaitForFirstConsumer |
| **Istio** | istio/base + istiod + gateway | istio-system, istio-ingress | `istio-values.yaml` | mTLS 전역, auto-inject, LB 게이트웨이(80/443) |
| **ArgoCD** | argo/argo-cd | argocd | `argocd-values.yaml` | LB 서비스, admin 비밀번호(bcrypt) |
| **Prometheus + Grafana** | prometheus-community/kube-prometheus-stack | monitoring | `monitoring-values.yaml` | Grafana LB, retention 7d, ServiceMonitor 전체 수집 |
| **Loki** | grafana/loki-stack | logging | `loki-values.yaml` | filesystem 백엔드, 10Gi PV(local-path), auth 비활성 |
| **Promtail** | grafana/promtail | logging | `promtail-values.yaml` | Loki push 엔드포인트 연결 |
| **Jaeger** | jaegertracing/jaeger | tracing | `jaeger-values.yaml` | memory 스토리지, Query LB |
| **OTel Collector** | open-telemetry/opentelemetry-collector | tracing | `otel-values.yaml` | OTLP gRPC/HTTP 수신, Jaeger OTLP 전송, 200m/256Mi |
| **Kiali** | kiali/kiali-server | istio-system | `kiali-values.yaml` | anonymous 인증, Prometheus/Jaeger 연동 |
| **Vault** | hashicorp/vault | vault | `vault-values.yaml` | Dev 모드, UI 활성, LB, external-dns 어노테이션 |

### 4. DNS 매핑 (*.bocopile.io)

| 도메인 | 서비스 |
|-------|--------|
| `argocd.bocopile.io` | argocd-server.argocd |
| `grafana.bocopile.io` | kube-prometheus-stack-grafana.monitoring |
| `jaeger.bocopile.io` | jaeger-query.tracing |
| `kiali.bocopile.io` | kiali.istio-system |
| `vault.bocopile.io` | vault.vault |

## T: 톤과 스타일

- 어조: 기술 문서 스타일의 간결하고 정확한 표현
- 언어: 쿠버네티스/인프라 실무 용어 사용, 약어는 첫 등장 시 풀네임 병기 (예: CNI(Container Network Interface))
- 형식: Mermaid 다이어그램으로 아키텍처 시각화, 비교/매핑 항목은 표(table) 사용, 코드 블록에는 언어 명시 (`hcl`, `yaml`, `bash` 등)
- 포함할 요소: 실제 코드 경로 참조, `terraform apply` / `bash addons/install.sh` 등 실행 가능한 명령어, Helm values의 핵심 파라미터
- 제외할 요소: 미구현 컴포넌트 언급, 클라우드 관리형 서비스 의존, Ansible/Helmfile 관련 내용
- 기타: 로컬(Multipass) 환경 제약사항을 명시하되, 프로덕션 환경 대비 차이점을 참고사항으로 안내

## E: 예시 참조

- **클러스터 토폴로지**:

| 역할 | 노드명 | VM 스펙 | 설명 |
|-----|--------|---------|------|
| Control Plane | k8s-master-0 | 4GB/40GB/2CPU | 초기 마스터 (kubeadm init 실행) |
| Control Plane | k8s-master-1 | 4GB/40GB/2CPU | CP 조인 |
| Control Plane | k8s-master-2 | 4GB/40GB/2CPU | CP 조인 |
| Worker | k8s-worker-0 | 4GB/50GB/2CPU | 워크로드 실행 |
| Worker | k8s-worker-1 | 4GB/50GB/2CPU | 워크로드 실행 |
| Worker | k8s-worker-2 | 4GB/50GB/2CPU | 워크로드 실행 |

- **네트워크 할당**:

| 항목 | 값 | 설정 위치 |
|-----|-----|----------|
| Pod CIDR | `10.244.0.0/16` | `shell/cluster-init.sh` (kubeadm init --pod-network-cidr) |
| CNI | Flannel | `shell/cluster-init.sh` (kube-flannel.yml) |
| MetalLB IP 풀 | `192.168.65.200-250` (51개) | `addons/values/metallb/metallb-config.yaml` |
| MetalLB 모드 | L2Advertisement | `addons/values/metallb/metallb-config.yaml` |
| Istio Gateway | HTTP(80→8080), HTTPS(443→8443) | `addons/values/istio/istio-values.yaml` |

- **관찰성 3-Pillar 매핑**:

| Pillar | 수집 | 저장 | 시각화 | 코드 참조 |
|--------|------|------|--------|----------|
| **메트릭** | Prometheus (kube-prometheus-stack) | 로컬 (7일 retention) | Grafana | `monitoring-values.yaml` |
| **로그** | Promtail → Loki push API | Loki filesystem (10Gi PV) | Grafana | `loki-values.yaml`, `promtail-values.yaml` |
| **트레이스** | OTel Collector (OTLP gRPC/HTTP) | Jaeger (memory) | Jaeger UI + Kiali | `otel-values.yaml`, `jaeger-values.yaml` |

- **리소스 예산 (VM 합계)**:

| 리소스 | CP (3노드) | Worker (3노드) | 합계 |
|--------|-----------|---------------|------|
| RAM | 12GB | 12GB | **24GB** |
| Disk | 120GB | 150GB | **270GB** |
| CPU | 6 vCPU | 6 vCPU | **12 vCPU** |

- **실행 명령어 요약**:

```bash
# 전체 인프라 생성 (VM + 클러스터)
terraform init && terraform apply -auto-approve

# 플랫폼 애드온 설치
cd addons && bash install.sh

# 설치 검증
bash verify.sh

# 전체 애드온 삭제
bash uninstall.sh

# 전체 인프라 삭제
terraform destroy -auto-approve
# 또는 수동: bash shell/delete-vm.sh
```

## R: 자료 참고

- **아키텍처 문서**: [ARCHITECTURE.md](ARCHITECTURE.md) - 클러스터 토폴로지, 네트워크, 보안, 관찰성 전체 설계
- **IaC 소스코드**: 본 리포지토리의 `main.tf`, `shell/`, `addons/` 디렉터리
- **기술 스택 공식 문서**:
  - kubeadm v1.35, containerd, Flannel CNI
  - Istio (서비스 메시, mTLS, Gateway)
  - MetalLB (L2 모드)
  - kube-prometheus-stack (Prometheus + Grafana)
  - Loki + Promtail (로그 수집/집계)
  - Jaeger + OpenTelemetry Collector (분산 트레이싱)
  - Kiali (서비스 메시 시각화)
  - ArgoCD (GitOps)
  - HashiCorp Vault (시크릿 관리)
  - Local Path Provisioner (동적 스토리지)
- **코드-문서 매핑 계약**:
  - C1: 모든 VM 스펙은 `main.tf`의 `multipass launch` 명령에서 도출
  - C2: 모든 네트워크 CIDR은 `cluster-init.sh`의 kubeadm 파라미터에서 도출
  - C3: 모든 Helm 설정은 `addons/values/` 디렉터리의 YAML 파일에서 도출
  - C4: 설치 순서는 `addons/install.sh`의 실행 순서를 따름
  - C5: 검증 항목은 `addons/verify.sh`의 ADDONS 배열과 일치

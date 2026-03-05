# mac-k8s-multipass-terraform

macOS(Apple Silicon) + Multipass + OpenTofu로 구축하는 **프로덕션급 Kubernetes 멀티클러스터 로컬 환경**.

Cilium, Istio, Vault, ArgoCD, Prometheus Stack 등 실무에서 사용하는 플랫폼 컴포넌트를 2단계 명령으로 완전 자동 설치합니다.

---

## 목차

1. [아키텍처 개요](#1-아키텍처-개요)
2. [사전 요구사항](#2-사전-요구사항)
3. [빠른 시작](#3-빠른-시작)
4. [Phase 0: Azure Infra 구성 (선택)](#4-phase-0-azure-infra-구성-선택)
5. [Phase 1: K8s 클러스터 생성](#5-phase-1-k8s-클러스터-생성)
6. [Phase 2: Addon 설치](#6-phase-2-addon-설치)
7. [서비스 접근](#7-서비스-접근)
8. [운영 명령어](#8-운영-명령어)
9. [전체 삭제](#9-전체-삭제)
10. [트러블슈팅](#10-트러블슈팅)

---

## 1. 아키텍처 개요

```
┌─────────────────────────────────────────────────────────────┐
│  macOS (Apple Silicon, 권장 64GB RAM / 540GB SSD)           │
│                                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                  │
│  │  mgmt    │  │  app1    │  │  app2    │  ← Multipass VM  │
│  │  CP+Wkr  │  │  CP+Wkr  │  │  CP+Wkr  │                  │
│  │  14GB    │  │  7GB     │  │  7GB     │                  │
│  └──────────┘  └──────────┘  └──────────┘                  │
│       │              │              │                       │
│       └──────────────┴──────────────┘                       │
│                  Cilium Cluster Mesh                        │
└─────────────────────────────────────────────────────────────┘
                          │ (선택)
         ┌────────────────┴────────────────┐
         │         Azure KoreaCentral      │
         │  ┌───────────┐  ┌───────────┐  │
         │  │ harbor-vm │  │ nexus-vm  │  │
         │  │ B2s/4GB   │  │ B2ms/8GB  │  │
         │  │ Harbor    │  │ Nexus3    │  │
         │  └───────────┘  └───────────┘  │
         └─────────────────────────────────┘
```

### 클러스터 역할

| 클러스터 | 역할 | 주요 컴포넌트 |
|---------|------|-------------|
| **mgmt** | 플랫폼 서비스 | Vault, Prometheus+Thanos, Loki, Grafana, Tempo, OpenSearch, ArgoCD, Velero+MinIO, Istio, K8sGPT, HolmesGPT |
| **app1** | 워크로드 A | Istio Sidecar, Kyverno, Falco, Grafana Alloy |
| **app2** | 워크로드 B | Kyverno, Falco, Grafana Alloy |

### VM 스펙

| VM | RAM | Disk | CPU |
|----|-----|------|-----|
| mgmt-cp | 4GB | 40GB | 2 |
| mgmt-worker-0 | 10GB | 60GB | 2 |
| app1-cp / app2-cp | 3GB 각 | 30GB 각 | 2 |
| app1-worker-0 / app2-worker-0 | 4GB 각 | 40GB 각 | 2 |
| **합계** | **28GB** | **240GB** | **12** |

### 기술 스택

| 영역 | 도구 |
|-----|------|
| IaC | OpenTofu 1.11+ |
| VM | Multipass (Ubuntu 24.04) |
| K8s | kubeadm v1.35, containerd |
| CNI | Cilium 1.19.0 (VXLAN + Cluster Mesh) |
| LB | MetalLB v0.15.3 (L2) |
| Ingress | Gateway API v1.2.1 + Istio 1.29.0 |
| GitOps | ArgoCD |
| 시크릿 | Vault + External Secrets Operator + cert-manager |
| 관찰성 | Prometheus · Thanos · Loki · Tempo · OpenSearch · Grafana Alloy · Hubble · Kiali |
| 보안 | Kyverno · Falco · Tetragon · Trivy · PSA |
| AIOps | K8sGPT · HolmesGPT · OpenCost · VPA · Chaos Mesh |
| 백업 | Velero + MinIO |

---

## 2. 사전 요구사항

### 하드웨어

- **CPU**: Apple Silicon (M1/M2/M3) 권장
- **RAM**: 최소 48GB, **권장 64GB**
- **Disk**: 최소 300GB 여유 공간

### 필수 소프트웨어

```bash
# Homebrew 패키지 관리자
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 필수 도구 일괄 설치
brew install opentofu multipass kubectl helm jq

# 설치 확인
tofu version    # >= 1.11.3
multipass version
kubectl version --client
helm version
jq --version
```

### 선택 소프트웨어 (Azure Infra 사용 시)

```bash
# Azure CLI
brew install azure-cli

# 로그인
az login

# 구독 확인
az account show
```

---

## 3. 빠른 시작

Azure Infra(Harbor/Nexus) 없이 **K8s 클러스터만** 구성하는 최단 경로입니다.

```bash
# 1. 저장소 클론
git clone <repo-url>
cd mac-k8s-multipass-terraform

# 2. K8s 클러스터 생성 (10~15분)
tofu init
tofu apply -auto-approve

# 3. kubeconfig 설정
export KUBECONFIG=~/kubeconfig-multi

# 4. 클러스터 확인
kubectl get nodes --context kubernetes-admin@mgmt
kubectl get nodes --context kubernetes-admin@app1
kubectl get nodes --context kubernetes-admin@app2

# 5. Addon 전체 설치 (20~30분)
bash addons/install.sh --all

# 6. /etc/hosts 자동 업데이트 (서비스 도메인 등록)
sudo bash scripts/update-hosts-mac.sh
```

---

## 4. Phase 0: Azure Infra 구성 (선택)

Harbor(컨테이너 레지스트리)와 Nexus(라이브러리 저장소)를 Azure VM으로 구성합니다.
**K8s 클러스터와 독립 운영** — 로컬 K8s를 재구성해도 이미지/아티팩트가 보존됩니다.

> Azure를 사용하지 않는 경우 이 단계를 건너뛰세요.

### 4.1 tfvars 설정

```bash
cd azure-infra
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` 필수 항목 수정:

```hcl
# 리소스 그룹 이름 (tofu destroy 시 전체 일괄 삭제)
resource_group_name = "rg-infra-registry"

# Harbor admin 비밀번호 (대소문자+숫자+특수문자 필수)
harbor_admin_password = "Harbor@Admin2024!"
```

선택 항목 (기본값으로도 동작):

```hcl
# SSH 접근 CIDR 제한 (보안 강화 시)
# curl https://checkip.amazonaws.com 으로 본인 IP 확인
# allowed_ssh_cidr = "1.2.3.4/32"

# VM 크기 / 디스크 / 리전 등 기본값 사용 가능
```

### 4.2 배포

```bash
# azure-infra 디렉토리에서 실행
cd azure-infra

tofu init
tofu apply -auto-approve

# 완료 후 출력 확인
# harbor_public_ip = "X.X.X.X"
# nexus_public_ip  = "X.X.X.X"
# ssh_harbor = "ssh -i ../generated/azure-infra-key.pem azureuser@X.X.X.X"
```

> 배포 완료 시 IP가 `generated/harbor-ip`, `generated/nexus-ip`에 자동 저장됩니다.

### 4.3 K8s 노드 연동 (K8s 클러스터 생성 후)

```bash
# 루트 디렉토리에서 실행
cd ..
bash scripts/configure-k8s-for-azure-infra.sh
```

이 스크립트는 모든 K8s 노드에 다음을 자동 적용합니다:
- `/etc/hosts`에 harbor/nexus 도메인 추가
- containerd certs.d 설정 (Harbor HTTP insecure 허용)

### 4.4 Nexus 초기 admin 비밀번호 확인

```bash
cat generated/nexus-admin-password
# 또는
ssh -i generated/azure-infra-key.pem azureuser@$(cat generated/nexus-ip) \
  "sudo docker exec nexus cat /nexus-data/admin.password"
```

---

## 5. Phase 1: K8s 클러스터 생성

### 5.1 초기화 및 배포

```bash
# 루트 디렉토리에서 실행
cd mac-k8s-multipass-terraform

tofu init
tofu apply -auto-approve
```

**내부 실행 순서:**
```
cloud-init 렌더링
  → VM 6개 생성 (Multipass)
    → kubeadm init (각 클러스터 CP)
      → kubeadm join (각 클러스터 Worker)
        → kubeconfig 병합 → generated/kubeconfig-multi
```

### 5.2 생성 결과 확인

```bash
export KUBECONFIG=~/kubeconfig-multi

# 전체 노드 확인
kubectl get nodes --context kubernetes-admin@mgmt
kubectl get nodes --context kubernetes-admin@app1
kubectl get nodes --context kubernetes-admin@app2

# 클러스터 정보
tofu output clusters
```

### 5.3 버전 변수 (선택)

기본값으로 동작하지만, `terraform.tfvars` 생성으로 재정의 가능합니다:

```hcl
# 루트 terraform.tfvars (선택)
k8s_version    = "1.35"
cilium_version = "1.19.0"
istio_version  = "1.29.0"
```

---

## 6. Phase 2: Addon 설치

K8s 클러스터 생성 완료 후 실행합니다.

### 6.1 전체 설치 (권장)

```bash
# 대화형 (확인 프롬프트 있음)
bash addons/install.sh --all

# 자동화 환경 (확인 없이 즉시 실행)
bash addons/install.sh --all --yes
```

**설치 순서 및 소요 시간** (총 20~30분):

| 순서 | 카테고리 | 주요 컴포넌트 |
|------|---------|-------------|
| 1 | infrastructure | priority-classes, Cilium, Tetragon, MetalLB, Gateway API, Cluster Mesh, cert-manager |
| 2 | secrets | Vault, Vault PKI, External Secrets Operator |
| 3 | gitops | ArgoCD |
| 4 | backup | MinIO, Velero |
| 5 | observability | Thanos, Prometheus+Grafana, Loki, Tempo, OpenSearch, Grafana Alloy |
| 6 | servicemesh | Istio, Kiali |
| 7 | security | Kyverno, Falco, Platform Addons (Trivy, OpenCost, VPA, Chaos Mesh) |
| 8 | aiops | K8sGPT, HolmesGPT |

### 6.2 카테고리별 설치

```bash
# 카테고리만 설치
bash addons/install.sh --category infrastructure
bash addons/install.sh --category secrets
bash addons/install.sh --category observability
bash addons/install.sh --category servicemesh
bash addons/install.sh --category security
bash addons/install.sh --category aiops
bash addons/install.sh --category backup
```

### 6.3 특정 Addon만 설치

```bash
# 하나씩
bash addons/install.sh vault

# 여러 개
bash addons/install.sh vault argocd prometheus-stack

# 설치 가능 목록 확인
bash addons/install.sh --list
```

### 6.4 Addon 제거

```bash
# 특정 addon 제거
bash addons/uninstall.sh prometheus-stack loki

# 전체 제거
bash addons/uninstall.sh --all

# 확인 없이 즉시 제거
bash addons/uninstall.sh --all --force
```

### 6.5 설치 후 hosts 업데이트

```bash
# LoadBalancer IP를 /etc/hosts에 자동 등록 (sudo 필요)
sudo bash scripts/update-hosts-mac.sh
```

---

## 7. 서비스 접근

### 7.1 도메인 접근 (권장)

`update-hosts-mac.sh` 실행 후 브라우저에서 직접 접근합니다.

| 서비스 | URL | 기본 자격증명 |
|--------|-----|-------------|
| **Grafana** | http://grafana.bocopile.io | admin / [credentials.env 참조] |
| **Prometheus** | http://prometheus.bocopile.io | - |
| **Alertmanager** | http://alertmanager.bocopile.io | - |
| **ArgoCD** | http://argocd.bocopile.io | admin / [K8s secret] |
| **Vault** | http://vault.bocopile.io | [vault-root-token] |
| **Kiali** | http://kiali.bocopile.io | anonymous |
| **Harbor** | http://harbor.bocopile.io | admin / [tfvars 설정값] |
| **Nexus** | http://nexus.bocopile.io:8081 | admin / [nexus-admin-password] |

```bash
# Istio Gateway를 통한 bocopile.io 도메인 등록
bash scripts/update-hosts-bocopile.sh
```

### 7.2 Port-Forward 방식

도메인 없이 임시 접근이 필요한 경우:

```bash
export KUBECONFIG=~/kubeconfig-multi

# Grafana
kubectl --context kubernetes-admin@mgmt -n monitoring \
  port-forward svc/kube-prometheus-stack-grafana 3000:80

# ArgoCD
kubectl --context kubernetes-admin@mgmt -n argocd \
  port-forward svc/argocd-server 8080:443

# Vault
kubectl --context kubernetes-admin@mgmt -n vault \
  port-forward svc/vault 8200:8200

# Kiali
kubectl --context kubernetes-admin@mgmt -n istio-system \
  port-forward svc/kiali 20001:20001

# Prometheus
kubectl --context kubernetes-admin@mgmt -n monitoring \
  port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

### 7.3 자격증명 조회

```bash
# 전체 자격증명 (MinIO 등 자동 생성 비밀번호)
cat generated/.credentials.env

# Vault root token
cat generated/vault-root-token

# ArgoCD admin 비밀번호
kubectl --kubeconfig ~/kubeconfig-multi --context kubernetes-admin@mgmt \
  -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo

# Nexus 초기 admin 비밀번호
cat generated/nexus-admin-password
```

### 7.4 Azure Infra VM SSH 접속

```bash
SSH_KEY="generated/azure-infra-key.pem"

# Harbor
ssh -i $SSH_KEY azureuser@$(cat generated/harbor-ip)

# Nexus
ssh -i $SSH_KEY azureuser@$(cat generated/nexus-ip)

# Harbor 서비스 상태 확인
ssh -i $SSH_KEY azureuser@$(cat generated/harbor-ip) \
  "sudo docker compose -f /tmp/harbor/docker-compose.yml ps"

# Nexus 서비스 상태 확인
ssh -i $SSH_KEY azureuser@$(cat generated/nexus-ip) \
  "sudo docker compose -f /opt/nexus/docker-compose.yml ps"
```

---

## 8. 운영 명령어

### 8.1 클러스터 상태 확인

```bash
export KUBECONFIG=~/kubeconfig-multi

# 전체 노드 상태
for ctx in mgmt app1 app2; do
  echo "=== $ctx ==="
  kubectl get nodes --context kubernetes-admin@$ctx
done

# 클러스터별 Pod 전체 확인
kubectl get pods -A --context kubernetes-admin@mgmt

# Cilium 상태
cilium status --kubeconfig ~/kubeconfig-multi --context kubernetes-admin@mgmt

# Cluster Mesh 상태
cilium clustermesh status --kubeconfig ~/kubeconfig-multi --context kubernetes-admin@mgmt
```

### 8.2 LoadBalancer IP 확인

```bash
bash scripts/show-loadbalancer-ips.sh
```

### 8.3 클러스터 검증

```bash
bash scripts/verify-clusters.sh
```

### 8.4 Addon 검증

```bash
bash addons/verify.sh
```

### 8.5 Multipass VM 관리

```bash
# VM 목록 및 상태
multipass list

# VM 중지 (리소스 절약)
multipass stop mgmt-cp mgmt-worker-0 app1-cp app1-worker-0 app2-cp app2-worker-0

# VM 재시작
multipass start mgmt-cp mgmt-worker-0 app1-cp app1-worker-0 app2-cp app2-worker-0

# VM 내부 접속
multipass shell mgmt-worker-0
```

### 8.6 네트워크 정책 적용

```bash
# 플랫폼 Namespace에 deny-all 기반 네트워크 정책 적용
bash addons/scripts/apply-network-policies.sh
```

### 8.7 Botkube 설치 (Slack 연동, 수동)

Slack 토큰이 필요하여 별도 수동 설치합니다:

```bash
# Botkube values 파일에 Slack 토큰 설정 후
bash addons/scripts/install-botkube.sh
```

---

## 9. 전체 삭제

### 9.1 K8s 클러스터 + Azure Infra 동시 삭제

루트 디렉토리에서 `tofu destroy`를 실행하면 **Multipass VM과 Azure VM이 모두 삭제**됩니다.

```bash
# 루트 디렉토리에서 실행
tofu destroy -auto-approve
```

**삭제 순서:**
1. `null_resource.destroy_azure_infra` → `azure-infra/` 내 `tofu destroy -auto-approve` 실행 (Harbor VM + Nexus VM + 네트워크 리소스)
2. `null_resource.cleanup` → 모든 Multipass VM 삭제

> **조건**: `azure-infra/terraform.tfstate`와 `azure-infra/terraform.tfvars`가 모두 존재해야 Azure 리소스가 삭제됩니다. 파일이 없으면 조용히 스킵됩니다.

### 9.2 Azure Infra만 별도 삭제

```bash
cd azure-infra
tofu destroy -auto-approve
```

### 9.3 K8s 클러스터만 삭제 (Azure 유지)

Azure 리소스를 유지한 채 로컬 K8s 클러스터만 삭제하려면 `azure-infra/terraform.tfstate`를 임시 이동하세요.

```bash
# azure-infra 상태를 백업하여 destroy 연동 비활성화
mv azure-infra/terraform.tfstate azure-infra/terraform.tfstate.bak

# K8s 클러스터만 삭제
tofu destroy -auto-approve

# 상태 복원
mv azure-infra/terraform.tfstate.bak azure-infra/terraform.tfstate
```

### 9.4 Addon만 제거

```bash
bash addons/uninstall.sh --all --force
```

---

## 10. 트러블슈팅

### 10.1 첫 실행 시 `generated/` 디렉토리 오류

```
Error: directory does not exist
```

```bash
mkdir -p generated
tofu apply -auto-approve
```

### 10.2 kubeconfig 병합 실패

```bash
# 수동으로 kubeconfig 병합
bash scripts/merge-kubeconfigs.sh

export KUBECONFIG=~/kubeconfig-multi
```

### 10.3 Cilium 설치 실패

```bash
# Cilium CLI 설치 여부 확인
cilium version

# 수동 설치 (기본 버전 사용)
bash addons/scripts/install-cilium.sh

# 특정 버전 지정
CILIUM_VERSION=1.19.0 bash addons/scripts/install-cilium.sh
```

### 10.4 MetalLB IP 할당 안 됨

MetalLB가 사용하는 IP 대역(`192.168.64.x`)이 Multipass 브리지 네트워크와 일치하는지 확인합니다.

```bash
# Multipass 네트워크 확인
multipass info mgmt-cp | grep IPv4

# MetalLB IPAddressPool 확인
kubectl --context kubernetes-admin@mgmt -n metallb-system get ipaddresspools
```

### 10.5 Vault 초기화 실패

```bash
# Vault Pod 상태 확인
kubectl --context kubernetes-admin@mgmt -n vault get pods

# Vault 초기화 상태 확인
kubectl --context kubernetes-admin@mgmt -n vault exec -it vault-0 -- vault status

# 수동 재실행
bash addons/scripts/install-vault.sh
bash addons/scripts/setup-vault-pki.sh
```

### 10.6 특정 Addon 재설치

```bash
# 예: prometheus-stack 재설치
bash addons/uninstall.sh prometheus-stack
bash addons/install.sh prometheus-stack
```

### 10.7 Azure Infra SSH 연결 실패

```bash
# 공인 IP 확인
cat generated/harbor-ip
cat generated/nexus-ip

# SSH 키 권한 확인
ls -la generated/azure-infra-key.pem
# 0600이어야 함

# 연결 테스트
ssh -v -i generated/azure-infra-key.pem azureuser@$(cat generated/harbor-ip)
```

### 10.8 tofu destroy 시 Azure 삭제 스킵됨

```
=== Azure Infra: state/tfvars 없음 → 스킵 ===
```

다음 중 하나를 확인하세요:

```bash
# 파일 존재 여부 확인
ls -la azure-infra/terraform.tfstate
ls -la azure-infra/terraform.tfvars

# azure-infra가 아직 apply되지 않은 경우 정상 동작
# azure-infra를 별도로 destroy하려면:
cd azure-infra && tofu destroy -auto-approve
```

---

## 프로젝트 구조

```
.
├── main.tf                     # VM 생성, 클러스터 초기화, Azure 연동 삭제
├── locals.tf                   # 클러스터 정의 (CIDR, 노드 스펙)
├── variables.tf                # 버전 변수 (K8s, Cilium, Istio 등)
├── versions.tf                 # OpenTofu 버전 및 provider 요구사항
├── outputs.tf                  # 클러스터 정보 출력
│
├── azure-infra/                # Azure Harbor/Nexus VM (선택)
│   ├── main.tf                 # Azure 리소스 + Harbor/Nexus 설치
│   ├── variables.tf            # Azure 설정 변수
│   ├── terraform.tfvars.example
│   └── scripts/
│       ├── harbor-setup.sh.tpl
│       └── nexus-setup.sh
│
├── addons/
│   ├── install.sh              # Addon 일괄 설치 (--all / --category / --yes)
│   ├── uninstall.sh            # Addon 일괄 제거 (--all / --force)
│   ├── verify.sh               # 설치 상태 검증
│   └── scripts/                # 개별 Addon 설치 스크립트
│       ├── install-cilium.sh
│       ├── install-metallb.sh
│       ├── install-vault.sh
│       ├── setup-vault-pki.sh
│       ├── setup-clustermesh.sh
│       └── ... (30+ 스크립트)
│
├── scripts/
│   ├── configure-k8s-for-azure-infra.sh  # K8s 노드 ↔ Azure 연결 설정
│   ├── update-hosts-mac.sh               # /etc/hosts 자동 업데이트
│   ├── merge-kubeconfigs.sh              # kubeconfig 병합
│   ├── verify-clusters.sh                # 클러스터 검증
│   ├── show-loadbalancer-ips.sh          # LB IP 조회
│   └── lib/
│       ├── common.sh                     # 공통 함수 (16개)
│       └── constants.sh                  # 공통 상수 (50+개)
│
├── templates/
│   ├── cloud-init-k8s.yaml.tpl           # K8s VM cloud-init
│   └── cloud-init-infra.yaml.tpl         # Azure Infra VM cloud-init
│
└── generated/                            # 자동 생성 파일 (.gitignore)
    ├── kubeconfig-multi                  # 병합된 kubeconfig
    ├── clusters.json                     # 클러스터 메타데이터
    ├── .credentials.env                  # 자동 생성 자격증명 (chmod 600)
    ├── vault-root-token                  # Vault root token
    ├── harbor-ip                         # Harbor 공인 IP
    ├── nexus-ip                          # Nexus 공인 IP
    └── azure-infra-key.pem               # Azure SSH 키 (chmod 600)
```

---

## 참고

- 상세 아키텍처: [`document/on-premise/ARCHITECTURE.md`](document/on-premise/ARCHITECTURE.md)
- Azure 비용: harbor-vm ~$35/월 + nexus-vm ~$60/월 + Public IP/Disk ~$33/월 ≈ **약 $128/월**
- 사용하지 않을 때 Azure VM 중지로 컴퓨팅 비용 절감 가능 (디스크 비용은 유지됨)

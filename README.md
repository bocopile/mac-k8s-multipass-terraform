# Kubernetes Multi-Node Cluster on macOS (Multipass + Terraform)

해당 프로젝트는 **macOS (M1/M2 포함)** 환경에서 기존 UTM 기반으로 설치하는 방법 대신 Multipass, Terraform을 이용하여 다음과 같은 **Kubernetes 멀티 노드 클러스터 환경**을 자동으로 구축하는데 그 목적을 둔다.

## 사전 설치 사항
- Terraform v1.11.3 이상 : [Terraform 설치 링크](https://developer.hashicorp.com/terraform/install)
- multipass v1.15.1+mac : [multipass 설치 링크](https://canonical.com/multipass)
- istioctl v1.26.2 :  [istioctl 설치 링크](https://formulae.brew.sh/formula/istioctl)
- helm : [helm 설치 링크](https://helm.sh/ko/docs/intro/install/)

## 구성 요소
| 구성 요소 | 수량 | 설명 |
|-----------|------|------|
| Control Plane (Master) | 3대 | 고가용성 멀티 마스터 |
| Worker Node | 6대 | 서비스 워크로드 처리 |
| Redis VM | 1대 | Kubernetes 외부 Redis (패스워드 설정 포함) |
| MySQL VM | 1대 | Kubernetes 외부 MySQL (DB/계정 자동 생성 포함) |
| Flannel | ✅ | Pod 간 통신을 위한 CNI 플러그인 |
| Terraform | ✅ | 인프라 정의 및 상태 관리 |
| Multipass | ✅ | 로컬 VM 기반 클러스터 실행 |

## 구조
```
.
├── init/
│   ├── k8s.yaml             # K8s용 cloud-init
│   ├── redis.yaml           # Redis VM용 cloud-init
│   └── mysql.yaml           # MySQL VM용 cloud-init
├── shell/
│   ├── cluster-init.sh      # kubeadm init 실행
│   ├── join-all.sh          # Master/Worker 자동 Join
│   ├── redis-install.sh     # Redis 패스워드 설정
│   └── mysql-install.sh     # MySQL 루트/유저/DB 설정
├── main.tf                  # Terraform 메인 구성
├── variables.tf             # Redis/MySQL 계정/포트 변수
└── README.md                # 사용 설명서
```

## 설치 방법

### 1. 초기화 및 배포
```bash
terraform init && terraform plan
terraform apply -auto-approve
```

### 2. 전체 삭제
```bash
terraform destroy -auto-approve
rm -rf .terraform .terraform.lock.hcl terraform.tfstate* kubeconfig
```

## 🔐 Redis/MySQL 접속 정보

Terraform `variables.tf` 에 정의된 기본값 기준으로 세팅

### Redis
- Host: `redis` VM IP
- Port: `6379`
- Password: `redispass`

### MySQL
- Host: `mysql` VM IP
- Port: `3306`
- User: `finalyzer`
- Password: `finalyzerpass`
- Database: `finalyzer`

---

# 🔧 Add-ons 설치 가이드 (`addon`)

이 프로젝트는 로컬 Mac 환경의 Kubernetes 클러스터에 다양한 Add-on(Observability, GitOps, Security 등)을 설치하고 설정하기 위한 자동화된 스크립트를 제공합니다. 모든 Add-on은 Helm Chart와 `values/` 디렉토리에 정의된 설정 파일 기반으로 설치됩니다.

## 📁 디렉토리 구조

```
addon/
├── install.sh               # 전체 Add-on을 순차 설치하는 스크립트
├── uninstall.sh             # 전체 Add-on을 제거하는 스크립트
├── verify.sh                # Add-on 설치 여부 및 접근성 확인 스크립트
├── hosts.generated          # xxx.bocopile.io 도메인용 hosts 매핑 파일
└── values/                  # Helm values.yaml 모음
    ├── argocd/
    ├── istio/
    ├── logging/
    ├── metallb/
    ├── monitoring/
    ├── tracing/
    └── vault/
```

## 🚀 설치 방법

### 1. 사전 조건
- Kubernetes 클러스터가 로컬에서 실행 중이어야 함 (multipass + kubeadm 기반)
- `xxx.bocopile.io` 도메인에 대한 hosts 매핑 필요 (`/etc/hosts`)

### 2. Add-on 일괄 설치

```bash
cd addon
./install.sh
```

> MetalLB -> my-local-path-provisioner ->  Istio →  ArgoCD → Vault → Monitoring → Logging → Tracing -> vault  순으로 설치됩니다.  
> 설치 후 host 파일을 추가해야 `*.bocopile.io` 형태의 로컬 도메인으로 각 서비스에 접속할 수 있습니다.

### 3. 설치 확인

```bash
./verify.sh
```

서비스별 도메인 응답 여부, Pod 상태 등을 자동 확인합니다.

### 4. 전체 삭제

```bash
./uninstall.sh
```

모든 Add-on 리소스를 제거합니다.

## 🧩 포함된 Add-on 목록

| Add-on    | 설명 |
|-----------|------|
| **Istio** | Service Mesh, Ingress Gateway 및 mTLS 설정 포함 |
| **ArgoCD** | GitOps 기반 애플리케이션 배포 관리 |
| **Vault** | 인증서 및 시크릿 자동 관리 시스템 |
| **Prometheus-Grafana** | 모니터링 대시보드 및 메트릭 수집 |
| **Loki-Promtail** | 로그 수집 및 검색 |
| **Jaeger, Kiali, OpenTelemetry** | 트레이싱 및 Service Mesh 시각화 도구 |
| **MetalLB** | 로컬 환경에서 LoadBalancer 형태 지원을 위한 IP 제공 |

## 🌐 로컬 도메인 설정

`install.sh` 실행 시 자동 생성되는 `hosts.generated` 파일을 `/etc/hosts`에 반영해야 각 서비스에 브라우저 접속이 가능합니다.

```bash
sudo cp hosts.generated /etc/hosts
```

> 예시:  
> `http://grafana.bocopile.io`  
> `https://argocd.bocopile.io`

## 🔒 TLS 및 인증서

Istio Gateway와 Vault를 활용하여 TLS 및 인증서 자동 관리 구조로 확장 가능합니다. `vault-values.yaml`과 `istio-values.yaml`을 커스터마이징하여 원하는 도메인 및 인증 흐름을 구성하세요.

## 📎 Helm values 커스터마이징

각 Add-on은 `values/<addon>` 디렉토리에 별도의 values.yaml이 존재하며, 도메인명, 인증 여부, 리소스 설정 등을 자유롭게 수정할 수 있습니다.
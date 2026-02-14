# Azure AKS 멀티클러스터 아키텍처 구축 프롬프트

> **SMART+ER 프롬프트 프레임워크** 기반 작성
> **참조 문서**: [ARCHITECTURE.md](ARCHITECTURE.md)
> **IaC 소스**: 본 프롬프트의 모든 내용은 `azure/` 디렉터리의 실제 Terraform / Helm Values / Shell Script 코드에서 도출

---

## S: 상황

- Azure 클라우드에서 Kubernetes 멀티클러스터 환경을 구축해야 합니다
- 시연 및 개발(PoC) 목적으로, Spot VM + AKS Free Tier로 월 $60-80 비용 최적화가 핵심 제약사항입니다
- 리전은 Korea Central이며, AKS(Azure Kubernetes Service)를 기반으로 합니다
- Terraform 모듈(vnet, aks, keyvault, observability) 4개로 인프라를 코드화했습니다
- 클러스터 3개: AKS-mgmt(1 Spot 노드) + AKS-app1(2 Spot 노드) + AKS-app2(2 Spot 노드)

### 현재 IaC 프로젝트 구조

```
azure/
├── main.tf                          # Root: RG + 4개 모듈 호출
├── variables.tf                     # 입력 변수 (location, vm_size, node_count 등)
├── outputs.tf                       # 출력 (클러스터명, kubeconfig 명령어)
├── versions.tf                      # azurerm ~> 3.0 + backend(Azure Storage)
├── terraform.tfvars.example         # 변수 예시 파일
├── modules/
│   ├── vnet/                        # VNet + 4 Subnets + 3 NSG + NSG↔Subnet 연결
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── aks/                         # AKS Cluster + Spot Node Pool (재사용 모듈)
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── keyvault/                    # Key Vault + Workload Identity + Role Assignment
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── observability/               # Log Analytics + Container Insights
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
├── addons/
│   ├── install.sh                   # Cilium + ArgoCD + ESO 설치 (3 클러스터)
│   ├── uninstall.sh                 # 애드온 역순 삭제
│   └── values/
│       ├── argocd-values.yaml       # ArgoCD Helm values
│       └── external-secrets-values.yaml  # ESO Helm values
└── scripts/
    ├── setup-kubeconfig.sh          # 3 클러스터 kubeconfig 일괄 등록
    └── cleanup.sh                   # 리소스 그룹 전체 삭제
```

## M: 목표

- **`terraform apply` 한 번으로** Azure 인프라 전체 생성: RG + VNet(4 Subnet) + AKS 3개 + Key Vault + Log Analytics
- **`bash addons/install.sh` 한 번으로** Cilium BYO CNI(3 클러스터) + ArgoCD(mgmt) + External Secrets(mgmt) 설치
- Spot VM(Standard_D2s_v3)으로 전 노드 운영, 월 **$60-80** 비용 목표
- Cilium BYO CNI(eBPF) 기반 네트워크 정책 + 멀티클러스터 서비스 디스커버리 기반 마련
- Azure Key Vault + Workload Identity + External Secrets Operator로 시크릿 관리
- Azure Monitor + Container Insights로 3개 클러스터 중앙 관찰성
- ArgoCD로 3개 클러스터 GitOps 배포 파이프라인

## A: 단계별 수행

"중요: 각 단계가 완료되면 사용자에게 결과를 확인받고 다음 단계 진행 여부 확인해야 합니다."

### Phase 1: 사전 준비

- 필수 도구 설치: Azure CLI, Terraform >= 1.11.0, Helm v3+, kubectl
- Azure 로그인 및 구독 설정

```bash
az login
az account set --subscription "<subscription-id>"
```

- Terraform State 백엔드용 Azure Storage 사전 생성

```hcl
# azure/versions.tf
backend "azurerm" {
  resource_group_name  = "rg-terraform-state"
  storage_account_name = "stterraformstate"
  container_name       = "tfstate"
  key                  = "k8s-demo.tfstate"
}
```

### Phase 2: Azure 인프라 프로비저닝 (Terraform)

- `terraform init && terraform apply`로 전체 인프라 자동 생성
- `azure/main.tf`가 4개 모듈을 순서대로 호출:

```
1. azurerm_resource_group  → rg-k8s-demo (Korea Central)
2. module "vnet"           → VNet(10.0.0.0/8) + 4 Subnets + 3 NSG
3. module "observability"  → Log Analytics(5GB/일, 30일) + Container Insights
4. module "aks_mgmt"       → AKS-mgmt (System 1노드 + Spot 1노드)
5. module "aks_app1"       → AKS-app1 (System 1노드 + Spot 2노드)
6. module "aks_app2"       → AKS-app2 (System 1노드 + Spot 2노드)
7. module "keyvault"       → Key Vault + Workload Identity + Role Assignment
```

- AKS 모듈 핵심 설정 (`modules/aks/main.tf`):
  - `network_plugin = "none"` → Cilium BYO CNI (ADR-A02)
  - `oidc_issuer_enabled = true` + `workload_identity_enabled = true` → Workload Identity
  - `oms_agent` → Container Insights 연동
  - `azure_policy_enabled = true` → Azure Policy for AKS

### Phase 3: Spot Node Pool 구성

- 각 AKS 클러스터에 Spot Node Pool 자동 생성 (`modules/aks/main.tf`):

```hcl
resource "azurerm_kubernetes_cluster_node_pool" "spot" {
  priority        = "Spot"
  eviction_policy = "Delete"
  spot_max_price  = var.spot_max_price  # -1 = On-Demand까지 허용
  node_labels = { "kubernetes.azure.com/scalesetpriority" = "spot" }
  node_taints = [ "kubernetes.azure.com/scalesetpriority=spot:NoSchedule" ]
}
```

### Phase 4: 플랫폼 애드온 설치 (Helm + Shell)

- `bash azure/addons/install.sh`로 5단계 순차 설치:

```
[1/5] kubeconfig 설정 (aks-mgmt)
[2/5] Cilium BYO CNI 설치 (mgmt) + 60초 대기
[3/5] ArgoCD 설치 (mgmt, LoadBalancer)
[4/5] External Secrets Operator 설치 (mgmt, Workload Identity 연동)
[5/5] app1/app2 클러스터 Cilium 설치
```

### Phase 5: 검증

```bash
# kubeconfig 전체 등록
bash azure/scripts/setup-kubeconfig.sh

# 클러스터 상태 확인
kubectl config get-contexts
kubectl get nodes

# ArgoCD 접근
kubectl -n argocd get svc argocd-server

# ESO 상태
kubectl -n external-secrets get pods
```

## R: 결과물

실제 IaC 코드로 구현된 결과물:

### 1. Terraform 모듈 (4개, 16파일)

| 모듈 | Azure 리소스 | 코드 참조 |
|-----|-------------|----------|
| **Root** | `azurerm_resource_group` | `azure/main.tf` |
| **vnet** | `azurerm_virtual_network` + 4 `subnet` + 3 `nsg` + 3 `nsg_association` | `azure/modules/vnet/main.tf` |
| **aks** (x3) | `azurerm_kubernetes_cluster` + `node_pool` (Spot) | `azure/modules/aks/main.tf` |
| **keyvault** | `azurerm_key_vault` + `user_assigned_identity` + `federated_identity_credential` + `role_assignment` | `azure/modules/keyvault/main.tf` |
| **observability** | `azurerm_log_analytics_workspace` + `log_analytics_solution` | `azure/modules/observability/main.tf` |

### 2. Helm Values (2파일)

| 컴포넌트 | Values 파일 | 핵심 설정 |
|---------|-----------|----------|
| **ArgoCD** | `addons/values/argocd-values.yaml` | LB 서비스, insecure 모드 |
| **External Secrets** | `addons/values/external-secrets-values.yaml` | Workload Identity 연동, CRD 자동 설치 |

### 3. Shell Script (4파일)

| 스크립트 | 역할 |
|---------|------|
| `addons/install.sh` | Cilium(3 클러스터) + ArgoCD + ESO 순차 설치 |
| `addons/uninstall.sh` | 애드온 역순 삭제 |
| `scripts/setup-kubeconfig.sh` | 3 클러스터 kubeconfig 일괄 등록 |
| `scripts/cleanup.sh` | 리소스 그룹 전체 삭제 (확인 프롬프트) |

### 4. 네트워크 설계

| Subnet | CIDR | AKS | NSG |
|--------|------|-----|-----|
| `subnet-aks-mgmt` | `10.1.0.0/16` | AKS-mgmt | `nsg-aks-mgmt` (app1/app2 inbound 허용) |
| `subnet-aks-app1` | `10.2.0.0/16` | AKS-app1 | `nsg-aks-app1` (mgmt inbound 허용) |
| `subnet-aks-app2` | `10.3.0.0/16` | AKS-app2 | `nsg-aks-app2` (mgmt inbound 허용) |
| `subnet-services` | `10.4.0.0/24` | - | - (관리형 서비스용) |

### 5. 비용 구조 (시연 환경)

| 항목 | 월 비용 | 코드 참조 |
|-----|--------|----------|
| AKS Control Plane (3개) | 무료 | AKS Free Tier |
| VM: Spot 5노드 (D2s_v3) | ~$50 | `modules/aks/main.tf` (spot_max_price) |
| Azure Disk (150GB) | ~$5 | System+Spot pool os_disk_size_gb |
| Log Analytics | ~$5 | `modules/observability/main.tf` (daily_quota_gb=5) |
| Key Vault | ~$1 | `modules/keyvault/main.tf` |
| **합계** | **~$60-80** | |

## T: 톤과 스타일

- 어조: 기술 문서 스타일의 간결하고 정확한 표현
- 언어: Azure/쿠버네티스 실무 용어 사용, 약어는 첫 등장 시 풀네임 병기 (예: AKS(Azure Kubernetes Service))
- 형식: Mermaid 다이어그램으로 아키텍처 시각화, 비교 항목은 표(table) 사용, 코드 블록에는 언어 명시 (`hcl`, `yaml`, `bash` 등)
- 포함할 요소: 실제 코드 경로 참조, `terraform apply` / `bash install.sh` 등 실행 가능한 명령어, ADR 번호 참조
- 제외할 요소: 미구현 컴포넌트 언급, 검증되지 않은 성능 수치, 마케팅성 표현
- 기타: 시연 환경 기준으로 작성하되, 프로덕션 전환 경로를 참고사항으로 안내

## E: 예시 참조

- **클러스터 토폴로지 (Terraform 모듈 매핑)**:

| 클러스터 | Terraform 모듈 호출 | Subnet | Spot 노드 수 | Tier |
|---------|-------------------|--------|------------|------|
| AKS-mgmt | `module "aks_mgmt"` | `10.1.0.0/16` | 1 | Tier 1 (플랫폼) |
| AKS-app1 | `module "aks_app1"` | `10.2.0.0/16` | 2 | Tier 2 (워크로드) |
| AKS-app2 | `module "aks_app2"` | `10.3.0.0/16` | 2 | Tier 2 (워크로드) |

- **ADR ↔ 코드 매핑**:

| ADR | 결정 | 코드 위치 | 핵심 설정 |
|-----|------|----------|----------|
| ADR-A01 | Spot VM Tier 배치 | `modules/aks/main.tf` | `priority = "Spot"`, `eviction_policy = "Delete"` |
| ADR-A02 | Cilium BYO CNI | `modules/aks/main.tf` | `network_plugin = "none"` |
| ADR-A03 | Key Vault + Workload Identity | `modules/keyvault/main.tf` | `federated_identity_credential`, `role_assignment` |
| ADR-A04 | Public API + NSG | `modules/vnet/main.tf` | NSG security_rule 정의 |

- **실행 명령어 요약**:

```bash
# 전체 인프라 생성
cd azure
terraform init && terraform apply

# 플랫폼 애드온 설치
bash addons/install.sh

# kubeconfig 설정
bash scripts/setup-kubeconfig.sh

# 전체 인프라 삭제
terraform destroy
# 또는 빠른 삭제: bash scripts/cleanup.sh
```

- **장애 영향 매트릭스**:

| 장애 유형 | 영향 | 완화 | 코드 참조 |
|----------|------|------|----------|
| Spot VM 회수 | 해당 노드 Pod 재스케줄링 | PDB + 다중 레플리카 | `modules/aks/main.tf` (node_taints) |
| AKS Control Plane 장애 | API Server 불가 | Azure 자동 복구 (SLA 99.5%) | - |
| Key Vault 장애 | 새 시크릿 조회 불가 | ESO 캐시 유지 (SLA 99.99%) | `modules/keyvault/main.tf` |

## R: 자료 참고

- **아키텍처 문서**: [ARCHITECTURE.md](ARCHITECTURE.md) - 클러스터 토폴로지, 네트워크, 보안, 관찰성, 비용 전략 전체 설계
- **IaC 소스코드**: `azure/` 디렉터리의 Terraform 모듈 + addons/ + scripts/
- **Azure 공식 문서**: AKS, Key Vault, Cilium BYO CNI, Workload Identity, Azure Monitor Container Insights
- **코드-문서 매핑 계약**:
  - C1: AKS 클러스터 스펙은 `modules/aks/main.tf`의 리소스 정의에서 도출
  - C2: 네트워크 CIDR은 `modules/vnet/main.tf`의 `address_prefixes`에서 도출
  - C3: 비용 관련 설정은 `variables.tf`의 `spot_max_price`, `log_analytics_daily_quota_gb`에서 도출
  - C4: 보안 설정은 `modules/keyvault/main.tf`의 Workload Identity + Role Assignment에서 도출
  - C5: 애드온 설치 순서는 `addons/install.sh`의 실행 순서를 따름

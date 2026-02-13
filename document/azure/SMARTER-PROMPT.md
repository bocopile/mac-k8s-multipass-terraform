# Azure Kubernetes 멀티클러스터 아키텍처 구축 프롬프트

> **SMART+ER 프롬프트 프레임워크** 기반 작성
> **참조 문서**: [ARCHITECTURE.md](ARCHITECTURE.md)

---

## S: 상황

- Azure 클라우드에서 Kubernetes 멀티클러스터 환경을 구축해야 합니다
- 시연 및 개발(PoC) 목적으로, 비용 최적화가 핵심 제약사항입니다
- 리전은 Korea Central이며, AKS(Azure Kubernetes Service)를 기반으로 합니다
- 클러스터 구성은 관리 클러스터(AKS-mgmt) 1개 + 애플리케이션 클러스터(AKS-app1, AKS-app2) 2개로 총 3개입니다
- Spot VM을 활용하여 월 $60-80 수준의 비용을 목표로 합니다
- GitOps(ArgoCD), 시크릿 관리(Azure Key Vault), 관찰성(Azure Monitor) 등의 플랫폼 기능이 필요합니다
- 프로덕션 전환 가능성을 고려하여 확장 경로를 열어둬야 합니다

## M: 목표

- Azure AKS 기반 멀티클러스터(3개) 아키텍처를 Terraform IaC로 구축
- 시연 환경 가용성 SLO 95%, RTO 2시간, RPO 24시간 달성
- 월 비용 $80 이하 유지 (Spot VM, AKS Free Tier, 로그 수집 제한 활용)
- Cilium BYO CNI를 통한 클러스터 간 서비스 디스커버리(Cluster Mesh) 구성
- Azure Key Vault + Workload Identity 기반 시크릿 관리 체계 확립
- 프로덕션 전환 시 Tier 1 워크로드 On-Demand 전환, Private Cluster, 멀티 AZ 적용 가능한 구조

## A: 단계별 수행

"중요: 각 단계가 완료되면 사용자에게 결과를 확인받고 다음 단계 진행 여부 확인해야 합니다."

1. 네트워크 기반 설계
   - VNet(10.0.0.0/8) 생성 및 서브넷 4개 분리 (mgmt: 10.1.0.0/16, app1: 10.2.0.0/16, app2: 10.3.0.0/16, services: 10.4.0.0/24)
   - NSG 규칙 설정으로 서브넷 간 트래픽 제어
   - Azure Private DNS Zone 구성

2. AKS 클러스터 프로비저닝
   - AKS-mgmt: Standard_D2s_v3, Spot VM, 1노드 (Tier 1 - ArgoCD, Prometheus 등 플랫폼 워크로드)
   - AKS-app1/app2: Standard_D2s_v3, Spot VM, 각 2노드 (Tier 2 - 애플리케이션 워크로드)
   - AKS Free Tier Control Plane 사용 (SLA 99.5%)
   - Public API + NSG 제한 (시연 환경)

3. CNI 및 멀티클러스터 네트워크 구성
   - Cilium BYO CNI 설치 및 eBPF 기반 네트워크 정책 적용
   - Cilium Cluster Mesh로 3개 클러스터 간 서비스 디스커버리 구성
   - Ingress 컨트롤러 설정 (Cilium Gateway 또는 NGINX)

4. 보안 아키텍처 구성
   - Azure AD + AKS RBAC 통합
   - Azure Key Vault 생성 + Workload Identity(Federated Credential) 연동
   - External Secrets Operator 배포 (캐싱 기반 장애 대응)
   - Azure Policy for AKS 적용 (이미지 허용 목록, 권한 컨테이너 금지, 리소스 제한)
   - Pod Security Admission(PSA) 설정

5. GitOps 및 관찰성 설정
   - AKS-mgmt에 ArgoCD 배포, 3개 클러스터 관리 대상 등록
   - Azure Monitor + Container Insights 활성화 (Azure Monitor Agent)
   - Log Analytics Workspace 구성 (보존 30일, 일일 5GB 제한)
   - Alert Rules 설정

6. 스토리지 및 백업 구성
   - StorageClass 구성 (managed, managed-premium, azurefile)
   - Velero 설치 → Azure Blob 백업
   - Azure Disk Snapshot 정책 설정
   - Terraform State는 Azure Storage에 원격 관리

7. 장애 대응 및 검증
   - PodDisruptionBudget 설정으로 Spot VM 회수 대응
   - Spot 회수 시나리오 테스트 (30초 전 알림 → Node Drain → 재스케줄링)
   - DR 시나리오 검증 (ArgoCD 동기화 복구, Velero 복원)

## R: 결과물

다음 요소를 포함한 Terraform IaC 프로젝트 및 운영 문서:

1. **Terraform 모듈** - AKS 클러스터, VNet/Subnet, NSG, Key Vault, ACR 등 인프라 코드
2. **Helm/Kustomize 매니페스트** - ArgoCD, External Secrets, Cilium, Velero, Prometheus 등 플랫폼 컴포넌트 배포 정의
3. **아키텍처 문서** - 클러스터 토폴로지, 네트워크 설계, 보안 계층, 장애 도메인을 포함한 아키텍처 결정 기록(ADR)
4. **구현 가이드** - Terraform 코드 실행 순서, AKS 설정, Key Vault 연동, Cilium Cluster Mesh 구성 절차
5. **운영 런북** - 백업/복구 절차, Spot VM 회수 대응, 업그레이드 가이드, 비용 모니터링
6. **비용 분석** - 시연 환경 월 $60-80 예상 비용 내역 및 프로덕션 전환 시 추가 비용(On-Demand +$50-80, 멀티 AZ +$30-50, Uptime SLA +$73)

## T: 톤과 스타일

- 어조: 기술 문서 스타일의 간결하고 정확한 표현
- 언어: 클라우드/쿠버네티스 실무 용어 사용, 약어는 첫 등장 시 풀네임 병기 (예: AKS(Azure Kubernetes Service))
- 형식: Mermaid 다이어그램으로 아키텍처 시각화, 비교 항목은 표(table) 사용, 코드 블록에는 언어 명시
- 포함할 요소: 시연 환경과 프로덕션 권장 사항의 명확한 구분, 비용 영향 표기, ADR(Architecture Decision Record) 형식의 의사결정 근거
- 제외할 요소: 마케팅성 표현, 검증되지 않은 성능 수치, 특정 벤더 편향적 비교
- 기타: 시연 환경 기준으로 작성하되, 프로덕션 전환 경로를 항상 부록 또는 참고사항으로 안내

## E: 예시 참조

- **Tier 분류 기준 예시**:

| Tier | 워크로드 | 시연 환경 | 프로덕션 권장 |
|------|---------|----------|-------------|
| Tier 0 | Control Plane (AKS 관리형), CoreDNS | AKS 관리형 (Azure 보장) | AKS 관리형 |
| Tier 1 | mgmt 클러스터 (Prometheus, ArgoCD) | Spot VM | On-Demand |
| Tier 2 | app 클러스터 (애플리케이션) | Spot VM | Spot VM |

- **CNI 비교 예시**:

| 항목 | Cilium (BYO) | Azure CNI Powered by Cilium | Azure CNI |
|------|-------------|---------------------------|-----------|
| Cluster Mesh | 자유 구성 | 제한적 | 미지원 |
| Azure 네이티브 통합 | 제한적 | 지원 | 완전 지원 |
| eBPF 기반 성능 | 지원 | 지원 | 미지원 |

- **장애 영향 매트릭스 예시**:

| 장애 유형 | 영향 | 복구 |
|----------|------|------|
| Spot VM 회수 | 해당 노드 Pod 재스케줄링 | 자동 (Cluster Autoscaler) |
| AKS Control Plane 장애 | API Server 불가 (워크로드는 계속 실행) | Azure 자동 복구 |
| Key Vault 장애 | 새 시크릿 조회 불가 (캐시 유지) | Azure 자동 복구 (SLA 99.99%) |

## R: 자료 참고

- **아키텍처 문서**: [ARCHITECTURE.md](ARCHITECTURE.md) - 클러스터 토폴로지, 네트워크, 보안, 관찰성, 비용 전략 전체 설계
- **구현 가이드**: [IMPLEMENTATION-GUIDE.md](IMPLEMENTATION-GUIDE.md) - Terraform 코드, AKS 설정, Key Vault 연동 절차
- **운영 런북**: [OPERATIONS-RUNBOOK.md](OPERATIONS-RUNBOOK.md) - 백업/복구/업그레이드 운영 절차
- **Azure 공식 문서**: AKS, Key Vault, Cilium BYO CNI, Workload Identity, Azure Monitor Container Insights
- **Cilium 공식 문서**: Cluster Mesh 구성, eBPF 기반 네트워크 정책
- **아키텍처 불변 조건(Architecture Contract)**:
  - C1: AKS Control Plane은 Azure 관리형으로 Tier 분류 대상 아님
  - C2: 시연 환경 User Node Pool은 Spot VM 사용
  - C3: 프로덕션 전환 시 Tier 1은 On-Demand 변경 권장
  - C4: 시크릿은 Azure Key Vault + Workload Identity로 관리
  - C5: 시연은 Public API + NSG 제한, 프로덕션은 Private Cluster
  - C6: External Secrets 캐시로 Key Vault 장애 시 기존 시크릿 유지

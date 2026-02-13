# On-Premise Kubernetes 멀티클러스터 아키텍처 구축 프롬프트

> **SMART+ER 프롬프트 프레임워크** 기반 작성
> **참조 문서**: [ARCHITECTURE.md](ARCHITECTURE.md)

---

## S: 상황

- macOS(Apple Silicon, M1 Max 10코어) 호스트에서 로컬 Kubernetes 멀티클러스터 환경을 구축해야 합니다
- 개발/학습/시연 목적의 프로덕션급 아키텍처를 로컬에서 재현하는 프로젝트입니다
- Multipass VM 위에 kubeadm v1.35(Timbernetes)로 클러스터를 프로비저닝합니다
- 호스트 리소스는 64GB RAM, 540GB SSD이며 VM에 할당 가능한 RAM은 약 56GB입니다
- 관리 클러스터(mgmt) 1개 + 애플리케이션 클러스터(app1, app2) 2개, 총 3개 클러스터 구성입니다
- Ansible과 Helmfile은 사용하지 않으며, Terraform + Shell Script + Helm CLI로 구성합니다
- 외부 서비스로 Harbor(컨테이너 레지스트리)와 Nexus(패키지 저장소)를 Docker Desktop에서 운영합니다
- mgmt 클러스터에 플랫폼 서비스(Vault, 관찰성 스택, 백업)를 집중 배치하되, mgmt 장애 시에도 app 클러스터가 독립 실행되어야 합니다

## M: 목표

- Terraform IaC + Shell Script로 Multipass 기반 멀티클러스터(3개) 환경을 완전 자동화 구축
- 가용성 SLO 99%(월 ~7시간 다운타임 허용), RTO 1시간, RPO 24시간 달성
- 호스트 RAM 24GB + 디스크 240GB 이내에서 6개 VM(CP 3 + Worker 3) 안정 운영
- Cilium Cluster Mesh(VXLAN 모드)를 통한 3개 클러스터 간 서비스 디스커버리 구성
- Vault + External Secrets + cert-manager 기반의 시크릿/PKI 관리 체계 확립 (2-Phase 부트스트랩)
- PSA + Kyverno 2-Layer 보안 모델로 워크로드 보안 정책 적용
- Prometheus Agent + Thanos + Loki + Grafana 기반 중앙 집중형 관찰성 구현 (에이전트 모드)
- mgmt 클러스터 장애 시 app 클러스터의 Graceful Degradation 보장 (로컬 버퍼링 + 캐시)

## A: 단계별 수행

"중요: 각 단계가 완료되면 사용자에게 결과를 확인받고 다음 단계 진행 여부 확인해야 합니다."

1. 호스트 환경 준비 및 VM 프로비저닝
   - Multipass, Docker Desktop, Terraform, Helm CLI 등 필수 도구 설치
   - Terraform으로 6개 VM 생성 (mgmt-cp/worker, app1-cp/worker, app2-cp/worker)
   - cloud-init으로 VM 초기 설정 (IP 고정: 192.168.64.10~31, containerd 설치)
   - Docker Desktop에서 Harbor(:8443) / Nexus(:8081) 구동

2. kubeadm 클러스터 부트스트랩
   - kubeadm v1.35로 3개 클러스터 초기화 (각각 별도 Pod CIDR, Service CIDR)
   - InPlacePodVerticalScaling GA 기능 활용 설정
   - Control Plane + Worker 노드 조인
   - kubeconfig 생성 및 관리

3. CNI 및 멀티클러스터 네트워크 구성
   - Cilium 설치 (Tunneling/VXLAN 모드 - Multipass 브리지 네트워크 환경)
   - Cilium Cluster Mesh 구성 (mgmt ↔ app1 ↔ app2 Full Mesh)
   - Hubble 활성화 (네트워크 관찰성)
   - MetalLB L2 모드 설치 (클러스터별 IP 풀 10개씩)
   - Cilium Gateway API v1.4 구성

4. 시크릿/PKI 관리 구성 (2-Phase 부트스트랩)
   - Phase 1: cert-manager + Self-signed Issuer 설치 (부트스트랩)
   - Vault 설치 및 초기화 (mgmt 클러스터, local-path-retain 스토리지)
   - External Secrets Operator 배포 (refreshInterval 1h 캐시)
   - Phase 2: Vault Issuer로 전환 (인증서 자동 갱신 보장)

5. 보안 정책 적용 (2-Layer 모델)
   - PSA 설정: 기본 baseline enforce, restricted audit/warn
   - PSA 예외 등록: kube-system, cilium-system, monitoring, vault
   - Kyverno 설치 (app1/app2만, mgmt 제외)
   - Kyverno 정책 적용: 이미지 레지스트리 제한(Harbor만), 리소스 제한 필수, 권한 컨테이너 금지
   - Falco 설치 (app1/app2 - 런타임 이상 행위 탐지)

6. 관찰성 스택 구성 (에이전트 모드 아키텍처)
   - mgmt: Prometheus(Full) + Thanos(장기 저장) + Loki + Grafana + Alertmanager 배포
   - app1/app2: Prometheus Agent Mode + Promtail 배포 (로컬 수집, mgmt로 remote_write/push)
   - Grafana 대시보드 및 Alert Rules 구성
   - mgmt 장애 시 로컬 버퍼링 동작 검증 (WAL ~2.7시간, Promtail positions 파일)

7. GitOps 및 백업 구성
   - mgmt에 ArgoCD 배포, 3개 클러스터 등록
   - Velero 설치 (각 클러스터) + MinIO 백엔드 (mgmt)
   - 백업 스케줄 설정: etcd 스냅샷 (24h), Velero+Restic (24h)
   - StorageClass 구성: local-path(기본, Delete), local-path-retain(중요 데이터, Retain)

8. 통합 검증 및 장애 테스트
   - 클러스터 간 서비스 디스커버리 테스트 (Cilium Cluster Mesh)
   - mgmt 클러스터 중단 시나리오 테스트 (Graceful Degradation)
     - app 워크로드 독립 실행 확인
     - Prometheus Agent 로컬 버퍼링 → 복구 후 재전송 확인
     - External Secrets 캐시 유지 확인
   - DR 시나리오 검증: ArgoCD 동기화, etcd 복원, Velero 복원

## R: 결과물

다음 요소를 포함한 Terraform IaC 프로젝트 및 운영 문서:

1. **Terraform 모듈** - Multipass VM 프로비저닝, cloud-init 설정, IP 할당 등 인프라 코드
2. **Shell Script** - kubeadm 클러스터 부트스트랩, 컴포넌트 설치 자동화 스크립트
3. **Helm Values / Kustomize** - Cilium, Vault, cert-manager, External Secrets, Prometheus, Thanos, Loki, Grafana, ArgoCD, Velero, MinIO, Kyverno, Falco 등 플랫폼 컴포넌트 배포 정의
4. **아키텍처 문서** - 클러스터 토폴로지, 네트워크 설계(CIDR 할당), 보안 계층, 장애 도메인을 포함한 ADR 6건
5. **구현 가이드** - Terraform 실행 → kubeadm 부트스트랩 → CNI → 2-Phase PKI → 보안 → 관찰성 → GitOps 순서의 설치 절차
6. **운영 런북** - 백업/복구 절차(etcd, Velero), 장애 대응(mgmt 다운, Vault 다운, Harbor 다운), 복구 우선순위(P0~P2)
7. **리소스 계획** - 호스트 64GB RAM 기준 VM별 할당(총 24GB), 워크로드별 requests/limits 명세

## T: 톤과 스타일

- 어조: 기술 문서 스타일의 간결하고 정확한 표현
- 언어: 쿠버네티스/인프라 실무 용어 사용, 약어는 첫 등장 시 풀네임 병기 (예: PSA(Pod Security Admission))
- 형식: Mermaid 다이어그램으로 아키텍처 시각화, 비교/매핑 항목은 표(table) 사용, 코드 블록에는 언어 명시 (yaml, bash, hcl 등)
- 포함할 요소: ADR(Architecture Decision Record) 형식의 의사결정 근거, 장애 영향 매트릭스, Graceful Degradation 시나리오, 리소스 예산
- 제외할 요소: 클라우드 관리형 서비스 의존, Ansible/Helmfile 관련 내용, 검증되지 않은 성능 수치
- 기타: 로컬(Multipass) 환경 제약사항을 명시하되, 프로덕션 환경 대비 차이점을 참고사항으로 안내

## E: 예시 참조

- **클러스터 역할 분담 예시**:

| 클러스터 | 역할 | 주요 컴포넌트 |
|---------|------|-------------|
| mgmt | 플랫폼 서비스 | Vault, Prometheus, Thanos, Loki, Grafana, Velero, MinIO, ArgoCD |
| app1 | 워크로드 A | 애플리케이션, Prometheus Agent, Promtail, Kyverno, Falco |
| app2 | 워크로드 B | 애플리케이션, Prometheus Agent, Promtail, Kyverno, Falco |

- **CIDR 할당 예시**:

| 클러스터 | 노드 네트워크 | Pod CIDR | Service CIDR | MetalLB 풀 |
|---------|-------------|----------|--------------|-----------|
| mgmt | 192.168.64.10-19 | 10.100.0.0/16 | 10.96.0.0/16 | 192.168.64.200-210 |
| app1 | 192.168.64.20-29 | 10.101.0.0/16 | 10.97.0.0/16 | 192.168.64.211-220 |
| app2 | 192.168.64.30-39 | 10.102.0.0/16 | 10.98.0.0/16 | 192.168.64.221-230 |

- **장애 영향 매트릭스 예시**:

| 장애 컴포넌트 | 영향 | 완화 |
|-------------|------|------|
| mgmt 클러스터 전체 다운 | 시크릿 갱신/중앙 로그/새 배포 불가 | app 클러스터 독립 실행, 로컬 버퍼링, 캐시 유지 |
| Vault 다운 | 새 시크릿 발급 불가 | External Secrets 1h 캐시로 동작 |
| Harbor 다운 | 새 이미지 Pull 불가 | 캐시된 이미지로 Pod 실행 |
| ArgoCD 다운 | GitOps 배포 중단 | 기존 워크로드 정상 실행 |

- **보안 2-Layer 모델 예시**:

| 계층 | 도구 | 적용 범위 | 역할 |
|-----|------|----------|------|
| Layer 1 | PSA | 전체 클러스터 | 네임스페이스 레벨 기본 경계 (baseline enforce) |
| Layer 2 | Kyverno | app 클러스터만 | 워크로드별 세부 정책 (이미지/리소스/권한 enforce) |

## R: 자료 참고

- **아키텍처 문서**: [ARCHITECTURE.md](ARCHITECTURE.md) - 클러스터 토폴로지, 네트워크, 보안, 관찰성, 장애 도메인, 리소스 계획 전체 설계
- **구현 가이드**: [IMPLEMENTATION-GUIDE.md](IMPLEMENTATION-GUIDE.md) - Terraform, kubeadm, Helm 설치 코드 및 절차
- **운영 런북**: [OPERATIONS-RUNBOOK.md](OPERATIONS-RUNBOOK.md) - 백업/복구/업그레이드 운영 절차
- **기술 스택 공식 문서**: kubeadm v1.35, Cilium (Cluster Mesh, VXLAN, Gateway API), Vault, cert-manager, External Secrets Operator, Prometheus (Agent Mode), Thanos, Loki, Grafana, ArgoCD, Velero, Kyverno, Falco, MetalLB
- **아키텍처 불변 조건(Architecture Contract)**:
  - C1: mgmt 장애 시에도 app 클러스터 워크로드는 **독립 실행** 지속
  - C2: Prometheus Agent WAL 로컬 버퍼링 유지 (~2.7시간, 수집량/디스크에 따라 변동)
  - C3: External Secrets **refreshInterval 1h** 캐시로 Vault 장애 시에도 동작
  - C4: Kyverno는 **app 클러스터에만** enforce (mgmt 제외)
  - C5: PKI 부트스트랩은 **2-Phase** (Self-signed → Vault Issuer) 순서 준수
  - C6: Cilium은 **Tunneling(VXLAN)** 모드로 동작

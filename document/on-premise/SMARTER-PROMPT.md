# On-Premise Kubernetes 멀티클러스터 아키텍처 구축 프롬프트

> **SMART+ER 프롬프트 프레임워크** 기반 작성
> **참조 문서**: [ARCHITECTURE.md](ARCHITECTURE.md)
> **버전**: 2.0.0 (코드 현실 반영)

---

## S: 상황

- macOS(Apple Silicon, M1 Max 10코어) 호스트에서 로컬 Kubernetes 멀티클러스터 환경을 구축해야 합니다
- 개발/학습/시연 목적의 프로덕션급 아키텍처를 로컬에서 재현하는 프로젝트입니다
- Multipass VM 위에 kubeadm v1.35(Timbernetes)로 클러스터를 프로비저닝합니다
- 호스트 리소스는 64GB RAM, 540GB SSD이며 VM에 할당 가능한 RAM은 약 56GB입니다
- 관리 클러스터(mgmt) 1개 + 애플리케이션 클러스터(app1, app2) 2개, 총 3개 클러스터 구성입니다
- Ansible과 Helmfile은 사용하지 않으며, Terraform + Shell Script + Helm CLI로 구성합니다
- mgmt 클러스터에 플랫폼 서비스(Vault, 관찰성 스택, GitOps, 백업)를 집중 배치하되, mgmt 장애 시에도 app 클러스터가 독립 실행되어야 합니다
- VM 노드 IP는 Multipass DHCP로 동적 할당됩니다

## M: 목표

- Terraform IaC + Shell Script로 Multipass 기반 멀티클러스터(3개) 환경을 완전 자동화 구축
- 가용성 SLO 99%(월 ~7시간 다운타임 허용), RTO 1시간, RPO 24시간 달성
- 호스트 RAM 26GB + 디스크 240GB 이내에서 6개 VM(CP 3 + Worker 3) 안정 운영
- Cilium Cluster Mesh(VXLAN 모드)를 통한 3개 클러스터 간 서비스 디스커버리 구성
- Vault + External Secrets + cert-manager 기반의 시크릿/PKI 관리 체계 확립 (2-Phase 부트스트랩)
- PSA + Kyverno 2-Layer 보안 모델 + Falco/Tetragon 런타임 보안
- Prometheus Agent + Thanos + Loki + Promtail + Grafana 기반 중앙 집중형 관찰성 (에이전트 모드)
- ArgoCD 기반 GitOps 배포 파이프라인
- mgmt 클러스터 장애 시 app 클러스터의 Graceful Degradation 보장 (로컬 버퍼링 + 캐시)

## A: 단계별 수행

"중요: 각 단계가 완료되면 사용자에게 결과를 확인받고 다음 단계 진행 여부 확인해야 합니다."

### Phase 1: 호스트 환경 준비 및 VM 프로비저닝
- Multipass, Terraform >= 1.11.3, Helm CLI, kubectl, cilium CLI 등 필수 도구 설치
- Terraform으로 6개 VM 생성 (mgmt-cp 4G, mgmt-worker-0 8G, app1-cp 3G, app1-worker-0 4G, app2-cp 3G, app2-worker-0 4G)
- cloud-init으로 VM 초기 설정 (containerd, kubeadm/kubelet/kubectl, PSA admission config)
- **구현**: `locals.tf`, `templates/cloud-init-k8s.yaml.tpl`, `main.tf` (null_resource.vm)

### Phase 2: kubeadm 클러스터 부트스트랩
- kubeadm v1.35로 3개 클러스터 초기화 (각각 별도 Pod CIDR, Service CIDR)
- skipPhases: addon/kube-proxy (Cilium이 대체)
- Control Plane + Worker 노드 조인
- 3개 kubeconfig 병합 (`kubeconfig-multi`)
- **구현**: `scripts/cluster-init.sh`, `scripts/cluster-join.sh`, `scripts/merge-kubeconfigs.sh`

### Phase 3: CNI 및 멀티클러스터 네트워크 구성
- Cilium 설치 (Tunneling/VXLAN 모드, kubeProxyReplacement=true, Hubble UI 활성화)
- Tetragon eBPF 런타임 보안 설치 (전 클러스터 DaemonSet)
- Gateway API CRD v1.2.1 설치 + Cilium Gateway 활성화
- MetalLB L2 모드 설치 (클러스터별 IP 풀)
- Cilium Cluster Mesh 구성 (mgmt <-> app1 <-> app2 Full Mesh)
- **구현**: `scripts/install-cilium.sh`, `scripts/install-tetragon.sh`, `scripts/install-gateway-api.sh`, `scripts/install-metallb.sh`, `scripts/setup-clustermesh.sh`

### Phase 4: 시크릿/PKI 관리 구성
- cert-manager 설치 (전 클러스터) + Phase 1 Self-signed ClusterIssuer + CA Certificate
- Vault 설치 (mgmt, standalone, local-path-retain StorageClass, LoadBalancer)
- External Secrets Operator 배포 (전 클러스터, refreshInterval 1h 캐시, Vault ClusterSecretStore)
- Phase 2: Vault Issuer 전환 (운영 안정화 후)
- **구현**: `scripts/install-cert-manager.sh`, `scripts/install-vault.sh`, `scripts/install-eso.sh`

### Phase 5: 보안 정책 적용
- PSA 설정: 기본 baseline enforce, restricted audit/warn (cloud-init에서 자동 적용)
- PSA 예외 등록: kube-system, cilium-system, monitoring, vault
- Kyverno 설치 (app1/app2만, mgmt 제외 - C4)
  - 이미지 레지스트리 제한 (localhost:8443, docker.io/library, registry.k8s.io, quay.io)
  - 리소스 제한 필수 (requests/limits)
  - 권한 있는 컨테이너 금지
  - 라벨 필수 (audit: app, version)
- Falco 설치 (app1/app2, eBPF 드라이버, Prometheus 메트릭)
- **구현**: `scripts/install-kyverno.sh`, `scripts/install-falco.sh`

### Phase 6: 플랫폼 부가 도구 (mgmt)
- local-path-retain StorageClass 생성
- Trivy Operator (이미지/K8s 취약점 스캔)
- K8sGPT Operator (AI 클러스터 진단)
- OpenCost (리소스 비용 가시화)
- VPA + Goldilocks (리소스 추천, recommender-only)
- Chaos Mesh (장애 주입 테스트)
- **구현**: `scripts/install-platform-addons.sh`

### Phase 7: 관찰성 스택 구성
- mgmt: Vault 설치 (Phase 4에서 완료)
- mgmt: Thanos Receive + Query + Compactor (LoadBalancer로 app에서 접근)
- mgmt: kube-prometheus-stack (Prometheus Full + Grafana + Alertmanager)
- mgmt: Loki (SingleBinary, 7일 보존, LoadBalancer)
- 전 클러스터: Promtail (Loki로 push, cluster 라벨 추가)
- app1/app2: Prometheus Agent Mode (Thanos Receive로 remote_write, WAL 2h)
- Grafana에 Thanos Query + Loki 데이터소스 자동 구성
- **구현**: `scripts/install-thanos.sh`, `scripts/install-prometheus-stack.sh`, `scripts/install-loki.sh`, `scripts/install-prometheus-agent.sh`

### Phase 8: GitOps 및 백업 구성
- mgmt에 ArgoCD 배포, app1/app2 클러스터 자동 등록
- MinIO 설치 (mgmt, 50Gi, LoadBalancer, velero-backups 버킷 자동 생성)
- Velero 설치 (전 클러스터, 클러스터별 prefix, AWS plugin + node-agent)
- **구현**: `scripts/install-argocd.sh`, `scripts/install-minio.sh`, `scripts/install-velero.sh`

### Phase 9: 통합 검증
- 클러스터 간 서비스 디스커버리 테스트 (Cilium Cluster Mesh)
- 전체 컴포넌트 상태 확인
- **구현**: `scripts/verify-clusters.sh`

## R: 결과물

다음 요소를 포함한 Terraform IaC 프로젝트 및 운영 문서:

1. **Terraform 코드** (`main.tf`, `locals.tf`, `variables.tf`, `versions.tf`, `outputs.tf`)
2. **Cloud-Init 템플릿** (`templates/cloud-init-k8s.yaml.tpl`)
3. **Shell Script 23개** (`scripts/` 디렉토리)
   - 클러스터 관리: `cluster-init.sh`, `cluster-join.sh`, `merge-kubeconfigs.sh`, `delete-all.sh`, `verify-clusters.sh`
   - 네트워크: `install-cilium.sh`, `install-metallb.sh`, `setup-clustermesh.sh`, `install-gateway-api.sh`
   - 보안: `install-tetragon.sh`, `install-kyverno.sh`, `install-falco.sh`
   - PKI/시크릿: `install-cert-manager.sh`, `install-vault.sh`, `install-eso.sh`
   - 관찰성: `install-prometheus-stack.sh`, `install-thanos.sh`, `install-prometheus-agent.sh`, `install-loki.sh`
   - 플랫폼: `install-platform-addons.sh`
   - GitOps: `install-argocd.sh`
   - 백업: `install-minio.sh`, `install-velero.sh`
4. **아키텍처 문서** (`ARCHITECTURE.md`) - ADR, 보안, 관찰성, 장애 도메인, 리소스 계획, 서비스 접근 레퍼런스, 보안 운영 체크리스트

## T: 톤과 스타일

- 어조: 기술 문서 스타일의 간결하고 정확한 표현
- 언어: 쿠버네티스/인프라 실무 용어 사용, 약어는 첫 등장 시 풀네임 병기
- 형식: Mermaid 다이어그램으로 아키텍처 시각화, 비교/매핑 항목은 표(table) 사용
- 포함: ADR 형식의 의사결정 근거, 장애 영향 매트릭스, Graceful Degradation 시나리오, 리소스 예산
- 제외: 클라우드 관리형 서비스, Ansible/Helmfile, 검증되지 않은 성능 수치

## E: 예시 참조

- **클러스터 역할 분담**:

| 클러스터 | 역할 | 주요 컴포넌트 |
|---------|------|-------------|
| mgmt | 플랫폼 서비스 | Vault, Prometheus Full, Thanos, Loki, Grafana, Alertmanager, ArgoCD, Velero, MinIO, Trivy, K8sGPT, OpenCost, VPA+Goldilocks, Chaos Mesh |
| app1 | 워크로드 A | 애플리케이션, Prometheus Agent, Promtail, Kyverno, Falco |
| app2 | 워크로드 B | 애플리케이션, Prometheus Agent, Promtail, Kyverno, Falco |
| 전체 | 공통 인프라 | Cilium, Tetragon, MetalLB, cert-manager, ESO |

- **CIDR 할당**:

| 클러스터 | Pod CIDR | Service CIDR | MetalLB 풀 |
|---------|----------|--------------|-----------|
| mgmt | 10.100.0.0/16 | 10.96.0.0/16 | 192.168.64.200-210 |
| app1 | 10.101.0.0/16 | 10.97.0.0/16 | 192.168.64.211-220 |
| app2 | 10.102.0.0/16 | 10.98.0.0/16 | 192.168.64.221-230 |

- **VM 스펙**:

| 클러스터 | 노드 | RAM | CPU | 디스크 |
|---------|------|-----|-----|--------|
| mgmt | mgmt-cp | 4GB | 2 | 40GB |
| mgmt | mgmt-worker-0 | 8GB | 2 | 60GB |
| app1 | app1-cp | 3GB | 2 | 30GB |
| app1 | app1-worker-0 | 4GB | 2 | 40GB |
| app2 | app2-cp | 3GB | 2 | 30GB |
| app2 | app2-worker-0 | 4GB | 2 | 40GB |
| **합계** | | **26GB** | **12** | **240GB** |

## R: 자료 참고

- **아키텍처 문서**: [ARCHITECTURE.md](ARCHITECTURE.md) v4.0.0
- **구현 가이드**: [IMPLEMENTATION-GUIDE.md](IMPLEMENTATION-GUIDE.md)
- **운영 런북**: [OPERATIONS-RUNBOOK.md](OPERATIONS-RUNBOOK.md)
- **기술 스택 공식 문서**: kubeadm v1.35, Cilium 1.19.0, Vault, cert-manager, ESO, Prometheus Agent Mode, Thanos, Loki, Grafana, ArgoCD, Velero, Kyverno, Falco, Tetragon, Trivy, MetalLB, Gateway API
- **아키텍처 불변 조건(Architecture Contract)**:
  - C1: mgmt 장애 시에도 app 클러스터 워크로드는 **독립 실행** 지속
  - C2: Prometheus Agent WAL 로컬 버퍼링 유지 (**2시간** retention)
  - C3: External Secrets **refreshInterval 1h** 캐시로 Vault 장애 시에도 동작
  - C4: Kyverno는 **app 클러스터에만** enforce (mgmt 제외)
  - C5: PKI 부트스트랩은 **2-Phase** (Self-signed -> Vault Issuer) 순서 준수
  - C6: Cilium은 **Tunneling(VXLAN)** 모드로 동작

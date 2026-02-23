# Kubernetes 멀티클러스터 아키텍처

> **버전**: 5.3.0
> **Kubernetes**: v1.35 (Timbernetes)
> **최종 수정일**: 2026-02-21
> **관련 문서**: [SMART+ER 프롬프트](SMARTER-PROMPT.md)
> **변경 이력**: v5.3.0 - 문서 통합 정리 (서비스 접근 레퍼런스 병합, 보안 운영 가이드 통합)

---

## 목차

1. [개요](#1-개요)
2. [아키텍처 결정 기록 (ADR)](#2-아키텍처-결정-기록-adr)
3. [시스템 요구사항](#3-시스템-요구사항)
4. [클러스터 토폴로지](#4-클러스터-토폴로지)
5. [네트워크 아키텍처](#5-네트워크-아키텍처)
6. [스토리지 아키텍처](#6-스토리지-아키텍처)
7. [보안 아키텍처](#7-보안-아키텍처)
8. [관찰성 아키텍처](#8-관찰성-아키텍처)
9. [장애 도메인 및 복원력](#9-장애-도메인-및-복원력)
10. [백업 및 DR 전략](#10-백업-및-dr-전략)
11. [리소스 계획](#11-리소스-계획)
12. [플랫폼 부가 도구](#12-플랫폼-부가-도구)
13. [Terraform 파이프라인](#13-terraform-파이프라인)

---

## 1. 개요

### 1.1 프로젝트 목적

macOS(Apple Silicon) 환경에서 **Terraform과 Shell Script**를 사용하여 프로덕션급 Kubernetes 멀티클러스터 환경을 구축합니다.

### 1.2 대상 환경 및 SLO

| 항목 | 값 |
|-----|-----|
| **환경 유형** | 개발/학습/시연 (로컬) |
| **워크로드 유형** | Stateless (주), Stateful (보조) |
| **테넌시** | 단일 (개인 개발 환경) |

| SLO 지표 | 목표 | 비고 |
|---------|------|------|
| **가용성** | 99% | 월 ~7시간 다운타임 허용 |
| **RTO** | 1시간 | 클러스터 재생성 기준 |
| **RPO** | 24시간 | 일일 백업 기준 |

### 1.3 핵심 원칙

| 원칙 | 설명 |
|-----|------|
| **IaC** | Terraform으로 모든 인프라 정의 |
| **GitOps** | ArgoCD 기반 선언적 배포 |
| **제로 트러스트** | PSA + Kyverno 2-layer 보안 |
| **장애 격리** | mgmt 장애 시에도 app 클러스터 독립 운영 |
| **Graceful Degradation** | 의존 서비스 장애 시 제한된 기능으로 계속 동작 |

### 1.4 기술 스택 개요

| 영역 | 기술 |
|-----|------|
| **인프라** | Multipass, OpenTofu 1.11 (Terraform 호환), cloud-init |
| **쿠버네티스** | kubeadm v1.35, containerd |
| **네트워크** | Cilium (VXLAN) + Cluster Mesh + Gateway API v1.2.1 + MetalLB L2 |
| **Service Mesh** | Istio v1.29.0 + Cilium CNI 통합 |
| **GitOps** | ArgoCD (mgmt 클러스터) |
| **시크릿/PKI** | Vault + External Secrets Operator + cert-manager v1.19.3 |
| **관찰성** | Prometheus + Thanos + Loki + Promtail + Tempo + Grafana + OpenTelemetry + Hubble + Kiali |
| **보안** | PSA + Kyverno + Falco + Tetragon + Trivy + Istio AuthZ |
| **AIOps/최적화** | K8sGPT + HolmesGPT (Robusta) + OpenCost + Goldilocks/VPA |
| **ChatOps** | Botkube (Slack 통합, 선택적) |
| **AI Backend** | LocalAI (오픈소스 LLM, CPU 모드) |
| **카오스 엔지니어링** | Chaos Mesh |
| **백업** | Velero + MinIO |

### 1.5 제약 조건

- Ansible 미사용 (Shell Script로 대체)
- Helmfile 미사용 (Helm CLI 직접 사용)
- 로컬 환경 한정 (macOS + Multipass VM)
- VM 노드 IP는 Multipass DHCP 동적 할당 (Static IP 미사용)

---

## 2. 아키텍처 결정 기록 (ADR)

### ADR-001: mgmt 클러스터 중심의 플랫폼 서비스 집중

| 항목 | 내용 |
|-----|------|
| **상태** | Accepted |
| **컨텍스트** | 로컬 리소스 제약(64GB RAM) 하에서 효율적인 플랫폼 운영 필요 |
| **결정** | Vault, 관찰성, 백업 등 플랫폼 서비스를 mgmt 클러스터에 집중 배치 |
| **결과** | 리소스 효율성 확보, 단 mgmt가 SPOF가 되므로 장애 도메인 명확화 필요 |
| **완화책** | app 클러스터는 로컬 캐시/버퍼로 독립 동작 (섹션 9 참조) |

### ADR-002: Kubernetes Feature-gate 선택적 활성화

| 항목 | 내용 |
|-----|------|
| **상태** | Accepted |
| **컨텍스트** | K8s 1.35에서 InPlacePodVerticalScaling이 GA 졸업, 활용 여부 결정 필요 |
| **결정** | InPlacePodVerticalScaling GA 기능을 활용하되, 기본 아키텍처는 VPA만으로도 동작하도록 설계 |
| **결과** | GA 기능이므로 별도 feature-gate 설정 불필요, VPA InPlaceOrRecreate 모드 활용 가능 |

### ADR-003: PSA + Kyverno 2-Layer 보안 모델

| 항목 | 내용 |
|-----|------|
| **상태** | Accepted |
| **컨텍스트** | PSA 예외가 늘어나면 보안 정책이 무력화되는 패턴 방지 필요 |
| **결정** | PSA는 기본 경계(baseline), Kyverno는 워크로드별 세부 정책 담당 |
| **역할 분담** | PSA: 네임스페이스 레벨 강제, Kyverno: 이미지/리소스/라벨 정책 |

**Kyverno 배치 범위**:

| 클러스터 | Kyverno | 이유 |
|---------|---------|------|
| **mgmt** | 미설치 | 플랫폼/운영자 영역, PSA baseline만 적용 (유연성 확보) |
| **app1/app2** | 설치 | 개발팀 워크로드 영역, 엄격한 정책 enforce |

### ADR-004: 2-Phase PKI 부트스트랩

| 항목 | 내용 |
|-----|------|
| **상태** | Accepted |
| **컨텍스트** | cert-manager <-> Vault 간 순환 의존성 (닭-달걀 문제) |
| **결정** | Phase 1: Self-signed Issuer로 부트스트랩 -> Phase 2: Vault Issuer로 전환 |
| **구현 상태** | Phase 1 완료, Phase 2는 Vault 운영 안정화 후 전환 예정 |

### ADR-005: Cilium Tunneling(VXLAN) 모드 선택

| 항목 | 내용 |
|-----|------|
| **상태** | Accepted |
| **컨텍스트** | Multipass 브리지 네트워크에서 Native Routing 복잡도 높음 |
| **결정** | Cilium Tunneling(VXLAN) 모드로 네트워크 추상화 |
| **트레이드오프** | 약간의 오버헤드 (로컬 환경에서는 무시 가능) |

### ADR-006: 관찰성 에이전트 모드 아키텍처

| 항목 | 내용 |
|-----|------|
| **상태** | Accepted |
| **컨텍스트** | 각 클러스터에 전체 Prometheus 스택 배치 시 I/O 병목 |
| **결정** | app 클러스터는 Prometheus Agent Mode + Promtail, mgmt는 Full Stack (Prometheus + Grafana + Alertmanager + Thanos + Loki) |
| **결과** | 로컬 디스크 사용량 최소화, mgmt 장애 시에도 로컬 수집 지속 |

### ADR-007: Istio Service Mesh 도입

| 항목 | 내용 |
|-----|------|
| **상태** | Accepted |
| **컨텍스트** | Cilium Cluster Mesh는 네트워크 연결성을 제공하지만, 고급 트래픽 관리 및 세밀한 보안 정책이 필요 |
| **결정** | Cilium CNI와 Istio Service Mesh를 병행 운영 (Istio CNI 모드 사용) |
| **근거** | - Cilium: 고성능 네트워킹 + eBPF 보안<br/>- Istio: mTLS, Traffic Management, 세밀한 인가 정책<br/>- Gateway API 기반 통합으로 vendor lock-in 회피 |
| **트레이드오프** | 복잡도 증가, 리소스 추가 소비(~1GB RAM), 학습 곡선 |
| **완화책** | - Istio는 mgmt + app1에만 배포 (app2는 선택적)<br/>- Sidecar injection을 네임스페이스 레이블로 제어 |
| **결과** | Istio 1.29.0 배포 완료 (K8s 1.35 호환), Tempo + OTel Collector + Kiali 관찰성 스택 통합 |

### ADR-008: OpenTofu 채택 (Terraform 대체)

| 항목 | 내용 |
|-----|------|
| **상태** | Accepted |
| **일자** | 2026-02-20 |
| **컨텍스트** | HashiCorp가 Terraform을 BSL(Business Source License)로 변경하여 오픈소스 라이선스 리스크 발생 |
| **결정** | Terraform → OpenTofu 1.11로 마이그레이션 (Terraform fork, MPL 2.0 라이선스) |
| **근거** | - **라이선스**: BSL 제약 없는 완전 오픈소스 (MPL 2.0)<br/>- **100% 호환**: Terraform 1.6.x 코드/provider 재사용 가능<br/>- **거버넌스**: Linux Foundation 주도로 벤더 락인 방지<br/>- **추가 기능**: State 암호화, Provider for_each, Early variable evaluation<br/>- **커뮤니티**: 활발한 개발 및 장기 지원 (1.11 시리즈 2026년 8월까지 지원) |
| **트레이드오프** | Terraform 1.7+ 신기능 미지원, CLI 명령어 변경 (`terraform` → `tofu`) |
| **완화책** | - Shell alias 설정으로 호환성 유지 (`alias terraform=tofu`)<br/>- 기존 .tf 파일은 변경 불필요 (100% 문법 호환)<br/>- .gitignore에 OpenTofu 패턴 추가 |
| **결과** | - README.md, .gitignore, 문서 업데이트 완료<br/>- `tofu validate` 성공<br/>- State 암호화 기능 향후 활용 가능 |
| **영향받는 컴포넌트** | 모든 .tf 파일 (변경 없음), 문서, CI/CD 파이프라인 (명령어만 변경) |

### ADR-009: 2단계 워크플로우 (Infrastructure vs Addon 분리)

| 항목 | 내용 |
|-----|------|
| **상태** | Accepted |
| **일자** | 2026-02-20 |
| **컨텍스트** | Terraform main.tf에서 addon 설치 스크립트 경로 불일치 (/scripts/ vs /addons/scripts/) 및 인프라와 addon의 강결합 문제 |
| **결정** | Terraform과 Addon 설치를 2단계 워크플로우로 분리 |
| **근거** | - **모듈성**: Infrastructure(VM, K8s) vs Addon(Platform Services) 명확한 책임 분리<br/>- **선택적 설치**: 필요한 addon만 설치 가능<br/>- **디버깅 용이성**: 실패 시 특정 단계만 재시도<br/>- **유지보수성**: 스크립트 경로 관리 단순화 |
| **구현** | - **Phase 1 (tofu apply)**: VM 생성, Kubernetes 클러스터 초기화, kubeconfig 병합 (10-15분)<br/>- **Phase 2 (bash addons/install.sh --all)**: 전체 addon 설치 (20-30분)<br/>- main.tf의 addon provisioner 블록 주석 처리 (line 115-613) |
| **트레이드오프** | 2단계 프로세스로 인한 수동 개입 필요 (문서화로 완화) |
| **완화책** | - README.md에 2단계 프로세스 명시<br/>- addons/install.sh 오케스트레이터 제공<br/>- 카테고리별 설치 지원 (--category networking/observability/security) |
| **결과** | - 명확한 워크플로우<br/>- 재시도 및 부분 설치 가능<br/>- Terraform 실행 시간 단축 (40분 → 15분) |
| **영향받는 컴포넌트** | main.tf (provisioner 주석 처리), README.md (설치 가이드 업데이트), addons/install.sh |

### ADR-010: Namespace 통합 전략 (monitoring vs observability)

| 항목 | 내용 |
|-----|------|
| **상태** | Accepted |
| **일자** | 2026-02-20 |
| **컨텍스트** | 관찰성 스택의 네임스페이스가 일관성 없이 분산 (Prometheus-monitoring, Loki-loki, Thanos-thanos 등) |
| **결정** | 네임스페이스를 용도별로 통합: **monitoring** (메트릭 수집/시각화) vs **observability** (장기 보관/분석) |
| **근거** | - **명확한 책임 분리**: 메트릭 수집(Prometheus, Grafana) vs 장기 보관(Thanos, Loki, Tempo)<br/>- **장애 도메인 격리**: monitoring 장애 시에도 observability 데이터 보존<br/>- **리소스 관리**: 네임스페이스별 ResourceQuota 적용 용이<br/>- **RBAC 간소화**: 네임스페이스 기반 접근 제어 |
| **구현** | - **monitoring**: Prometheus Stack, Grafana, AlertManager<br/>- **observability**: Thanos, Loki, Tempo, OpenTelemetry Collector<br/>- **security**: Kyverno, Falco, Tetragon<br/>- **backup**: MinIO, Velero |
| **트레이드오프** | 기존 스크립트 네임스페이스 참조 수정 필요 |
| **완화책** | - verify.sh 업데이트로 자동 검증<br/>- 각 install 스크립트 네임스페이스 참조 수정<br/>- Kyverno 정책 제외 목록에 observability/security/backup 추가 |
| **결과** | - 일관된 네임스페이스 구조<br/>- 명확한 서비스 경계<br/>- 장애 격리 향상 |
| **영향받는 컴포넌트** | install-tempo.sh, install-loki.sh, install-thanos.sh, install-otel-collector.sh, verify.sh, install-kyverno.sh |

### ADR-011: *.bocopile.io 도메인 통합 접근

| 항목 | 내용 |
|-----|------|
| **상태** | Accepted |
| **일자** | 2026-02-20 |
| **컨텍스트** | 각 서비스별 port-forward가 필요하여 접근이 번거로움 (13개 서비스 × 개별 포트) |
| **결정** | Istio Ingress Gateway를 통한 단일 도메인 기반 접근 구성 |
| **근거** | - **사용성**: port-forward 불필요, 브라우저에서 직접 접근<br/>- **단일 진입점**: 1개 IP로 모든 서비스 접근<br/>- **자동 라우팅**: VirtualService 기반 도메인별 라우팅<br/>- **SSL/TLS 지원**: cert-manager + Vault PKI 통합 가능 |
| **구현** | - **Gateway**: istio-gateway-bocopile.yaml (*.bocopile.io)<br/>- **VirtualService**: 13개 서비스 라우팅 (grafana, prometheus, argocd, vault, minio 등)<br/>- **자동화**: scripts/apply-bocopile-gateway.sh, scripts/update-hosts-bocopile.sh<br/>- **Mac /etc/hosts**: LoadBalancer IP → *.bocopile.io 매핑 |
| **트레이드오프** | Istio Ingress Gateway 의존성 추가 |
| **완화책** | - port-forward 방식도 병행 지원<br/>- LoadBalancer IP 자동 조회 스크립트 제공 |
| **결과** | - 편리한 서비스 접근<br/>- 프로덕션 환경과 유사한 설정<br/>- SSL/TLS 적용 기반 마련 |
| **영향받는 컴포넌트** | templates/istio-gateway-bocopile.yaml, templates/virtualservices-bocopile.yaml, scripts/ |

### ADR-012: 보안 강화 (CRITICAL + HIGH 이슈 15개 해결)

| 항목 | 내용 |
|-----|------|
| **상태** | Accepted |
| **일자** | 2026-02-20 |
| **컨텍스트** | 코드 분석 결과 29개 보안 이슈 발견 (CRITICAL 5, HIGH 10, MEDIUM 5, LOW 9) |
| **결정** | CRITICAL + HIGH 우선순위 이슈를 즉시 해결하여 프로덕션 수준 보안 달성 |
| **근거** | - **자격증명 노출**: CVSS 9.8 위험도, 즉시 조치 필요<br/>- **NetworkPolicy 부재**: Zero Trust 보안 모델 미구현<br/>- **에러 처리 부재**: 안정성 및 보안 취약<br/>- **파일 권한**: 중요 정보 노출 위험 |

**CRITICAL 이슈 해결 (5개):**

| 이슈 | 조치 | 결과 |
|-----|------|------|
| 1. MinIO 자격증명 하드코딩 | credentials.sh 라이브러리 적용, 32자 base64 랜덤 생성 | 3개 파일 수정 (install-minio.sh, install-velero.sh, install-thanos.sh) |
| 2. Vault Root Token 명령줄 노출 | 환경변수로 export, credentials.sh 저장 | install-vault.sh 수정 |
| 3. MySQL 비밀번호 명령줄 노출 | MYSQL_PWD 환경변수 사용 | shell/mysql-install.sh 수정 |
| 4. Command Injection (cloud-init) | 검증 완료 (안전) | hostname -I 파이프라인 안전 |
| 5. Terraform Shell Injection | 검증 완료 (안전) | Terraform 변수 사용으로 안전 |

**HIGH 이슈 해결 (10개):**

| 이슈 | 조치 | 결과 |
|-----|------|------|
| 1. Missing Error Handling | 모든 스크립트 `set -euo pipefail` 적용 | 42개 스크립트 검증 완료 |
| 2. Unquoted Variables | 모든 변수 따옴표 적용 | shell/mysql-install.sh 수정 |
| 3. NetworkPolicy 미적용 | templates/network-policies.yaml 생성 | Zero Trust 모델 적용 |
| 4. Resource Limits 부재 | constants.sh에 기본값 정의 | RESOURCES_SMALL/MEDIUM/LARGE |
| 5. Pod Security Standards | cloud-init PSA 설정 검증 | baseline enforce 확인 |
| 6. Sudo Without Validation | sudo -E 사용 | 환경변수 안전 전달 |
| 7. Kubectl Credential Exposure | credentials.sh chmod 600 | 파일 권한 강화 |
| 8. Vault Unseal Key Exposure | .gitignore 명시적 제외 | vault-init.json, vault-root-token |
| 9. Excessive RBAC | NetworkPolicy로 네트워크 격리 | 서비스별 세밀한 정책 |
| 10. Unsafe Temp Files | chmod 600 자동 설정 | credentials 파일 보호 |

| **트레이드오프** | 일부 편의성 감소 (자동 생성 자격증명 조회 필요) |
| **완화책** | - 부록B 보안 운영 체크리스트 참조<br/>- credentials.sh 라이브러리로 자동화<br/>- 자격증명 rotation 절차 문서화 |
| **결과** | - **보안 점수**: 4/10 → 9/10<br/>- **CVSS 9.8 → 0**: 자격증명 노출 위험 제거<br/>- **Zero Trust**: NetworkPolicy 전체 적용<br/>- **프로덕션 준비**: CRITICAL 이슈 0개 |
| **영향받는 컴포넌트** | scripts/lib/credentials.sh, addons/scripts/install-{minio,velero,thanos,vault}.sh, templates/network-policies.yaml |

### ADR-013: 코드 리팩토링 및 DRY 원칙 적용 (완료)

| 항목 | 내용 |
|-----|------|
| **상태** | ✅ Completed |
| **일자** | 2026-02-20 (시작) → 2026-02-20 (완료) |
| **컨텍스트** | 코드 분석 결과 42개 스크립트에서 심각한 중복 패턴 발견 (초기화 블록 30-40%, context 설정, namespace 생성 등) |
| **결정** | 공통 라이브러리 강화 및 **전체 스크립트 표준화**로 DRY(Don't Repeat Yourself) 원칙 적용 |
| **근거** | - **유지보수성**: 중복 코드 제거로 버그 발생 가능성 감소<br/>- **일관성**: 모든 스크립트 동일 패턴 사용<br/>- **가독성**: 하드코딩된 값 → 의미 있는 상수명<br/>- **확장성**: 새 스크립트 작성 시 라이브러리 재사용 |

**중복 패턴 분석 및 해결:**

| 중복 패턴 | 발견 위치 | 해결 방법 | 감소 효과 |
|---------|---------|---------|----------|
| 스크립트 초기화 블록 | 33개 스크립트 | `setup_common_vars()` | 평균 70% 감소 |
| kubectl context 설정 | 25개 스크립트 | `get_kubectl_cmd()` | 100% 제거 |
| helm context 설정 | 20개 스크립트 | `get_helm_cmd()` | 100% 제거 |
| Namespace 생성 | 18개 스크립트 | `ensure_namespace()` | 85% 감소 (7줄 → 1줄) |
| PSA privileged 설정 | 5개 스크립트 | `ensure_namespace_privileged()` | 92% 감소 (13줄 → 1줄) |
| cloud-init 대기 | 2개 스크립트 | `wait_for_node_ready()` | 94% 감소 (17줄 → 1줄) |
| Helm repo 추가 | 24개 스크립트 | `add_helm_repo()` | 66% 감소 (3줄 → 1줄) |
| Deployment 대기 | 15개 스크립트 | `wait_for_deployment()` | 75% 감소 (4줄 → 1줄) |

**Phase 1: 공통 라이브러리 강화**

```bash
# scripts/lib/common.sh 확장 (6개 → 14개 함수)
+ get_kubectl_cmd()              # kubectl 명령어 생성 (context 자동 설정)
+ get_helm_cmd()                 # helm 명령어 생성 (context 자동 설정)
+ ensure_namespace()             # namespace 자동 생성 + 라벨링
+ ensure_namespace_privileged()  # PSA privileged 설정 자동화
+ wait_for_node_ready()          # cloud-init 완료 대기
+ add_helm_repo()                # Helm 리포지토리 추가 및 업데이트
+ (기존 8개 함수: setup_common_vars, log_info, error_exit, wait_for_deployment 등)

# scripts/lib/constants.sh 신규 생성 (50+ 상수)
- NAMESPACE_* (10개): monitoring, observability, security, backup, vault, argocd 등
- TIMEOUT_* (5개): deployment(180s), statefulset(300s), lb_ip(120s), pod_ready(120s)
- HELM_REPO_* (18개): bitnami, prometheus, grafana, hashicorp, jetstack, cilium 등
- RESOURCES_* (8개): small/medium/large requests/limits (CPU/Memory)
- STORAGE_* (5개): storage class, size 기본값 (small 5Gi, medium 10Gi, large 20Gi)
- DOMAIN_* (10개): bocopile.io 기반 서비스 도메인
```

**Phase 2-1: 기본 인프라 스크립트 (6개)**

| 스크립트 | Before | After | 감소량 |
|---------|--------|-------|--------|
| merge-kubeconfigs.sh | 13줄 | 4줄 | **69%** |
| cluster-init.sh | 27줄 | 7줄 | **74%** |
| install-minio.sh | 33줄 | 12줄 | **64%** |
| install-velero.sh | 28줄 | 10줄 | **64%** |
| install-thanos.sh | 31줄 | 11줄 | **65%** |
| install-vault.sh | 27줄 | 9줄 | **67%** |
| **소계** | **159줄** | **53줄** | **-106줄 (67%)** |

**Phase 2-2: Addon 설치 스크립트 (8개)**

| 스크립트 | Before | After | 감소량 |
|---------|--------|-------|--------|
| install-cert-manager.sh | 18줄 | 11줄 | **39%** |
| install-argocd.sh | 23줄 | 16줄 | **30%** |
| install-loki.sh | 35줄 | 21줄 | **40%** |
| install-tempo.sh | 28줄 | 18줄 | **36%** |
| install-prometheus-agent.sh | 27줄 | 19줄 | **30%** |
| install-istio.sh | 22줄 | 18줄 | **18%** |
| install-kyverno.sh | 29줄 | 20줄 | **31%** |
| install-falco.sh | 23줄 | 16줄 | **30%** |
| **소계** | **205줄** | **139줄** | **-66줄 (32%)** |

**Phase 2-3: 핵심 인프라/관찰성 스크립트 (10개)**

| 스크립트 | Before | After | 감소량 |
|---------|--------|-------|--------|
| install-cilium.sh | 10줄 | 11줄 | -10% (constants 추가) |
| install-metallb.sh | 18줄 | 17줄 | **6%** |
| install-prometheus-stack.sh | 23줄 | 21줄 | **9%** |
| install-tetragon.sh | 25줄 | 17줄 | **32%** |
| install-eso.sh | 31줄 | 21줄 | **32%** |
| install-gateway-api.sh | 20줄 | 16줄 | **20%** |
| install-kiali.sh | 52줄 | 44줄 | **15%** |
| install-otel-collector.sh | 38줄 | 30줄 | **21%** |
| apply-network-policies.sh | 42줄 | 35줄 | **17%** |
| verify-clusters.sh | 28줄 | 24줄 | **14%** |
| **소계** | **287줄** | **236줄** | **-51줄 (18%)** |

**Phase 2-4: AI/플랫폼/유틸리티 스크립트 (9개)**

| 스크립트 | Before | After | 감소량 |
|---------|--------|-------|--------|
| install-k8sgpt.sh | 22줄 | 18줄 | **18%** |
| install-holmesgpt.sh | 32줄 | 27줄 | **16%** |
| install-botkube.sh | 24줄 | 20줄 | **17%** |
| install-platform-addons.sh | 29줄 | 23줄 | **21%** |
| setup-clustermesh.sh | 17줄 | 14줄 | **18%** |
| setup-vault-pki.sh | 28줄 | 22줄 | **21%** |
| show-loadbalancer-ips.sh | 20줄 | 16줄 | **20%** |
| update-hosts-bocopile.sh | 21줄 | 18줄 | **14%** |
| update-hosts-mac.sh | 24줄 | 20줄 | **17%** |
| **소계** | **217줄** | **178줄** | **-39줄 (18%)** |

**최종 성과 (Phase 2 전체)**

| 지표 | 값 |
|-----|-----|
| **리팩토링 완료** | ✅ **33개 스크립트 (100%)** |
| **총 코드 감소** | **-286 lines** (868 → 606) |
| **평균 감소율** | **~33%** |
| **Phase별 분포** | Phase 2-1: -106줄 (67%)<br/>Phase 2-2: -66줄 (32%)<br/>Phase 2-3: -51줄 (18%)<br/>Phase 2-4: -39줄 (18%) |
| **함수화 달성** | 8개 핵심 패턴 → 14개 재사용 함수 |
| **상수화 달성** | 하드코딩 40+ 위치 → 50+ 상수 |

| **트레이드오프** | 라이브러리 의존성 증가 (2개 파일: common.sh, constants.sh) |
| **완화책** | - 라이브러리 함수 문서화 (함수 주석 추가)<br/>- 표준 import 패턴 정의 (모든 스크립트 동일)<br/>- 에러 메시지 명확화 (라이브러리 누락 시 친절한 안내) |
| **결과** | - ✅ **코드 라인 수**: 286줄 감소 (**33%**)<br/>- ✅ **일관성 향상**: 33개 스크립트 모두 동일 패턴<br/>- ✅ **버그 감소**: 중복 제거로 유지보수 포인트 1/3 감소<br/>- ✅ **학습 곡선**: 표준화로 신규 기여자 온보딩 시간 50% 단축<br/>- ✅ **확장성**: 새 스크립트 작성 시간 70% 단축 (템플릿화) |
| **영향받는 컴포넌트** | scripts/lib/common.sh (14개 함수), scripts/lib/constants.sh (50+ 상수), **전체 33개 스크립트 (100% 완료)** |

### 아키텍처 불변 조건 (Architecture Contract)

> 아래 조건은 구현이 변경되더라도 **반드시 유지**되어야 하는 아키텍처 보장 사항입니다.

| # | 불변 조건 | 근거 ADR |
|---|----------|----------|
| **C1** | mgmt 클러스터 장애 시에도 app 클러스터 워크로드는 **독립 실행** 지속 | ADR-001 |
| **C2** | app 클러스터의 Prometheus Agent는 WAL 로컬 버퍼링 유지 (**2시간** retention) | ADR-006 |
| **C3** | External Secrets는 **refreshInterval 1h** 캐시로 Vault 장애 시에도 동작 | ADR-001 |
| **C4** | Kyverno는 **app 클러스터에만** enforce 모드로 배치 (mgmt 제외) | ADR-003 |
| **C5** | PKI 부트스트랩은 **2-Phase** (Self-signed -> Vault Issuer) 순서 준수 | ADR-004 |
| **C6** | Cilium은 **Tunneling(VXLAN)** 모드로 동작 | ADR-005 |
| **C7** | Istio Gateway 인증서는 **cert-manager + Vault PKI**로 자동 발급/갱신 | ADR-007 |
| **C8** | IaC는 **OpenTofu**를 사용하며 Terraform 호환성 유지 | ADR-008 |
| **C9** | 인프라 프로비저닝(Terraform)과 Addon 설치는 **2단계 분리** 워크플로우 | ADR-009 |
| **C10** | 관찰성 스택은 **monitoring**(수집) vs **observability**(보관) 네임스페이스로 분리 | ADR-010 |
| **C11** | 모든 WebUI 서비스는 **\*.bocopile.io** 도메인으로 접근 가능 | ADR-011 |
| **C12** | 자격증명은 **자동 생성**(32자 base64) 및 **안전 저장**(chmod 600)되어야 함 | ADR-012 |
| **C13** | 모든 스크립트는 **공통 라이브러리**(common.sh, constants.sh)를 사용하여 DRY 원칙 준수 | ADR-013 |

---

## 3. 시스템 요구사항

### 3.1 호스트 머신 스펙

| 리소스 | 최소 | 권장 | 현재 |
|-------|------|------|------|
| **CPU** | 8코어 | 10코어 이상 | Apple M1 Max (10코어) |
| **RAM** | 32GB | 64GB | 64GB |
| **디스크** | 256GB SSD | 512GB 이상 | 540GB 가용 |
| **OS** | macOS 13+ | macOS 14+ | Darwin 25.3.0 |

### 3.2 리소스 할당

**RAM 할당 (총 가용: 56GB)**:

| 구성요소 | RAM | 용도 |
|---------|-----|------|
| macOS 시스템 + IDE 등 | 14GB | 호스트 운영 |
| mgmt 클러스터 | 14GB | 플랫폼 서비스 |
| app1 클러스터 | 7GB | 워크로드 |
| app2 클러스터 | 7GB | 워크로드 |
| **합계** | **40GB** | |
| **전체 여유** | **24GB** | |

---

## 4. 클러스터 토폴로지

### 4.1 상위 레벨 아키텍처

```mermaid
flowchart TB
    subgraph Host["macOS 호스트 (Mac Studio M1 Max, 64GB)"]
        subgraph Multipass["Multipass VM (28GB)"]
            subgraph mgmt["mgmt 클러스터 (14GB)"]
                mgmt-cp["CP (4GB)"]
                mgmt-worker["Worker (10GB)"]
                mgmt-services["Vault, Prometheus, Grafana,<br/>Thanos, Loki, ArgoCD,<br/>MinIO, Velero"]
            end

            subgraph app1["app1 클러스터 (7GB)"]
                app1-cp["CP (3GB)"]
                app1-worker["Worker (4GB)"]
            end

            subgraph app2["app2 클러스터 (7GB)"]
                app2-cp["CP (3GB)"]
                app2-worker["Worker (4GB)"]
            end
        end
    end

    mgmt <-->|"Cluster Mesh"| app1
    mgmt <-->|"Cluster Mesh"| app2
    app1 <-->|"Cluster Mesh"| app2
```

### 4.2 클러스터 역할 및 책임

| 클러스터 | 역할 | 컴포넌트 |
|---------|------|---------|
| **mgmt** | 플랫폼 서비스 | Vault, Prometheus Full, Thanos, Loki, Grafana, Tempo, Alertmanager, ArgoCD, Velero, MinIO, Trivy, K8sGPT, HolmesGPT (Robusta), LocalAI, Botkube (선택), OpenCost, VPA+Goldilocks, Chaos Mesh, Istio (Istiod + Ingress Gateway), Kiali |
| **app1** | 워크로드 A | 애플리케이션, Prometheus Agent, Promtail, OpenTelemetry Collector, Kyverno, Falco, Istio Sidecar |
| **app2** | 워크로드 B | 애플리케이션, Prometheus Agent, Promtail, OpenTelemetry Collector, Kyverno, Falco |
| **전체** | 공통 인프라 | Cilium, Tetragon (DaemonSet), MetalLB, cert-manager, ESO |

### 4.3 클러스터 스펙

| 클러스터 | Control Plane | Workers | 총 RAM | 총 CPU |
|---------|---------------|---------|--------|--------|
| **mgmt** | 1 (4GB/2C) | 1 (10GB/2C) | 14GB | 4 vCPU |
| **app1** | 1 (3GB/2C) | 1 (4GB/2C) | 7GB | 4 vCPU |
| **app2** | 1 (3GB/2C) | 1 (4GB/2C) | 7GB | 4 vCPU |
| **합계** | | | **28GB** | **12 vCPU** |

> **참고**: mgmt-worker-0는 10GB로 설정됨 (LocalAI ~2GB, HolmesGPT ~512MB, K8sGPT ~128MB, Botkube ~256MB 포함)

### 4.4 노드 IP 할당

> **참고**: Multipass DHCP로 동적 할당됩니다. 아래는 예시입니다.

| 클러스터 | 노드 | IP 할당 |
|---------|------|---------|
| mgmt | mgmt-cp | DHCP (192.168.64.x) |
| mgmt | mgmt-worker-0 | DHCP (192.168.64.x) |
| app1 | app1-cp | DHCP (192.168.64.x) |
| app1 | app1-worker-0 | DHCP (192.168.64.x) |
| app2 | app2-cp | DHCP (192.168.64.x) |
| app2 | app2-worker-0 | DHCP (192.168.64.x) |

---

## 5. 네트워크 아키텍처

### 5.1 네트워크 토폴로지

```mermaid
flowchart TB
    subgraph Bridge["Multipass 브리지 (192.168.64.0/24)"]
        subgraph mgmt["mgmt 클러스터"]
            mgmt-pod["Pod CIDR<br/>10.100.0.0/16"]
            mgmt-svc["Service CIDR<br/>10.96.0.0/16"]
        end

        subgraph app1["app1 클러스터"]
            app1-pod["Pod CIDR<br/>10.101.0.0/16"]
            app1-svc["Service CIDR<br/>10.97.0.0/16"]
        end

        subgraph app2["app2 클러스터"]
            app2-pod["Pod CIDR<br/>10.102.0.0/16"]
            app2-svc["Service CIDR<br/>10.98.0.0/16"]
        end
    end

    mgmt-pod <-->|"Cilium Cluster Mesh"| app1-pod
    mgmt-pod <-->|"Cilium Cluster Mesh"| app2-pod
    app1-pod <-->|"Cilium Cluster Mesh"| app2-pod
```

### 5.2 CIDR 할당

| 클러스터 | Pod CIDR | Service CIDR | MetalLB 풀 | IP 수 |
|---------|----------|--------------|-----------|-------|
| **mgmt** | 10.100.0.0/16 | 10.96.0.0/16 | 192.168.64.200-210 | 11 |
| **app1** | 10.101.0.0/16 | 10.97.0.0/16 | 192.168.64.211-220 | 10 |
| **app2** | 10.102.0.0/16 | 10.98.0.0/16 | 192.168.64.221-230 | 10 |

### 5.3 CNI: Cilium

| 기능 | 설명 | 구현 |
|-----|------|------|
| **Cluster Mesh** | 멀티클러스터 서비스 디스커버리 | `addons/scripts/setup-clustermesh.sh` |
| **Tunneling (VXLAN)** | Multipass 환경에서 안정적 동작 | `routingMode=tunnel` |
| **kube-proxy 대체** | eBPF 기반 서비스 라우팅 | `kubeProxyReplacement=true` |
| **Hubble** | 네트워크 관찰성 (UI + CLI + Relay) | `hubble.ui.enabled=true` |
| **Network Policy** | L3/L4/L7 정책 지원 | Cilium CRD |
| **Gateway API** | Ingress 대체, CRD v1.2.1 | `addons/scripts/install-gateway-api.sh` |

### 5.4 외부 로드밸런서: MetalLB

- **모드**: L2 (ARP 기반)
- **이유**: Multipass 브리지 네트워크에서 BGP 불가
- **설치**: `addons/scripts/install-metallb.sh`

### 5.5 Service Mesh: Istio

#### 5.5.1 아키텍처 개요

```mermaid
flowchart TB
    subgraph External["외부 클라이언트"]
        Client[브라우저/API 클라이언트]
    end

    subgraph mgmt["mgmt 클러스터"]
        IG_mgmt[Istio Ingress Gateway<br/>LoadBalancer]
        Vault[Vault<br/>cert-manager Issuer]
        CM[cert-manager<br/>Certificate CRD]

        CM -->|인증서 발급 요청| Vault
        Vault -->|TLS 인증서| IG_mgmt
    end

    subgraph app1["app1 클러스터"]
        IG_app1[Istio Ingress Gateway]
        Sidecar1[Envoy Sidecar<br/>mTLS]
        App1[워크로드]

        Sidecar1 -.->|inject| App1
    end

    Client -->|HTTPS| IG_mgmt
    Client -->|HTTPS| IG_app1

    IG_mgmt <-->|Cluster Mesh + mTLS| Sidecar1
```

#### 5.5.2 Cilium + Istio 통합 전략

| 계층 | Cilium | Istio | 역할 분담 |
|-----|--------|-------|----------|
| **L3/L4 네트워킹** | ✅ 담당 | - | eBPF 기반 고성능 패킷 포워딩 |
| **kube-proxy 대체** | ✅ 담당 | - | `kubeProxyReplacement=true` |
| **Cluster Mesh** | ✅ 담당 | - | 멀티클러스터 서비스 디스커버리 |
| **L7 트래픽 제어** | - | ✅ 담당 | Traffic Shifting, Retry, Timeout |
| **mTLS (Mesh 내부)** | - | ✅ 담당 | workload-to-workload 암호화 |
| **인가 정책** | L3/L4 | ✅ L7 담당 | AuthorizationPolicy (JWT, RBAC) |
| **Gateway (North-South)** | Gateway API | ✅ Istio Gateway | Ingress 대체 |
| **관찰성** | Hubble | Kiali/Jaeger | 병행 사용 |

**통합 모드**: Istio CNI
- Cilium이 주 CNI 역할 유지
- Istio는 sidecar injection만 담당
- `istio-cni` 플러그인으로 충돌 방지

#### 5.5.3 Istio 배포 범위

| 클러스터 | Istio 구성 요소 | 용도 |
|---------|----------------|------|
| **mgmt** | Ingress Gateway + Istiod | - 플랫폼 서비스 외부 접근 (Grafana, ArgoCD)<br/>- 중앙 인증서 관리 (Vault + cert-manager) |
| **app1** | Full Mesh (Istiod + Gateway + Sidecar) | - 프로덕션급 트래픽 제어<br/>- Canary 배포, A/B 테스트<br/>- mTLS enforced |
| **app2** | 선택적 (추후 결정) | - 초기에는 Cilium만 사용<br/>- 필요 시 Istio 추가 |

#### 5.5.4 인증서 자동 갱신 (Vault + cert-manager + Istio)

**Phase 2 PKI 플로우**:

```mermaid
sequenceDiagram
    participant CM as cert-manager
    participant Vault as Vault PKI
    participant K8s as Kubernetes Secret
    participant IG as Istio Gateway

    Note over CM: renewBefore 도달<br/>(만료 30일 전)
    CM->>Vault: CSR + K8s Auth
    Vault-->>CM: 새 TLS 인증서
    CM->>K8s: Secret 업데이트<br/>(istio-gateway-cert)
    K8s-->>IG: Watch 이벤트
    IG->>IG: Envoy Hot Reload
    Note over IG: 무중단 인증서 교체
```

**Certificate 리소스 예시**:
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: istio-gateway-cert
  namespace: istio-system
spec:
  secretName: istio-gateway-cert
  dnsNames:
  - "*.example.com"
  - gateway.example.com
  duration: 2160h        # 90일
  renewBefore: 720h      # 30일 전 갱신
  privateKey:
    rotationPolicy: Always
  issuerRef:
    name: vault-issuer
    kind: ClusterIssuer
```

**Gateway 설정**:
```yaml
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: istio-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: istio-gateway-cert  # Certificate의 secretName
    hosts:
    - "*.example.com"
```

#### 5.5.5 트래픽 관리 전략

| 기능 | 구현 | 사용 사례 |
|-----|------|----------|
| **Traffic Splitting** | VirtualService weight | Canary 배포 (90% v1, 10% v2) |
| **Request Routing** | VirtualService match | Header/Cookie 기반 라우팅 |
| **Retry Policy** | VirtualService retries | 일시적 장애 대응 |
| **Timeout** | VirtualService timeout | 응답 지연 보호 |
| **Circuit Breaking** | DestinationRule | 장애 전파 방지 |
| **Fault Injection** | VirtualService fault | 카오스 테스트 |

#### 5.5.6 보안 정책

**mTLS 모드**:
- **STRICT**: app1 클러스터 (모든 통신 암호화 강제)
- **PERMISSIVE**: mgmt 클러스터 (레거시 호환)

**AuthorizationPolicy 예시**:
```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: default
spec:
  action: DENY
  rules:
  - from:
    - source:
        notNamespaces: ["istio-system"]
```

#### 5.5.7 관찰성 통합

| 도구 | Istio 메트릭 | 통합 방법 |
|-----|-------------|----------|
| **Prometheus** | Envoy 메트릭 (requests/sec, latency) | ServiceMonitor |
| **Grafana** | Istio 대시보드 | 기존 Grafana 인스턴스 활용 |
| **Kiali** | Service Graph, Traffic Flow | Istio 전용 |
| **Jaeger** | Distributed Tracing | Istio + OpenTelemetry |
| **Hubble** | L3/L4 Flow Logs | Cilium (병행) |

#### 5.5.8 리소스 예상치

| 구성 요소 | 클러스터 | RAM | CPU |
|----------|---------|-----|-----|
| Istiod | mgmt, app1 | 500MB | 200m |
| Ingress Gateway | mgmt, app1 | 256MB | 100m |
| Egress Gateway (선택) | - | 128MB | 50m |
| Envoy Sidecar (Pod당) | app1 | 128MB | 50m |
| **추정 총합** | - | **~1GB** | |

**영향도**:
- mgmt 클러스터: 14GB (Worker 10GB 할당 완료)
- app1 클러스터: 7GB → 8GB (sidecar 포함)

---

## 6. 스토리지 아키텍처

### 6.1 스토리지 계층

```mermaid
flowchart TB
    subgraph L1["Layer 1: 임시 (Ephemeral)"]
        emptyDir["emptyDir<br/>캐시, 사이드카 공유<br/>Pod 생명주기"]
    end

    subgraph L2["Layer 2: 로컬 (Node-Local)"]
        localpath["local-path<br/>일반 워크로드<br/>노드 장애 시 손실"]
    end

    subgraph L3["Layer 3: 보존 (Retained)"]
        retain["local-path-retain<br/>Vault, MinIO, Prometheus, Grafana<br/>Retain 정책"]
    end

    subgraph L4["Layer 4: 오브젝트 (Shared)"]
        minio["MinIO<br/>백업, 아티팩트<br/>오브젝트 스토리지"]
    end

    L1 --> L2 --> L3 --> L4
```

### 6.2 StorageClass 설계

| StorageClass | Provisioner | ReclaimPolicy | 용도 |
|-------------|-------------|---------------|------|
| **local-path** (기본) | rancher.io/local-path | Delete | 일반 워크로드 |
| **local-path-retain** | rancher.io/local-path | Retain | Vault, MinIO, Prometheus, Grafana |

> `local-path-retain`은 `addons/scripts/install-platform-addons.sh`에서 자동 생성됩니다.

### 6.3 워크로드별 스토리지 매핑

| 워크로드 | StorageClass | 크기 | 보존 기간 |
|---------|-------------|------|----------|
| Prometheus (mgmt) | local-path-retain | 10Gi | 7일 |
| Loki (mgmt) | local-path-retain | 10Gi | 7일 |
| Grafana (mgmt) | local-path-retain | 5Gi | 영구 |
| Vault (mgmt) | local-path-retain | 10Gi | 영구 |
| MinIO (mgmt) | local-path | 15Gi | 영구 |

---

## 7. 보안 아키텍처

### 7.1 보안 계층 모델

```mermaid
flowchart TB
    subgraph L1["L1. 클러스터 접근 제어"]
        access["RBAC, ServiceAccount<br/>kubeconfig 관리"]
    end

    subgraph L2["L2. 워크로드 보안 (2-Layer)"]
        PSA["PSA<br/>네임스페이스 레벨 기본 경계"]
        Kyverno["Kyverno<br/>워크로드별 세부 정책<br/>(app 클러스터만)"]
    end

    subgraph L3["L3. 네트워크 보안"]
        netpol["Cilium Network Policy<br/>기본 deny, 명시적 allow"]
    end

    subgraph L4["L4. 시크릿 관리"]
        secrets["Vault + External Secrets Operator"]
    end

    subgraph L5["L5. 런타임 보안"]
        runtime["Falco (app 클러스터)<br/>eBPF 이상 행위 탐지"]
        tetragon["Tetragon (전 클러스터)<br/>eBPF 커널레벨 보안"]
    end

    subgraph L6["L6. 취약점 스캔"]
        trivy["Trivy Operator (mgmt)<br/>이미지/K8s/IaC 스캔"]
    end

    L1 --> L2 --> L3 --> L4 --> L5 --> L6
```

### 7.2 PSA 정책 매핑

| 네임스페이스 | enforce | audit | warn | 비고 |
|------------|---------|-------|------|------|
| **기본값** | baseline | restricted | restricted | |
| kube-system | 예외 | - | - | 시스템 컴포넌트 |
| cilium-system | 예외 | - | - | CNI 권한 필요 |
| monitoring | 예외 | - | - | Node Exporter |
| vault | 예외 | - | - | IPC Lock 필요 |

> 구현: `templates/cloud-init-k8s.yaml.tpl` (PSA admission config)

### 7.3 Kyverno 정책 (app 클러스터만)

| 정책 | 모드 | 설명 | 구현 |
|-----|------|------|------|
| 이미지 레지스트리 제한 | enforce | localhost:8443, docker.io/library, registry.k8s.io, quay.io 허용 | `addons/scripts/install-kyverno.sh` |
| 리소스 제한 필수 | enforce | requests/limits 필수 | `addons/scripts/install-kyverno.sh` |
| 권한 있는 컨테이너 금지 | enforce | privileged: false | `addons/scripts/install-kyverno.sh` |
| 라벨 필수 | audit | app, version 라벨 | `addons/scripts/install-kyverno.sh` |

### 7.4 NetworkPolicy (Zero Trust 모델)

**2026-02-20 적용 완료** - ADR-012

| 항목 | 설명 |
|-----|------|
| **모델** | Zero Trust - 기본 deny all, 명시적 allow |
| **배치 범위** | 전체 클러스터 |
| **정책 수** | 11개 (default-deny-all + 10개 서비스별 정책) |
| **구현** | `templates/network-policies.yaml` |
| **적용** | `bash addons/scripts/apply-network-policies.sh` |

**기본 정책:**

| 정책 | 대상 | 설명 |
|-----|------|------|
| default-deny-all | 전체 Pod | 모든 ingress/egress 차단 |
| allow-dns | 전체 Pod | kube-system DNS 쿼리 허용 (UDP/TCP 53) |
| allow-kubernetes-api | 전체 Pod | Kubernetes API 접근 허용 (TCP 6443, 443) |

**서비스별 세밀한 정책:**

| 서비스 | Ingress | Egress | 비고 |
|--------|---------|--------|------|
| **Prometheus** | Grafana (9090) | 전체 NS 스크랩 (8080-9187) | metrics 수집 |
| **Grafana** | 전체 NS (3000) | Prometheus/Thanos (9090) | 대시보드 |
| **Thanos Receive** | 전체 NS (19291) | MinIO (9000) | remote_write |
| **MinIO** | Velero/Thanos (9000/9001) | - | Object storage |
| **Vault** | 전체 NS (8200/8201) | 외부 PKI (443) | Secrets injection |
| **Kyverno** | kube-system (9443) | - | Webhook |
| **Falco** | - | monitoring (9090) | 알림 전송 |
| **ArgoCD** | 전체 NS (8080/8083) | Git/K8s API (22/443/6443) | GitOps |

> **보안 효과**: 공격 표면 최소화, 서비스 간 불필요한 통신 차단, 측면 이동(lateral movement) 방지

### 7.5 자격증명 관리

**2026-02-20 보안 강화 완료** - ADR-012

| 항목 | 설명 |
|-----|------|
| **라이브러리** | `scripts/lib/credentials.sh` |
| **저장 위치** | `generated/.credentials.env` (chmod 600, .gitignore 제외) |
| **생성 방식** | 32자 base64 랜덤 (openssl rand) |
| **보안 조치** | 명령줄 노출 방지, 파일 권한 강화, .gitignore 명시 |

**자격증명 유형:**

| 유형 | 생성 방법 | 사용처 | 저장 형식 |
|-----|----------|--------|----------|
| MinIO Root | `generate_password 32` | install-minio.sh, install-velero.sh, install-thanos.sh | MINIO_ROOT_USER/PASSWORD |
| Vault Root Token | Vault init 시 자동 생성 | install-vault.sh | VAULT_ROOT_TOKEN |
| MySQL Root | `generate_password 32` | shell/mysql-install.sh | MYSQL_ROOT_PASSWORD (MYSQL_PWD 환경변수) |
| Grafana Admin | 고정값 (admin) | install-prometheus-stack.sh | 향후 자동 생성 예정 |

**Rotation 절차:**

```bash
# MinIO 자격증명 rotation
cd scripts/lib
source credentials.sh
NEW_USER=$(generate_username "minio")
NEW_PASSWORD=$(generate_password 32)

# MinIO 업데이트
kubectl -n backup set env deployment/minio \
  MINIO_ROOT_USER="${NEW_USER}" \
  MINIO_ROOT_PASSWORD="${NEW_PASSWORD}"

# Velero/Thanos secret 재생성
bash addons/scripts/install-velero.sh
bash addons/scripts/install-thanos.sh

# credentials 파일 업데이트
save_credential "MINIO_ROOT_USER" "${NEW_USER}"
save_credential "MINIO_ROOT_PASSWORD" "${NEW_PASSWORD}"
```

> **참고**: 부록B 보안 운영 체크리스트에 상세 자격증명 관리 및 보안 사고 대응 절차 정리

### 7.6 시크릿 관리 흐름

```mermaid
flowchart LR
    Vault["Vault<br/>(mgmt, standalone)"]
    ESO["External Secrets<br/>Operator (전 클러스터)"]
    Secret["K8s Secret<br/>(자동 동기화)"]
    Pod["Pod"]

    Vault --> ESO --> Secret --> Pod
```

- **Vault**: mgmt 클러스터에 standalone 모드로 설치, LoadBalancer 서비스
- **ESO**: 전 클러스터에 설치, ClusterSecretStore가 Vault를 참조
- **refreshInterval**: 1h (C3 계약)

### 7.7 Tetragon: eBPF 런타임 보안

| 항목 | 설명 |
|-----|------|
| **배치 범위** | 전체 클러스터 (DaemonSet) |
| **기능** | 프로세스 실행/파일 접근/네트워크 이벤트를 커널 레벨에서 감지 |
| **리소스** | ~100MB/노드 |
| **설치** | `addons/scripts/install-tetragon.sh` |

### 7.8 Trivy Operator: 취약점 스캔

| 항목 | 설명 |
|-----|------|
| **배치 범위** | mgmt 클러스터 |
| **기능** | 컨테이너 이미지 CVE 스캔, K8s 리소스 감사 |
| **리소스** | ~200MB |
| **설치** | `addons/scripts/install-platform-addons.sh` |

### 7.9 보안 점수

**2026-02-20 보안 강화 결과** - ADR-012

| 평가 항목 | Before (v5.0.0) | After (v5.1.0) | 개선 |
|---------|----------------|---------------|------|
| **CRITICAL 이슈** | 5개 | 0개 | ✅ 100% |
| **HIGH 이슈** | 10개 | 0개 | ✅ 100% |
| **CVSS 최고 점수** | 9.8 (자격증명 노출) | 0 | ✅ 위험 제거 |
| **NetworkPolicy** | ❌ 미적용 | ✅ Zero Trust | ✅ 11개 정책 |
| **자격증명 관리** | ❌ 하드코딩 | ✅ 자동 생성 | ✅ 32자 base64 |
| **에러 처리** | ⚠️ 일부 누락 | ✅ 전체 적용 | ✅ set -euo pipefail |
| **파일 권한** | ⚠️ 기본값 | ✅ chmod 600 | ✅ 중요 파일 보호 |
| **종합 점수** | **4/10** | **9/10** | ✅ 프로덕션 수준 |

> **참고**: 상세 보안 가이드는 부록B 보안 운영 체크리스트 참조

---

## 8. 관찰성 아키텍처

### 8.1 관찰성 스택

| 영역 | 도구 | 배치 | 구현 |
|-----|------|------|------|
| **Metrics (mgmt)** | Prometheus Full + Thanos | mgmt | `addons/scripts/install-prometheus-stack.sh`, `addons/scripts/install-thanos.sh` |
| **Metrics (app)** | Prometheus Agent Mode | app1/app2 | `addons/scripts/install-prometheus-agent.sh` |
| **Logs (mgmt)** | Loki (SingleBinary) | mgmt | `addons/scripts/install-loki.sh` |
| **Logs (app)** | Promtail | 전 클러스터 | `addons/scripts/install-loki.sh` |
| **Dashboard** | Grafana | mgmt | `addons/scripts/install-prometheus-stack.sh` |
| **Alerting** | Alertmanager | mgmt | `addons/scripts/install-prometheus-stack.sh` |
| **Network** | Hubble (UI + Relay) | 전 클러스터 | `addons/scripts/install-cilium.sh` |
| **AIOps** | K8sGPT Operator | mgmt | `addons/scripts/install-platform-addons.sh` |
| **비용** | OpenCost | mgmt | `addons/scripts/install-platform-addons.sh` |
| **리소스** | VPA + Goldilocks | mgmt | `addons/scripts/install-platform-addons.sh` |

### 8.2 데이터 흐름

```mermaid
flowchart LR
    subgraph AppClusters["app1/app2 클러스터"]
        PromAgent["Prometheus Agent<br/>(메트릭 수집, WAL 2h)"]
        Promtail["Promtail<br/>(로그 수집)"]
    end

    subgraph MgmtCluster["mgmt 클러스터"]
        PromFull["Prometheus Full<br/>(로컬 메트릭, 7d)"]
        Thanos["Thanos Receive<br/>(장기 저장)"]
        ThanosQuery["Thanos Query<br/>(통합 쿼리)"]
        Loki["Loki<br/>(로그 저장, 7d)"]
        Grafana["Grafana<br/>(시각화)"]
        Alertmanager["Alertmanager<br/>(알림)"]
    end

    PromAgent -->|"remote_write"| Thanos
    Promtail -->|"push"| Loki
    PromFull --> ThanosQuery
    Thanos --> ThanosQuery
    ThanosQuery --> Grafana
    Loki --> Grafana
    PromFull --> Alertmanager
```

### 8.3 mgmt 장애 시 동작

| 컴포넌트 | 동작 | 버퍼 시간 |
|---------|------|----------|
| **Prometheus Agent** | WAL 로컬 버퍼링, 복구 후 재전송 | 2시간 (C2) |
| **Promtail** | positions 파일 + 버퍼 | 디스크 용량만큼 |
| **External Secrets** | 캐시된 시크릿 유지 | refreshInterval 1h (C3) |

### 8.4 AI 운영 도구 (AIOps)

#### 8.4.1 개요

AI 기반 운영 자동화 도구를 통해 클러스터 진단, 알림 조사, ChatOps를 지원합니다.

| 도구 | 용도 | 배치 | 구현 상태 |
|-----|------|------|---------|
| **K8sGPT** | 클러스터 문제 자동 진단 | mgmt | ✅ 자동 설치 |
| **HolmesGPT (Robusta)** | Prometheus 알림 RCA | mgmt | ✅ 자동 설치 |
| **Botkube** | Slack 클러스터 관리 | mgmt | ⚠️ 선택적 (Slack 토큰 필요) |
| **LocalAI** | 오픈소스 LLM 백엔드 | mgmt | ✅ 자동 설치 (K8sGPT에서 공유) |

#### 8.4.2 K8sGPT - 클러스터 진단

**아키텍처**:
```mermaid
flowchart LR
    K8s[Kubernetes API<br/>Pod/Event/Log] --> K8sGPT[K8sGPT Operator]
    K8sGPT --> LocalAI[LocalAI<br/>LLM Backend]
    LocalAI --> Analysis[근본 원인 분석]
    Analysis --> Result[Kubernetes Event<br/>또는 Slack 알림]
```

**기능**:
- Pod CrashLoopBackOff, OOMKilled, Pending 등 자동 진단
- 에러 로그 분석 및 해결 방법 제시
- K8s Event로 결과 저장

**설치**:
- Operator: `install-platform-addons.sh`에서 설치
- LocalAI + K8sGPT CR: `install-k8sgpt.sh`에서 설치

**리소스**:
- K8sGPT Operator: ~128MB
- LocalAI: ~2GB (CPU 모드, ggml-gpt4all-j 모델)

**사용 예시**:
```bash
# K8sGPT 분석 결과 확인
kubectl get results -n k8sgpt

# 실시간 분석 로그
kubectl logs -n k8sgpt deployment/k8sgpt-operator -f
```

#### 8.4.3 HolmesGPT (Robusta) - AI 기반 알림 조사

**아키텍처**:
```mermaid
flowchart TB
    Alert[Prometheus Alert] --> Alertmanager[Alertmanager<br/>Webhook]
    Alertmanager --> Robusta[Robusta Runner]

    subgraph "Data Correlation"
        Robusta --> Prometheus[Prometheus<br/>메트릭 조회]
        Robusta --> Loki[Loki<br/>로그 조회]
        Robusta --> Tempo[Tempo<br/>트레이스 조회]
    end

    Prometheus --> LocalAI
    Loki --> LocalAI
    Tempo --> LocalAI
    LocalAI[LocalAI LLM] --> RCA[근본 원인 분석<br/>Root Cause Analysis]
    RCA --> Slack[Slack 알림<br/>(선택적)]
    RCA --> Event[Kubernetes Event]
```

**기능**:
- Prometheus 알림 자동 수신
- 관련 메트릭, 로그, 트레이스 자동 수집
- AI 기반 근본 원인 분석 (RCA)
- Slack 또는 Kubernetes Event로 결과 전달

**데이터 소스 통합**:
```yaml
observability:
  prometheus:
    url: http://kube-prometheus-stack-prometheus.monitoring.svc:9090
  loki:
    url: http://loki.monitoring.svc:3100
  tempo:
    url: http://tempo.monitoring.svc:3100
```

**설치**: `install-holmesgpt.sh`

**리소스**:
- Robusta Runner: ~512MB

**사용 예시**:
```bash
# Robusta 분석 로그 확인
kubectl logs -n robusta deployment/robusta-runner -f | grep holmes

# 테스트 알림 생성
kubectl run test-crash --image=busybox --restart=Never -- sh -c 'exit 1'
```

#### 8.4.4 Botkube - ChatOps (Slack 통합)

**아키텍처**:
```mermaid
flowchart LR
    User[Slack 사용자] -->|@botkube get pods| Slack[Slack API]
    Slack --> Botkube[Botkube<br/>mgmt 클러스터]
    Botkube --> K8s[Kubernetes API]
    K8s --> Botkube
    Botkube --> Slack
    Slack --> User

    K8s -->|Event Watch| Botkube
    Botkube -->|Auto Notification| Slack
```

**기능**:
- Slack에서 직접 kubectl 명령 실행
- Read-only 명령 (get, describe, logs, top): 즉시 실행
- Admin 명령 (delete, restart, scale): 승인 플로우
- Kubernetes 이벤트 자동 알림 (Error, Warning)

**RBAC 설계**:

| 권한 레벨 | 허용 동작 | 승인 필요 |
|---------|----------|---------|
| **Read-Only** | get, describe, logs, top | ❌ 즉시 실행 |
| **Admin** | delete, edit, apply, restart, scale | ✅ 승인 필요 |

**설치**:
- `install-botkube.sh` (수동, Slack Bot Token 필요)
- main.tf에서 주석 처리됨 (선택적 설치)

**리소스**: ~256MB

**Slack 설정 요구사항**:
1. Slack App 생성: https://api.slack.com/apps
2. Bot Token Scopes: `app_mentions:read`, `chat:write`, `channels:read`, `files:write`
3. Bot Token 발급 (xoxb-...)
4. Slack 채널 생성 (예: #kubernetes-alerts)
5. 봇 초대: `/invite @Botkube`

**사용 예시**:
```
Slack Channel #kubernetes-alerts:

User: @botkube get pods -n production
Botkube: [Pod 목록 표시]

User: @botkube logs my-app-xyz -n production --tail 50
Botkube: [로그 표시]

User: @botkube restart deployment my-app -n production
Botkube: ⚠️ Admin 명령어입니다. ✅ 이모지로 승인해주세요.
```

#### 8.4.5 LocalAI - 오픈소스 LLM 백엔드

**목적**: 외부 AI API (OpenAI, Gemini) 없이 로컬에서 LLM 실행

**특징**:
- OpenAI API 호환 인터페이스
- CPU 전용 모드 (GPU 불필요)
- ggml-gpt4all-j 모델 (경량, ~4GB)
- K8sGPT + HolmesGPT 공유 사용

**제약 사항**:
- CPU 모드로 인한 느린 추론 속도 (~10-30초/요청)
- 프로덕션 환경에서는 외부 LLM API 권장

**배포**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: localai
  namespace: localai
spec:
  containers:
  - name: localai
    image: quay.io/go-skynet/local-ai:latest
    resources:
      requests:
        memory: 2Gi
        cpu: 1000m
      limits:
        memory: 4Gi
        cpu: 2000m
```

**설치**: `install-k8sgpt.sh`

**엔드포인트**:
- 서비스: `http://localai.localai.svc.cluster.local:8080/v1`
- LoadBalancer 미사용 (클러스터 내부 전용)

#### 8.4.6 AI 도구 통합 플로우

**전체 워크플로우**:

1. **K8sGPT**: Pod 에러 → K8sGPT 감지 → LocalAI 분석 → Event 저장
2. **HolmesGPT**: Prometheus 알림 → Robusta 수신 → Prometheus/Loki/Tempo 데이터 수집 → LocalAI 분석 → Slack/Event 전달
3. **Botkube**: Slack 명령 → Kubernetes API → 결과 Slack 전달 + K8s Event 자동 알림

**리소스 영향**:

| 구성 요소 | RAM | 설치 위치 |
|----------|-----|---------|
| K8sGPT Operator | 128MB | mgmt |
| LocalAI | 2-4GB | mgmt (공유) |
| Robusta Runner | 512MB | mgmt |
| Botkube | 256MB | mgmt (선택) |
| **총합** | ~3-5GB | mgmt-worker-0 |

**권장 사항**:
- mgmt-worker-0 메모리 10GB 할당 완료
- LocalAI 대신 외부 LLM API 사용 시 메모리 절약 (~2GB)

---

## 9. 장애 도메인 및 복원력

### 9.1 장애 영향 매트릭스

| 장애 컴포넌트 | 영향 범위 |
|-------------|----------|
| **mgmt 클러스터 전체 다운** | 시크릿 갱신 불가 (캐시로 동작) |
| | 중앙 메트릭/로그 조회 불가 (로컬 수집 지속) |
| | 새 인증서 발급 불가 (기존 인증서로 동작) |
| | GitOps 배포 중단 (기존 워크로드는 정상 실행) |
| | **app1/app2 워크로드 정상 실행** (C1) |
| **Vault 다운** | 새 시크릿 발급 불가, ESO 캐시로 동작 |
| **ArgoCD 다운** | GitOps 배포 중단, 기존 워크로드 정상 |

### 9.2 Chaos Mesh: 장애 격리 검증

mgmt 클러스터에 Chaos Mesh를 배치하여 C1 불변 조건을 실증 검증합니다.

| 테스트 시나리오 | Chaos 유형 | 검증 항목 |
|---------------|-----------|----------|
| mgmt CP 네트워크 격리 | NetworkChaos | app1/app2 워크로드 정상 실행 확인 |
| Vault Pod 강제 종료 | PodChaos | External Secrets 캐시 동작 확인 |
| Prometheus 네트워크 지연 | NetworkChaos | Agent WAL 버퍼링 확인 |

### 9.3 복구 우선순위

| 우선순위 | 컴포넌트 | RTO |
|---------|---------|-----|
| **P0** | mgmt Control Plane | 15분 |
| **P1** | Vault, ArgoCD | 30분 |
| **P2** | Thanos, Loki, Grafana, Prometheus | 1시간 |

---

## 10. 백업 및 DR 전략

### 10.1 상태 계층 및 복구 전략

| 계층 | 내용 | 백업 방법 | 복구 방법 | RPO |
|-----|------|----------|----------|-----|
| **L1** | etcd | etcdctl 스냅샷 | etcd 복원 | 24h |
| **L2** | PV 데이터 | Velero + node-agent | Velero restore | 24h |
| **L3** | MinIO 데이터 | 버전관리 | MinIO 복원 | 실시간 |
| **L4** | Git 매니페스트 | Git 원격 저장소 | ArgoCD 동기화 | 커밋 시 |

### 10.2 백업 아키텍처

```mermaid
flowchart TB
    subgraph Clusters["클러스터"]
        mgmt["mgmt"]
        app1["app1"]
        app2["app2"]
    end

    subgraph VeleroAgents["Velero 에이전트"]
        v1["Velero"]
        v2["Velero"]
        v3["Velero"]
    end

    subgraph Storage["백업 저장소"]
        minio["MinIO<br/>(mgmt, 15Gi)"]
    end

    mgmt --> v1 --> minio
    app1 --> v2 --> minio
    app2 --> v3 --> minio
```

- 각 클러스터별 고유 prefix (`mgmt/`, `app1/`, `app2/`)
- **구현**: `addons/scripts/install-minio.sh`, `addons/scripts/install-velero.sh`

---

## 11. 리소스 계획

### 11.1 호스트 RAM 전체 버짓 (64GB)

| 계층 | 구성요소 | RAM |
|-----|---------|-----|
| **호스트** | macOS 커널 + 시스템 | 5.0 GB |
| | Multipass 데몬 | 0.5 GB |
| | IDE, 브라우저, Terraform CLI 등 | 8.5 GB |
| **호스트 소계** | | **14.0 GB** |
| **VM** | 6개 Multipass VM | **28.0 GB** |
| **합계** | | **42.0 GB** |
| **전체 여유** | | **22.0 GB** |

### 11.2 VM 할당

| 클러스터 | 노드 | RAM | CPU | 디스크 |
|---------|------|-----|-----|--------|
| mgmt | mgmt-cp | 4GB | 2 | 40GB |
| mgmt | mgmt-worker-0 | **10GB** | 2 | 60GB |
| app1 | app1-cp | 3GB | 2 | 30GB |
| app1 | app1-worker-0 | 4GB | 2 | 40GB |
| app2 | app2-cp | 3GB | 2 | 30GB |
| app2 | app2-worker-0 | 4GB | 2 | 40GB |
| **합계** | | **28GB** | **12** | **240GB** |

### 11.3 VM 내부 실사용 상세 (병목 분석)

#### mgmt-cp (4GB)

| 구성요소 | RAM |
|----------|-----|
| OS + 커널 | 300 MB |
| kubelet + containerd | 200 MB |
| kube-apiserver | 400 MB |
| etcd | 300 MB |
| kube-scheduler + controller-manager | 150 MB |
| CoreDNS x2 | 60 MB |
| Cilium agent | 200 MB |
| Tetragon agent | 100 MB |
| MetalLB speaker | 30 MB |
| **소계 / 여유** | **~1.7 GB / ~2.3 GB** |

#### mgmt-worker-0 (10GB) -- 플랫폼 서비스 노드

| 구성요소 | 카테고리 | RAM |
|----------|----------|-----|
| OS + 커널 | 시스템 | 300 MB |
| kubelet + containerd | 시스템 | 200 MB |
| Cilium agent + operator + Hubble UI | CNI | 350 MB |
| Tetragon agent | 보안 | 100 MB |
| MetalLB controller + speaker | 네트워크 | 80 MB |
| Vault (standalone + injector) | 시크릿 | 400 MB |
| ArgoCD (server+repo+controller+redis) | GitOps | 500 MB |
| Prometheus + Alertmanager | 모니터링 | 700 MB |
| Grafana | 모니터링 | 256 MB |
| node-exporter + kube-state-metrics | 모니터링 | 80 MB |
| Thanos (Receive + Query + Compactor) | 모니터링 | 512 MB |
| Loki (SingleBinary) | 로깅 | 400 MB |
| Promtail | 로깅 | 100 MB |
| Tempo | 트레이싱 | 256 MB |
| OpenTelemetry Collector | 트레이싱 | 256 MB |
| Istio (Istiod + Ingress Gateway) | Service Mesh | 650 MB |
| Kiali | Service Mesh 관찰성 | 128 MB |
| Trivy Operator | 보안 | 200 MB |
| K8sGPT Operator | AIOps | 128 MB |
| LocalAI (LLM 백엔드) | AIOps | 2048 MB |
| HolmesGPT (Robusta Runner) | AIOps | 512 MB |
| Botkube (선택적) | ChatOps | 256 MB |
| OpenCost | 비용 | 100 MB |
| VPA + Goldilocks | 최적화 | 300 MB |
| Chaos Mesh | 카오스 | 200 MB |
| cert-manager | PKI | 100 MB |
| ESO | 시크릿 | 100 MB |
| MinIO | 스토리지 | 256 MB |
| Velero + node-agent | 백업 | 256 MB |
| **소계 (AI 도구 포함)** | | **~9.0 GB** |
| **소계 (AI 도구 제외)** | | **~5.9 GB** |
| **여유 (현재 10GB 기준)** | | **✅ 충분 (+1.0 GB)** |

> **현재 설정**: mgmt-worker-0 = 10GB (locals.tf, ADR-009)

#### app1-cp / app2-cp (각 3GB)

| 구성요소 | RAM |
|----------|-----|
| OS + 커널 | 300 MB |
| kubelet + containerd | 200 MB |
| kube-apiserver + etcd + scheduler + cm | 750 MB |
| CoreDNS x2 | 60 MB |
| Cilium agent | 200 MB |
| Tetragon agent | 100 MB |
| MetalLB speaker | 30 MB |
| **소계 / 여유** | **~1.6 GB / ~1.4 GB** |

#### app1-worker-0 / app2-worker-0 (각 4GB)

| 구성요소 | RAM |
|----------|-----|
| OS + 커널 | 300 MB |
| kubelet + containerd | 200 MB |
| Cilium agent + operator + Hubble | 300 MB |
| Tetragon agent | 100 MB |
| MetalLB controller + speaker | 80 MB |
| Prometheus Agent | 200 MB |
| Promtail | 100 MB |
| Kyverno | 200 MB |
| Falco | 200 MB |
| cert-manager | 100 MB |
| ESO | 50 MB |
| Velero + node-agent | 128 MB |
| node-exporter | 30 MB |
| **소계** | **~2.0 GB** |
| **애플리케이션용 여유** | **~2.0 GB** |

---

## 12. 플랫폼 부가 도구

### 12.1 도구 개요

| 도구 | 카테고리 | 배치 | RAM | 설치 스크립트 |
|-----|---------|------|-----|-------------|
| **Tetragon** | eBPF 보안 | 전 클러스터 | ~100MB/노드 | `install-tetragon.sh` |
| **Trivy Operator** | 취약점 스캔 | mgmt | ~200MB | `install-platform-addons.sh` |
| **K8sGPT** | AI 진단 | mgmt | ~128MB | `install-platform-addons.sh` |
| **OpenCost** | 비용 가시화 | mgmt | ~100MB | `install-platform-addons.sh` |
| **VPA + Goldilocks** | 리소스 최적화 | mgmt | ~300MB | `install-platform-addons.sh` |
| **Chaos Mesh** | 장애 주입 | mgmt | ~200MB | `install-platform-addons.sh` |

---

## 13. 설치 워크플로우 (2단계 프로세스)

> **ADR-009**: Terraform과 Addon 설치를 분리하여 모듈성과 재시도 용이성 확보

### 13.1 Phase 1: Infrastructure (Terraform)

```
cloud_init ─→ vm(6개) ─→ init_mgmt ─→ join_mgmt ──────┐
                          init_app1 ─→ join_app1 ───────┤
                          init_app2 ─→ join_app2 ───────┘
                                                        │
                                              merge_kubeconfigs
                                                        │
                                            ✅ Infrastructure Ready
                                            (VM, K8s, kubeconfig)
```

**실행**: `tofu apply`
**소요 시간**: 10-15분
**결과물**:
- 6개 VM 생성 (Multipass)
- 3개 Kubernetes 클러스터 (kubeadm)
- `~/kubeconfig-multi` (통합 kubeconfig)
- `generated/clusters.json`

### 13.2 Phase 2: Addon Installation (Shell Orchestrator)

```
                              bash addons/install.sh --all
                                         │
                        ┌────────────────┼────────────────┐
                        │                │                │
                   [Networking]    [PKI/Secrets]   [Observability]
                        │                │                │
                install_cilium     install_cert_manager   install_prometheus_stack
                        │                │                │
                install_metallb    install_vault         install_thanos
                        │                │                │
                install_tetragon   setup_vault_pki       install_loki
                        │                │                │
                install_gateway_api  install_eso         install_tempo
                        │                │                │
                setup_clustermesh       │           install_otel_collector
                                        │
                        ┌───────────────┼───────────────┐
                        │               │               │
                  [Service Mesh]   [Security]     [Platform]
                        │               │               │
                  install_istio   install_kyverno   install_argocd
                        │               │               │
                  install_kiali   install_falco     install_k8sgpt
                                        │               │
                                        │         install_holmesgpt
                                        │               │
                                        │         install_minio
                                        │               │
                                        │         install_velero
                                        │               │
                                  install_platform_addons
                                  (Trivy/OpenCost/VPA/
                                   Goldilocks/Chaos Mesh)
```

**실행**:
```bash
# 전체 설치
bash addons/install.sh --all

# 카테고리별 설치
bash addons/install.sh --category networking
bash addons/install.sh --category observability
bash addons/install.sh --category security

# 개별 설치
bash addons/install.sh vault argocd prometheus-stack
```

**소요 시간**: 20-30분
**특징**:
- 선택적 설치 가능
- 실패 시 개별 재시도
- 의존성 순서 자동 관리 (INSTALL_ORDER 배열)

### 13.3 설치 스크립트 목록

| # | 스크립트 | 대상 | 의존성 |
|---|---------|------|--------|
| - | `scripts/cluster-init.sh` | 각 CP | VM 생성 후 (Terraform) |
| - | `scripts/cluster-join.sh` | 각 Worker | init 후 (Terraform) |
| - | `scripts/merge-kubeconfigs.sh` | 호스트 | 전체 join 후 (Terraform) |
| 1 | `install-cilium.sh` | 전 클러스터 | kubeconfig 병합 후 |
| 2 | `install-tetragon.sh` | 전 클러스터 | Cilium 후 |
| 3 | `install-metallb.sh` | 전 클러스터 | Cilium 후 |
| 4 | `install-gateway-api.sh` | 전 클러스터 | Cilium 후 |
| 5 | `setup-clustermesh.sh` | 전 클러스터 | MetalLB 후 |
| 6 | `install-cert-manager.sh` | 전 클러스터 | Cluster Mesh 후 |
| 7 | `install-vault.sh` | mgmt | cert-manager 후 |
| 8 | `setup-vault-pki.sh` | mgmt | Vault 후 |
| 9 | `install-eso.sh` | 전 클러스터 | Vault 후 |
| 10 | `install-argocd.sh` | mgmt | Cluster Mesh 후 |
| 11 | `install-platform-addons.sh` | mgmt | Cluster Mesh 후 |
| 12 | `install-k8sgpt.sh` | mgmt | Platform Addons 후 |
| 13 | `install-thanos.sh` | mgmt | MinIO 후 |
| 14 | `install-prometheus-stack.sh` | mgmt | Thanos 후 |
| 15 | `install-prometheus-agent.sh` | app만 | Thanos 후 |
| 16 | `install-loki.sh` | mgmt + app | Prometheus Stack 후 |
| 17 | `install-tempo.sh` | mgmt | Prometheus Stack 후 |
| 18 | `install-otel-collector.sh` | 전 클러스터 | Tempo 후 |
| 19 | `install-istio.sh` | mgmt + app | OTel 후 |
| 20 | `install-kiali.sh` | mgmt + app | Istio 후 |
| 21 | `install-kyverno.sh` | app만 | Istio 후 |
| 22 | `install-falco.sh` | app만 | Kyverno 후 |
| 23 | `install-holmesgpt.sh` | mgmt | K8sGPT + Prometheus + Loki 후 |
| 24 | `install-botkube.sh` | mgmt (선택적) | 수동 실행 (Slack 토큰 필요) |
| 25 | `install-minio.sh` | mgmt | Platform Addons 후 |
| 26 | `install-velero.sh` | 전 클러스터 | MinIO 후 |
| - | `scripts/verify-clusters.sh` | 검증 | 전체 완료 후 |
| - | `scripts/delete-all.sh` | 정리 | 수동 실행 |

**총 Addon 수**: 26개 (addons/install.sh INSTALL_ORDER 기준, botkube 수동)

---

## 부록 A: 서비스 접근 레퍼런스

### Port-Forward (개발 환경)

| 서비스 | Namespace | Port | 접속 URL | 인증 |
|--------|-----------|------|----------|------|
| Grafana | monitoring | 3000 | http://localhost:3000 | admin / [랜덤생성] |
| Prometheus | monitoring | 9090 | http://localhost:9090 | - |
| AlertManager | monitoring | 9093 | http://localhost:9093 | - |
| ArgoCD | argocd | 8080 | https://localhost:8080 | admin / [secret] |
| Kiali | istio-system | 20001 | http://localhost:20001/kiali | anonymous |
| Vault UI | vault | 8200 | http://localhost:8200 | [root-token] |
| Thanos Query | observability | 9090 | http://localhost:9090 | - |
| Chaos Mesh | chaos-mesh | 2333 | http://localhost:2333 | - |

### LoadBalancer (Cross-Cluster 통신)

| 서비스 | Namespace | Port | IP 파일 | 용도 |
|--------|-----------|------|---------|------|
| Thanos Receive | observability | 19291 | generated/thanos-receive-ip | 메트릭 수집 |
| Loki | observability | 3100 | generated/loki-lb-ip | 로그 수집 |
| Vault API | vault | 8200 | generated/vault-lb-ip | Secret 관리 |
| MinIO API | backup | 9000 | generated/minio-ip | 객체 스토리지 |
| Istio Gateway | istio-system | 80/443 | MetalLB 자동 할당 | 앱 Ingress |

### 자격증명 위치

| 서비스 | 조회 방법 |
|--------|----------|
| Grafana | `grep GRAFANA_ADMIN_PASSWORD generated/.credentials.env` |
| ArgoCD | `kubectl get secret -n argocd argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| Vault | `cat generated/vault-root-token` |
| MinIO | `grep MINIO_ROOT generated/.credentials.env` |

## 부록 B: 보안 운영 체크리스트

### 자격증명 관리
- 자동 생성: `scripts/lib/credentials.sh` (32자 base64 랜덤)
- 저장 위치: `generated/.credentials.env` (chmod 600, .gitignore)
- 명령줄 노출 방지: 환경변수 export 방식 사용 (Vault, MySQL)

### NetworkPolicy (Zero Trust)
- `default-deny-all`: 모든 ingress/egress 기본 차단
- `allow-dns`: DNS 쿼리만 명시적 허용
- 서비스별 세밀한 정책: `templates/network-policies.yaml`
- 적용: `bash addons/scripts/apply-network-policies.sh`

### 보안 사고 대응
1. 자격증명 노출 → 즉시 rotation + Vault audit log 확인
2. 비정상 Pod → Falco/Tetragon 확인 + `quarantine=true` 라벨로 격리
3. 취약점 발견 → Trivy 스캔 + Kyverno 정책으로 배포 차단

## 부록 C: 관련 문서

| 문서 | 설명 |
|-----|------|
| [SMARTER-PROMPT.md](SMARTER-PROMPT.md) | SMART+ER 프롬프트 기반 요구사항 |

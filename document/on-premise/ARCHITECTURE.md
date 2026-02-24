# Kubernetes 멀티클러스터 아키텍처

> **버전**: 6.0.0
> **Kubernetes**: v1.35
> **최종 수정일**: 2026-02-24
> **이전 버전 백업**: `ARCHITECTURE.md.bak`

---

## 목차

1. [개요](#1-개요)
2. [아키텍처 결정 기록 (ADR)](#2-아키텍처-결정-기록-adr)
3. [아키텍처 불변 조건](#3-아키텍처-불변-조건-architecture-contract)
4. [클러스터 토폴로지](#4-클러스터-토폴로지)
5. [네트워크 아키텍처](#5-네트워크-아키텍처)
6. [스토리지 아키텍처](#6-스토리지-아키텍처)
7. [보안 아키텍처](#7-보안-아키텍처)
8. [관찰성 아키텍처](#8-관찰성-아키텍처)
9. [백업 및 DR](#9-백업-및-dr)
10. [리소스 계획](#10-리소스-계획)
11. [설치 워크플로우](#11-설치-워크플로우)
12. [서비스 접근 레퍼런스](#12-서비스-접근-레퍼런스)

---

## 1. 개요

### 1.1 프로젝트 목적

macOS(Apple Silicon) 환경에서 **OpenTofu + Shell Script**로 프로덕션급 Kubernetes 멀티클러스터 환경을 구축합니다.

### 1.2 대상 환경 및 SLO

| 항목 | 값 |
|-----|-----|
| **환경 유형** | 개발 / 학습 / 시연 (로컬) |
| **가용성 목표** | 99% (월 ~7시간 다운타임 허용) |
| **RTO** | 1시간 (클러스터 재생성 기준) |
| **RPO** | 24시간 (일일 백업 기준) |

### 1.3 기술 스택

| 영역 | 기술 |
|-----|------|
| **인프라** | Multipass VM, OpenTofu 1.11, cloud-init |
| **쿠버네티스** | kubeadm v1.35, containerd |
| **네트워크** | Cilium 1.19.0 (VXLAN) + Cluster Mesh + Gateway API v1.2.1 + MetalLB v0.15.3 |
| **Service Mesh** | Istio 1.29.0 + Cilium CNI 통합 |
| **GitOps** | ArgoCD (mgmt 클러스터, chart 7.7.11) |
| **시크릿/PKI** | Vault + External Secrets Operator + cert-manager v1.19.3 |
| **관찰성** | Prometheus + Thanos + Loki + Grafana Alloy 1.5.0 + Tempo 2.6.1 + OpenSearch 2.18.0 + Grafana + Hubble + Kiali 1.91.0 |
| **보안** | PSA + Kyverno 3.3.4 + Falco 4.16.0 + Tetragon 1.3.0 + Trivy |
| **AIOps** | K8sGPT + HolmesGPT (Robusta 0.13.0) + OpenCost + VPA + Chaos Mesh |
| **백업** | Velero 8.2.0 + MinIO |
| **ChatOps** | Botkube 1.15.0 (Slack, 선택적) |

### 1.4 제약 조건

- Ansible 미사용 (Shell Script 대체)
- Helmfile 미사용 (Helm CLI 직접 사용)
- Static IP 미사용 (Multipass DHCP 동적 할당)
- Vault: Standalone 모드 (PoC 목적, HA 미적용)

---

## 2. 아키텍처 결정 기록 (ADR)

| ADR | 상태 | 결정 요약 |
|-----|------|----------|
| **ADR-001** | Accepted | mgmt 클러스터에 플랫폼 서비스 집중 (Vault, 관찰성, 백업) |
| **ADR-002** | Accepted | K8s 1.35 GA 기능 활용 (InPlacePodVerticalScaling, VPA InPlaceOrRecreate) |
| **ADR-003** | Accepted | PSA(baseline) + Kyverno 2-Layer 보안 모델. Kyverno는 app 클러스터에만 배치 |
| **ADR-004** | Accepted | 2-Phase PKI: Self-signed → Vault Issuer 순서 부트스트랩 (닭-달걀 문제 해결) |
| **ADR-005** | Accepted | Cilium Tunneling(VXLAN) 모드 (Multipass 브리지 네트워크에서 Native Routing 복잡도 회피) |
| **ADR-006** | Accepted | 관찰성 에이전트 분산: app 클러스터는 Alloy(WAL 버퍼), mgmt는 Full Stack |
| **ADR-007** | Accepted | Cilium CNI + Istio Service Mesh 병행 (Cilium: L3/L4, Istio: L7/mTLS/AuthZ) |
| **ADR-008** | Accepted | Terraform → OpenTofu 1.11 마이그레이션 (BSL 라이선스 회피, MPL 2.0) |
| **ADR-009** | Accepted | 2단계 워크플로우 분리: Phase 1(tofu apply) vs Phase 2(addons/install.sh) |
| **ADR-010** | Accepted | Namespace 통합: **monitoring**(수집/시각화) vs **observability**(장기보관/분석) |
| **ADR-011** | Accepted | Istio Ingress Gateway를 통한 `*.bocopile.io` 단일 도메인 접근 |
| **ADR-012** | Accepted | 보안 강화: 자격증명 자동 생성(32자 base64), credentials.sh 라이브러리, chmod 600 |
| **ADR-013** | Completed | DRY 리팩토링: common.sh 18개 함수, constants.sh 50+ 상수, 전체 스크립트 표준화 |

### ADR-003 상세: Kyverno 배치 범위

| 클러스터 | Kyverno | 이유 |
|---------|---------|------|
| **mgmt** | 미설치 | 플랫폼/운영자 영역, PSA baseline만 (유연성 확보) |
| **app1/app2** | Enforce 모드 | 개발팀 워크로드 영역 |

### ADR-013 상세: 공통 라이브러리 현황

**`scripts/lib/common.sh`** — 18개 함수:

| 함수 | 용도 |
|------|------|
| `setup_common_vars()` | 경로 변수 초기화, kubeconfig/clusters.json 존재 확인 |
| `get_kubectl_cmd(cluster)` | kubectl 명령어 생성 (context 자동 설정) |
| `get_helm_cmd(cluster)` | helm 명령어 생성 (kube-context 자동 설정) |
| `ensure_namespace(ns, cluster)` | namespace 자동 생성 |
| `ensure_namespace_privileged(ns, cluster)` | PSA privileged 라벨 설정 |
| `add_helm_repo(name, url)` | Helm repo 추가 + update |
| `wait_for_deployment(ns, name, timeout, ctx)` | Deployment 준비 대기 |
| `wait_for_statefulset(ns, name, timeout, ctx)` | StatefulSet readyReplicas=1 대기 |
| `wait_for_lb_ip(ns, svc, timeout, ctx)` | LoadBalancer IP 할당 대기 |
| `wait_for_node_ready(node)` | cloud-init 완료 + K8s 컴포넌트 확인 |
| `validate_prerequisites()` | kubectl/helm/jq 존재 확인 (⚠️ 현재 미호출) |
| `error_exit(msg)` | 에러 출력 후 exit 1 |
| `log_info(msg)` / `log_warn(msg)` | 로그 출력 |
| `require_command(cmd)` / `require_file(path)` | 의존성 확인 |
| `kubectl_ctx(cluster)` / `helm_ctx(cluster)` | ⚠️ 레거시 (get_kubectl_cmd로 대체, 미사용 상태) |

**`scripts/lib/constants.sh`** — 주요 상수:

| 그룹 | 상수 |
|-----|------|
| Namespace | `NAMESPACE_MONITORING`, `NAMESPACE_OBSERVABILITY`, `NAMESPACE_SECURITY`, `NAMESPACE_BACKUP`, `NAMESPACE_VAULT`, `NAMESPACE_ARGOCD`, `NAMESPACE_ISTIO` |
| Timeout | `TIMEOUT_DEPLOYMENT=180s`, `TIMEOUT_STATEFULSET=180s`, `TIMEOUT_LB_IP=120s`, `TIMEOUT_POD_READY=120s` |
| Domain | `BASE_DOMAIN=bocopile.io`, `DOMAIN_GRAFANA`, `DOMAIN_ARGOCD`, `DOMAIN_VAULT` 등 10개 |
| Resources | `RESOURCES_SMALL/MEDIUM/LARGE` × `REQUESTS/LIMITS` × `CPU/MEMORY` |
| Storage | `STORAGE_CLASS_DEFAULT=local-path`, `STORAGE_CLASS_RETAIN=local-path-retain` |
| Helm Repos | `HELM_REPO_HASHICORP`, `HELM_REPO_GRAFANA`, `HELM_REPO_KYVERNO` 등 18개 |

---

## 3. 아키텍처 불변 조건 (Architecture Contract)

> 구현이 변경되더라도 반드시 유지해야 하는 아키텍처 보장 사항

| # | 불변 조건 | 근거 ADR |
|---|----------|----------|
| **C1** | mgmt 클러스터 장애 시에도 app 클러스터 워크로드는 독립 실행 지속 | ADR-001 |
| **C2** | app 클러스터 Grafana Alloy는 WAL 로컬 버퍼링 유지 | ADR-006 |
| **C3** | External Secrets는 refreshInterval 1h 캐시로 Vault 장애 시에도 동작 | ADR-001 |
| **C4** | Kyverno는 app 클러스터에만 Enforce 모드 배치 (mgmt 제외) | ADR-003 |
| **C5** | PKI 부트스트랩은 2-Phase 순서 준수 (Self-signed → Vault Issuer) | ADR-004 |
| **C6** | Cilium은 Tunneling(VXLAN) 모드로 동작 | ADR-005 |
| **C7** | Istio Gateway 인증서는 cert-manager + Vault PKI로 자동 발급/갱신 | ADR-007 |
| **C8** | IaC는 OpenTofu 사용, Terraform 문법 호환성 유지 | ADR-008 |
| **C9** | 인프라(tofu apply)와 Addon 설치(addons/install.sh)는 2단계 분리 | ADR-009 |
| **C10** | 관찰성 스택은 monitoring(수집) vs observability(보관) Namespace로 분리 | ADR-010 |
| **C11** | 모든 WebUI 서비스는 *.bocopile.io 도메인으로 접근 가능 | ADR-011 |
| **C12** | 자격증명은 자동 생성(32자 base64) 및 안전 저장(chmod 600) | ADR-012 |
| **C13** | 모든 스크립트는 common.sh + constants.sh 공통 라이브러리를 사용 | ADR-013 |

---

## 4. 클러스터 토폴로지

### 4.1 클러스터 역할

| 클러스터 | 역할 | 주요 컴포넌트 |
|---------|------|-------------|
| **mgmt** | 플랫폼 서비스 | Vault, Prometheus Full, Thanos, Loki, Grafana, Tempo, OpenSearch, Alertmanager, ArgoCD, Velero, MinIO, Trivy, K8sGPT, HolmesGPT, LocalAI, Botkube(선택), OpenCost, VPA+Goldilocks, Chaos Mesh, Istio (Istiod+Gateway), Kiali |
| **app1** | 워크로드 A | 애플리케이션, Grafana Alloy, Kyverno, Falco, Istio Sidecar |
| **app2** | 워크로드 B | 애플리케이션, Grafana Alloy, Kyverno, Falco |
| **공통** | 전 클러스터 | Cilium, Tetragon DaemonSet, MetalLB, cert-manager, ESO, Velero |

### 4.2 노드 스펙 (`locals.tf` 기준)

| 클러스터 | 노드 | RAM | CPU | 디스크 |
|---------|------|-----|-----|--------|
| mgmt | mgmt-cp | 4GB | 2 | 40GB |
| mgmt | mgmt-worker-0 | **10GB** | 2 | 60GB |
| app1 | app1-cp | 3GB | 2 | 30GB |
| app1 | app1-worker-0 | 4GB | 2 | 40GB |
| app2 | app2-cp | 3GB | 2 | 30GB |
| app2 | app2-worker-0 | 4GB | 2 | 40GB |
| **합계** | | **28GB** | **12** | **240GB** |

### 4.3 CIDR 할당 (`locals.tf` 기준)

| 클러스터 | Pod CIDR | Service CIDR | MetalLB 풀 |
|---------|----------|--------------|-----------|
| **mgmt** | 10.100.0.0/16 | 10.96.0.0/16 | 192.168.64.200–210 |
| **app1** | 10.101.0.0/16 | 10.97.0.0/16 | 192.168.64.211–220 |
| **app2** | 10.102.0.0/16 | 10.98.0.0/16 | 192.168.64.221–230 |

> 노드 IP: Multipass DHCP 동적 할당 (192.168.64.x 대역)

---

## 5. 네트워크 아키텍처

### 5.1 Cilium CNI

| 설정 | 값 | 근거 |
|-----|----|----|
| `routingMode` | `tunnel` (VXLAN) | ADR-005, Multipass 환경 호환 |
| `kubeProxyReplacement` | `true` | eBPF 기반 서비스 라우팅 |
| Cluster Mesh | 활성화 | 3개 클러스터 상호 서비스 디스커버리 |
| Hubble | UI + Relay 활성화 | 네트워크 관찰성 |
| **구현** | `install-cilium.sh`, `setup-clustermesh.sh` | |

### 5.2 MetalLB (L2 모드)

- L2/ARP 기반 (Multipass 브리지에서 BGP 불가)
- **구현**: `addons/scripts/install-metallb.sh`

### 5.3 Gateway API

- CRD v1.2.1 설치 후 Cilium Gateway + Istio Gateway 공용
- **구현**: `addons/scripts/install-gateway-api.sh`

### 5.4 Istio Service Mesh

| 클러스터 | 배포 범위 |
|---------|----------|
| **mgmt** | Istiod + Ingress Gateway |
| **app1** | Istiod + Ingress Gateway + Sidecar Injection (mTLS STRICT) |
| **app2** | 미배포 (선택적) |

**Cilium + Istio 역할 분담**:

| 계층 | Cilium | Istio |
|-----|--------|-------|
| L3/L4 네트워킹 | ✅ | - |
| kube-proxy 대체 | ✅ | - |
| Cluster Mesh | ✅ | - |
| L7 트래픽 제어 (Retry/Timeout/Canary) | - | ✅ |
| mTLS (Mesh 내부) | - | ✅ |
| AuthorizationPolicy | - | ✅ |
| Gateway (North-South) | Gateway API CRD | ✅ Istio Gateway |
| 관찰성 | Hubble | Kiali |

**구현**: `addons/scripts/install-istio.sh`, `addons/scripts/install-kiali.sh`

---

## 6. 스토리지 아키텍처

| StorageClass | ReclaimPolicy | 용도 |
|-------------|---------------|------|
| **local-path** (기본) | Delete | 일반 워크로드, MinIO |
| **local-path-retain** | Retain | Vault, Prometheus, Loki, Grafana |

| 워크로드 | StorageClass | 크기 |
|---------|-------------|------|
| Prometheus | local-path-retain | 10Gi |
| Loki | local-path-retain | 10Gi |
| Grafana | local-path-retain | 5Gi |
| Vault | local-path-retain | 10Gi |
| MinIO | local-path | 15Gi |

> `local-path-retain`은 `addons/scripts/install-platform-addons.sh`에서 자동 생성

---

## 7. 보안 아키텍처

### 7.1 보안 계층

| 계층 | 구현 | 범위 |
|-----|------|------|
| **L1 클러스터 접근** | RBAC, ServiceAccount, kubeconfig | 전 클러스터 |
| **L2 워크로드 (PSA)** | baseline enforce (cloud-init PSA admission config) | 전 클러스터 |
| **L2 워크로드 (Kyverno)** | 4개 정책 Enforce | app 클러스터만 |
| **L3 네트워크** | Cilium NetworkPolicy (Zero Trust, 기본 deny-all) | 플랫폼 Namespace |
| **L4 시크릿** | Vault Standalone + ESO (refreshInterval 1h) | 전 클러스터 |
| **L5 런타임** | Falco (app), Tetragon DaemonSet (전체) | 전 클러스터 |
| **L6 취약점** | Trivy Operator | mgmt |

### 7.2 PSA Privileged 예외 Namespace

`kube-system`, `cilium-system`, `monitoring`, `vault`

### 7.3 Kyverno 정책 (`addons/scripts/install-kyverno.sh`)

| 정책 | 모드 | 내용 |
|-----|------|------|
| `restrict-image-registries` | Enforce | `localhost:8443/*`, `registry.k8s.io/*`, `docker.io/library/*`, `quay.io/*` 허용 |
| `require-resource-limits` | Enforce | requests/limits 필수 |
| `disallow-privileged-containers` | Enforce | `privileged: false` 강제 |
| `require-labels` | Audit | app, version 라벨 필수 |

**제외 Namespace**: kube-system, cilium-system, kyverno, monitoring, observability, security, backup, cert-manager, external-secrets

### 7.4 NetworkPolicy (`templates/network-policies.yaml`)

- 모델: 기본 deny-all + 명시적 allow
- 적용 범위: monitoring, observability, security, backup, vault, argocd
- 정책 수: 11개 (default-deny-all + DNS allow + K8s API allow + 서비스별 8개)
- **적용**: `bash addons/scripts/apply-network-policies.sh`

### 7.5 자격증명 관리 (`scripts/lib/credentials.sh`)

| 항목 | 내용 |
|-----|------|
| **저장 위치** | `generated/.credentials.env` (chmod 600, .gitignore 제외) |
| **생성 방식** | `openssl rand -base64 32` |
| **MinIO** | MINIO_ROOT_USER / MINIO_ROOT_PASSWORD (자동 생성) |
| **Vault Root Token** | Vault init 시 자동 생성, `generated/vault-root-token` (chmod 600) |
| **Vault Unseal Key** | `generated/vault-init.json` (chmod 600) |

### 7.6 Vault PKI (`addons/scripts/setup-vault-pki.sh`)

- PKI Secrets Engine 활성화 (`pki/`)
- Root CA 생성 (max-lease-ttl 8760h)
- Role `istio-gateway`: `allowed_domains = "*.local,*.example.com,*.cluster.local,localhost"`
- Kubernetes Auth 설정 (cert-manager 연동)
- ⚠️ **알려진 문제**: `bocopile.io`가 allowed_domains 누락 → Istio Gateway TLS 인증서 발급 불가 (C7 위반)

---

## 8. 관찰성 아키텍처

### 8.1 스택 구성

| 영역 | 도구 | 배치 | 구현 스크립트 |
|-----|------|------|-------------|
| **Metrics (mgmt)** | Prometheus Full + Alertmanager + Grafana | mgmt | `install-prometheus-stack.sh` |
| **Metrics (장기)** | Thanos Receive + Query + Compactor | mgmt | `install-thanos.sh` |
| **Metrics (app)** | Grafana Alloy → Thanos remote_write | app1/app2 | `install-alloy.sh` |
| **Logs (mgmt)** | Loki SingleBinary + Grafana Alloy | mgmt | `install-loki.sh`, `install-alloy.sh` |
| **Logs (app)** | Grafana Alloy → OpenSearch | app1/app2 | `install-alloy.sh` |
| **Log Search** | OpenSearch + Dashboards | mgmt | `install-opensearch.sh` |
| **Tracing** | Grafana Tempo | mgmt | `install-tempo.sh` |
| **Network** | Hubble UI + Relay | 전 클러스터 | `install-cilium.sh` |
| **Service Graph** | Kiali | mgmt + app1 | `install-kiali.sh` |

### 8.2 mgmt 장애 시 동작 (C2, C3)

| 컴포넌트 | 동작 |
|---------|------|
| Grafana Alloy | WAL 로컬 버퍼링 → 복구 후 자동 재전송 |
| External Secrets | 캐시 유지 (refreshInterval 1h) |

### 8.3 AIOps 도구

| 도구 | 용도 | RAM | 구현 |
|-----|------|-----|------|
| K8sGPT Operator | Pod 에러 자동 진단 | 128MB | `install-platform-addons.sh` + `install-k8sgpt.sh` |
| LocalAI (LLM) | K8sGPT/HolmesGPT 공유 백엔드 (CPU 모드) | 2~4GB | `install-k8sgpt.sh` |
| HolmesGPT (Robusta) | Prometheus 알림 RCA | 512MB | `install-holmesgpt.sh` |
| Botkube | Slack ChatOps | 256MB | `install-botkube.sh` (수동, Slack 토큰 필요) |
| OpenCost | 비용 가시화 | 100MB | `install-platform-addons.sh` |
| VPA + Goldilocks | 리소스 최적화 | 300MB | `install-platform-addons.sh` |
| Chaos Mesh | 장애 주입 (C1 검증) | 200MB | `install-platform-addons.sh` |
| Trivy Operator | 이미지 CVE 스캔 | 200MB | `install-platform-addons.sh` |

---

## 9. 백업 및 DR

| 계층 | 대상 | 백업 방법 | RPO |
|-----|------|----------|-----|
| L1 | etcd | etcdctl 스냅샷 | 24h |
| L2 | PV 데이터 | Velero + node-agent → MinIO | 24h |
| L3 | MinIO 데이터 | 버전관리 | 실시간 |
| L4 | Git 매니페스트 | 원격 저장소 | 커밋 시 |

- MinIO 버킷: `velero-backups`, `thanos`, `loki-logs`, `tempo-traces`
- 클러스터별 prefix: `mgmt/`, `app1/`, `app2/`
- ⚠️ **알려진 문제**: `install-velero.sh`는 Helm 설치만 수행, **Schedule 리소스 미생성** → 자동 백업 없음

수동 Schedule 생성 (설치 후 필수):
```bash
for CTX in mgmt app1 app2; do
  velero schedule create daily-${CTX} --schedule='0 2 * * *' \
    --kubeconfig ~/kubeconfig-multi --kubecontext kubernetes-admin@${CTX}
done
```

---

## 10. 리소스 계획

### 10.1 호스트 RAM 버짓 (64GB)

| 구분 | RAM |
|-----|-----|
| macOS + IDE + 기타 | ~14GB |
| VM 6개 합계 | 28GB |
| **여유** | **~22GB** |

### 10.2 VM 내부 사용량 요약

| 노드 | 할당 | 예상 사용 | 여유 |
|-----|------|----------|------|
| mgmt-cp | 4GB | ~1.7GB | +2.3GB |
| mgmt-worker-0 | 10GB | ~9.4GB (AI 포함) / ~6.3GB (AI 제외) | ✅ |
| app1-cp / app2-cp | 3GB 각 | ~1.6GB | +1.4GB |
| app1-worker-0 / app2-worker-0 | 4GB 각 | ~2.0GB | +2.0GB (앱용) |

> mgmt-worker-0 주요 컴포넌트: Vault 400MB, ArgoCD 500MB, Prometheus+Grafana 956MB, Thanos 512MB, Loki 400MB, OpenSearch 512MB, Istio 650MB, LocalAI 2GB, Robusta 512MB

---

## 11. 설치 워크플로우

### 11.1 Phase 1: Infrastructure (`tofu apply`, 10~15분)

```
cloud_init → vm(6개) → init_{mgmt,app1,app2} → join_{mgmt,app1,app2}
                                                         ↓
                                               merge_kubeconfigs
                                                         ↓
                                          generated/clusters.json
                                          generated/kubeconfig-multi
```

> **사전 조건**: `mkdir -p generated` (generated/ 디렉토리 없으면 첫 실행 실패)

### 11.2 Phase 2: Addon Installation (`bash addons/install.sh --all`, 20~30분)

| # | 스크립트 | 대상 | 의존성 |
|---|---------|------|--------|
| 0 | `install-priority-classes.sh` | 전 클러스터 | kubeconfig 후 |
| 1 | `install-cilium.sh` | 전 클러스터 | priority-classes 후 |
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
| 13 | `install-minio.sh` | mgmt | Platform Addons 후 |
| 14 | `install-thanos.sh` | mgmt | MinIO 후 |
| 15 | `install-prometheus-stack.sh` | mgmt | Thanos 후 |
| 16 | `install-loki.sh` | mgmt | Prometheus Stack 후 |
| 17 | `install-tempo.sh` | mgmt | Prometheus Stack 후 |
| 18 | `install-opensearch.sh` | mgmt | Prometheus Stack 후 |
| 19 | `install-alloy.sh` | 전 클러스터 | OpenSearch + Thanos 후 |
| 20 | `install-istio.sh` | mgmt + app1 | Alloy 후 |
| 21 | `install-kiali.sh` | mgmt + app1 | Istio 후 |
| 22 | `install-kyverno.sh` | app1/app2 | Istio 후 |
| 23 | `install-falco.sh` | app1/app2 | Kyverno 후 |
| 24 | `install-holmesgpt.sh` | mgmt | K8sGPT + Prometheus + Loki 후 |
| 25 | `install-velero.sh` | 전 클러스터 | MinIO 후 |
| 26 | `install-botkube.sh` | mgmt | **수동** (Slack 토큰 필요) |
| - | `apply-network-policies.sh` | 플랫폼 NS | 전체 완료 후 |
| - | `scripts/verify-clusters.sh` | 검증 | 전체 완료 후 |

```bash
# 카테고리별 설치
bash addons/install.sh --all
bash addons/install.sh --category networking
bash addons/install.sh --category observability
bash addons/install.sh --category security
```

---

## 12. 서비스 접근 레퍼런스

### 12.1 Port-Forward 방식

| 서비스 | Namespace | Port | URL | 인증 |
|--------|-----------|------|-----|------|
| Grafana | monitoring | 3000 | http://localhost:3000 | admin / [credentials.env] |
| Prometheus | monitoring | 9090 | http://localhost:9090 | - |
| Alertmanager | monitoring | 9093 | http://localhost:9093 | - |
| ArgoCD | argocd | 8080 | https://localhost:8080 | admin / [K8s secret] |
| Kiali | istio-system | 20001 | http://localhost:20001/kiali | anonymous |
| Vault UI | vault | 8200 | http://localhost:8200 | [vault-root-token] |
| Thanos Query | observability | 9090 | http://localhost:9090 | - |
| Chaos Mesh | chaos-mesh | 2333 | http://localhost:2333 | - |

### 12.2 LoadBalancer (Cross-Cluster 통신)

| 서비스 | Namespace | Port | IP 파일 |
|--------|-----------|------|---------|
| Thanos Receive | observability | 19291 | `generated/thanos-receive-ip` |
| Loki | observability | 3100 | `generated/loki-lb-ip` |
| Vault API | vault | 8200 | `generated/vault-lb-ip` |
| MinIO API | backup | 9000 | `generated/minio-ip` |
| Istio Gateway | istio-system | 80/443 | MetalLB 자동 할당 |

### 12.3 *.bocopile.io 도메인 접근 (ADR-011)

```bash
# Istio Gateway IP 조회 후 /etc/hosts 자동 등록
bash scripts/update-hosts-bocopile.sh

# 주요 도메인 목록
grafana.bocopile.io       argocd.bocopile.io
prometheus.bocopile.io    vault.bocopile.io
kiali.bocopile.io         minio.bocopile.io
alertmanager.bocopile.io  loki.bocopile.io
```

### 12.4 자격증명 조회

```bash
# 전체 자격증명
cat generated/.credentials.env

# Vault root token
cat generated/vault-root-token

# ArgoCD admin 비밀번호
kubectl --kubeconfig ~/kubeconfig-multi --context kubernetes-admin@mgmt \
  -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```


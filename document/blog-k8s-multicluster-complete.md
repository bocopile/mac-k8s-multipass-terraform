# K8s 멀티클러스터 온프레미스 구축 — 완료 편

> 이전 글: [k8s-pattern-on-premise-01](https://velog.io/@gjrjr4545/k8s-pattern-on-premise-01)
>
> Mac Studio M1 Max (64GB) 위에서 OpenTofu + Shell script로 Kubernetes 멀티클러스터를 구축하고,
> 플랫폼 엔지니어링에 필요한 Addon을 모두 설치한 최종 결과를 정리합니다.

---

## 1. 이전 글 대비 변경 요약

### 1-1. 인프라 축소

| 항목 | 이전 (01편) | 현재 (완료) | 변경 이유 |
|------|-----------|-----------|----------|
| 클러스터 | mgmt + app1 + app2 (3개) | mgmt + app1 (2개) | 리소스 부족 — app2의 4CPU/7GB를 mgmt에 재분배 |
| VM | 6개 (CP3 + Worker3) | 4개 (CP2 + Worker2) | app2 제거 |
| 총 RAM | ~30GB | ~23GB | 64GB 호스트에서 안정적 운영 |
| mgmt-worker-0 | 3GB / 2CPU | **12GB / 4CPU** | 플랫폼 Addon(16개)을 안정적으로 수용 |

실제로 `tofu apply`를 반복 실행할 때마다 다른 Addon이 실패하는 현상이 있었다. 원인은 mgmt-worker-0의 CPU requests가 95% 이상 포화된 상태에서 스케줄링이 불안정해진 것이었다. app2 클러스터를 제거하고 해당 리소스를 mgmt에 재분배함으로써 해결했다.

### 1-2. Addon 삭제 (6개)

학습/편의 도구로 분류되어, 핵심 플랫폼 운영에는 불필요하다고 판단했다.

| Addon | 이전 역할 | 삭제 이유 |
|-------|----------|----------|
| k8sgpt | AI 기반 K8s 진단 | CPU 200m+ 소비, 핵심 아님 |
| HolmesGPT | k8sgpt 후처리 | k8sgpt 의존 |
| Botkube | Slack 알림 연동 | 로컬 환경에서 불필요 |
| OpenCost | 비용 분석 | 온프레미스에서 의미 없음 |
| Goldilocks | VPA 추천 | 선택적 도구 |
| Chaos Mesh | 카오스 엔지니어링 | 리소스 부족 + privileged 요구 |

### 1-3. Addon 추가 (5개)

| Addon | 클러스터 | 역할 | 추가 이유 |
|-------|---------|------|----------|
| **Istio** | mgmt, app1 | L7 트래픽 관리, mTLS, Ingress Gateway | Cilium(L3/L4)과 역할 분리하여 Service Mesh 구성 |
| **Kiali** | mgmt, app1 | Service Mesh 시각화 대시보드 | Istio 트래픽 흐름/에러/지연 실시간 관찰 |
| **Tempo** | mgmt | 분산 트레이싱 백엔드 | 관찰성 3축 완성 (Metrics + Logs + **Traces**) |
| **Tetragon** | mgmt, app1 | eBPF 기반 런타임 보안 관찰 | Cilium 연동, 커널 레벨 syscall/파일/네트워크 이벤트 모니터링 |
| **Grafana Alloy** | mgmt, app1 | 통합 텔레메트리 에이전트 | Prometheus Agent + Promtail을 단일 바이너리로 대체 |

### 1-4. Addon 변경

| Addon | 이전 | 현재 | 변경 내용 |
|-------|------|------|----------|
| Prometheus Agent (app) | 별도 agent 모드 | **Grafana Alloy로 대체** | Alloy가 remote_write + 로그 수집 + 트레이스 전달을 하나로 처리 |
| Promtail (app) | 별도 로그 에이전트 | **Grafana Alloy로 대체** | 위와 동일 |
| ArgoCD | 외부 Docker 호스트 | **mgmt 클러스터 내부** | 외부 의존 제거, Helm 설치로 통합 |

---

## 2. 현재 인프라 구성

### 2-1. VM 스펙

| VM | 클러스터 | 역할 | CPU | RAM | Disk |
|----|---------|------|-----|-----|------|
| mgmt-cp | mgmt | control-plane | 2 | 4G | 40G |
| mgmt-worker-0 | mgmt | worker | 4 | 12G | 60G |
| app1-cp | app1 | control-plane | 2 | 3G | 30G |
| app1-worker-0 | app1 | worker | 2 | 4G | 40G |
| **합계** | | | **10** | **23G** | **170G** |

### 2-2. 네트워크 할당

| 클러스터 | Pod CIDR | Service CIDR | MetalLB Pool |
|---------|----------|-------------|--------------|
| mgmt | 10.100.0.0/16 | 10.96.0.0/16 | 192.168.64.200 - 210 |
| app1 | 10.101.0.0/16 | 10.97.0.0/16 | 192.168.64.211 - 220 |

### 2-3. LoadBalancer 서비스 (mgmt)

| 네임스페이스 | 서비스 | External IP | 용도 |
|------------|--------|-------------|------|
| backup | minio | 192.168.64.200 | S3 호환 스토리지 |
| vault | vault | 192.168.64.201 | 시크릿 관리 API |
| observability | thanos-receive | 192.168.64.202 | 멀티클러스터 메트릭 수신 |
| observability | loki-lb | 192.168.64.203 | 중앙 로그 수신 |
| istio-system | istio-ingressgateway | 192.168.64.204 | 도메인 기반 라우팅 |

---

## 3. 전체 Addon 구성

### 3-1. mgmt 클러스터 (16개 Addon)

| 카테고리 | Addon | 역할 |
|---------|-------|------|
| CNI | Cilium 1.19.0 | L3/L4 네트워크, kube-proxy 대체, Gateway API |
| 보안 관찰 | Tetragon | eBPF 런타임 보안 이벤트 수집 |
| LB | MetalLB | 베어메탈 LoadBalancer IP 할당 |
| 인증서 | cert-manager | TLS 인증서 자동 발급/갱신 |
| 시크릿 | Vault | 시크릿 관리 + PKI CA (standalone) |
| 시크릿 동기화 | External Secrets Operator | Vault → K8s Secret 자동 동기화 |
| GitOps | ArgoCD | 선언적 배포 파이프라인 |
| 메트릭 | kube-prometheus-stack | Prometheus + Grafana + Alertmanager |
| 메트릭 집계 | Thanos (Receive 모드) | 멀티클러스터 메트릭 중앙 집계 |
| 로그 | Loki | 중앙 로그 저장소 |
| 트레이싱 | Tempo | 분산 트레이싱 백엔드 |
| 텔레메트리 | Grafana Alloy | 통합 에이전트 (메트릭/로그/트레이스) |
| 백업 스토리지 | MinIO | S3 호환 오브젝트 스토리지 |
| 백업 | Velero | K8s 리소스 + PV 백업/복원 |
| Service Mesh | Istio (istiod + IngressGateway) | L7 트래픽 관리, mTLS PERMISSIVE |
| Mesh 시각화 | Kiali | 서비스 그래프, 트래픽 흐름 시각화 |

### 3-2. app1 클러스터 (9개 Addon)

| 카테고리 | Addon | 역할 |
|---------|-------|------|
| CNI | Cilium 1.19.0 | 네트워크 + Gateway API |
| 보안 관찰 | Tetragon | eBPF 런타임 이벤트 |
| 인증서 | cert-manager | TLS 인증서 |
| 시크릿 동기화 | External Secrets Operator | Vault → Secret 동기화 |
| 텔레메트리 | Grafana Alloy | mgmt의 Thanos/Loki로 LB IP 경유 전송, Tempo는 Cluster Mesh 필요 |
| 정책 보안 | Kyverno (4개 정책) | 이미지 레지스트리 제한, 리소스 제한 필수, privileged 금지, 라벨 필수 |
| 런타임 보안 | Falco | syscall 기반 이상 행위 탐지 |
| 백업 | Velero | 리소스 백업 (MinIO 연동) |
| Service Mesh | Istio + Kiali | mTLS STRICT, 서비스 시각화 |

---

## 4. 아키텍처 변경 포인트

### 4-1. 관찰성 3축 완성

이전에는 Metrics(Prometheus)와 Logs(Loki) 2축만 구성되어 있었다.
Tempo를 추가하여 **분산 트레이싱**까지 완성했다.

```
[app1 Pod] → Alloy → Thanos Receive (메트릭, LB IP 경유)
                    → Loki (로그, LB IP 경유)
                    → Tempo (트레이스, Cluster Mesh 필요*)
                              ↓
                         Grafana에서 통합 조회
                         메트릭 → 로그 → 트레이스 드릴다운
```

> \* app1에서 mgmt의 Tempo로 트레이스를 전달하려면 Cilium Cluster Mesh가 필요하다. 메트릭과 로그는 MetalLB LoadBalancer IP를 통해 전달되므로 Cluster Mesh 없이도 동작한다. Cluster Mesh 구성은 현재 스크립트 수준으로 준비되어 있으며(`setup-clustermesh.sh`), 안정화 및 서비스 연동을 다음 과제로 선정했다.

Grafana에서 메트릭 알림을 확인하고, 해당 시간대의 로그를 조회하고, 특정 요청의 트레이스를 추적하는 것이 하나의 흐름으로 가능해졌다.

### 4-2. 텔레메트리 에이전트 통합

이전에는 app 클러스터에 Prometheus Agent(메트릭)와 Promtail(로그)을 별도로 운영했다.

| 이전 | 현재 |
|------|------|
| Prometheus Agent (DaemonSet) | Grafana Alloy (DaemonSet) |
| Promtail (DaemonSet) | ↑ 하나로 통합 |
| OTel Collector (필요 시) | ↑ 트레이스도 포함 |

Alloy 하나로 메트릭 remote_write + 로그 수집 + 트레이스 전달을 처리한다. DaemonSet 수가 줄어 리소스 사용량이 감소하고, 설정 관리가 단순해졌다.

### 4-3. Service Mesh 도입

Cilium과 Istio를 병행하는 이중 구조를 선택했다.

| 계층 | 담당 | 역할 |
|------|------|------|
| L3/L4 | Cilium | Pod 네트워킹, NetworkPolicy, kube-proxy 대체 |
| L7 | Istio | 트래픽 관리, mTLS, 인가 정책, Ingress Gateway |

Istio IngressGateway를 통해 `*.bocopile.io` 도메인으로 10개 서비스에 접근할 수 있다.

```
브라우저 → grafana.bocopile.io
        → /etc/hosts (192.168.64.204)
        → Istio IngressGateway
        → VirtualService 라우팅
        → kube-prometheus-stack-grafana:80
```

도메인별 VirtualService 매핑:

| 도메인 | 서비스 |
|--------|--------|
| grafana.bocopile.io | Grafana 대시보드 |
| prometheus.bocopile.io | Prometheus UI |
| alertmanager.bocopile.io | Alertmanager UI |
| argocd.bocopile.io | ArgoCD 대시보드 |
| kiali.bocopile.io | Kiali Service Mesh 시각화 |
| vault.bocopile.io | Vault UI |
| minio.bocopile.io | MinIO Console |
| s3.bocopile.io | MinIO S3 API |
| tempo.bocopile.io | Tempo API |
| thanos.bocopile.io | Thanos Query UI |

### 4-4. eBPF 보안 계층 추가

Falco(syscall 기반)에 더해 Tetragon(eBPF 기반)을 추가했다.

| 도구 | 방식 | 강점 |
|------|------|------|
| Falco | syscall 후킹 | 규칙 기반 이상 행위 탐지 (파일 접근, 권한 상승 등) |
| Tetragon | eBPF 네이티브 | Cilium 통합, 커널 레벨 프로세스/파일/네트워크 관찰, 낮은 오버헤드 |

두 도구는 보완적이다. Falco는 "무엇이 비정상인지" 탐지하고, Tetragon은 "무엇이 일어나고 있는지" 관찰한다.

### 4-5. IaC 완전 자동화

이전에는 2단계 실행이 필요했다:

```bash
# 이전
tofu apply              # Phase 1: VM + K8s
addons/install.sh --all  # Phase 2: Addon 설치
```

현재는 `main.tf`에 Phase별 의존성을 선언하여 단일 명령으로 통합했다:

```bash
# 현재
tofu apply -auto-approve  # 전체 완료 (VM → K8s → Addon → 검증)
```

main.tf의 Phase 구조:

```
Phase 0: 사전 체크 (check-prerequisites.sh)
Phase 1: VM 생성 → 클러스터 초기화 → Worker Join → Kubeconfig 병합
Phase 2-A: 인프라 Addon (Cilium, MetalLB, Gateway API, cert-manager)
Phase 2-B: Secrets & GitOps (Vault, ESO, ArgoCD) ─┐ 병렬
Phase 2-C: Backup (MinIO, Velero) ─────────────────┘
Phase 2-D: Observability (Thanos, Prometheus, Loki, Tempo, Alloy)
Phase 2-E: Security & Mesh (Istio, Kiali, Falco, Kyverno)
Phase 2-F: Istio Gateway + VirtualService
Phase 3: 인프라 검증 (verify-infra.sh)
```

---

## 5. 보안 구성

### 5-1. 다층 보안 모델

| 계층 | 도구 | mgmt | app1 |
|------|------|------|------|
| Pod 보안 | PSA baseline | ✅ | ✅ |
| 정책 보안 | Kyverno (Enforce) | ❌ (ADR-003) | ✅ 4개 정책 |
| 런타임 보안 | Falco | ❌ | ✅ |
| eBPF 관찰 | Tetragon | ✅ | ✅ |
| 네트워크 암호화 | Istio mTLS | PERMISSIVE | **STRICT** |
| 시크릿 관리 | Vault + ESO | ✅ (origin) | ✅ (동기화) |
| 인증서 | cert-manager + Vault PKI | ✅ | ✅ |

### 5-2. mTLS 설정

- **app1: STRICT** — 모든 워크로드 간 통신에 mTLS를 강제한다. 사이드카 없이는 통신 불가.
- **mgmt: PERMISSIVE** — 모니터링, Vault, ArgoCD 등 플랫폼 서비스가 사이드카 없이 동작하므로 plain text도 허용한다.

이 설정은 `install-istio.sh`에서 Istio 설치 직후 `PeerAuthentication` 리소스로 적용된다.

### 5-3. Kyverno 정책 (app1)

| 정책 | 모드 | 내용 |
|------|------|------|
| restrict-image-registries | Enforce | registry.k8s.io, docker.io, quay.io, ghcr.io만 허용 |
| require-resource-limits | Enforce | 모든 컨테이너에 requests/limits 필수 |
| disallow-privileged-containers | Enforce | privileged: true 금지 |
| require-labels | Audit | app, version 라벨 필수 |

---

## 6. 관찰성 구성

### 6-1. 데이터 흐름

```
┌─────────────────────────────────────────────────────────┐
│ app1 클러스터                                            │
│                                                         │
│  [Pod] → Alloy DaemonSet                                │
│            ├─ remote_write → Thanos Receive (mgmt)      │
│            ├─ loki.write   → Loki (mgmt)                │
│            └─ otlp.export  → Tempo (mgmt)               │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│ mgmt 클러스터                                            │
│                                                         │
│  Thanos Receive ← 메트릭 수신 → Thanos Query            │
│  Loki          ← 로그 수신                               │
│  Tempo         ← 트레이스 수신                            │
│                       ↓                                  │
│              Grafana (통합 대시보드)                       │
│              28개 대시보드 + 추가 데이터소스 2개(Loki, Tempo) │
└─────────────────────────────────────────────────────────┘
```

### 6-2. Graceful Degradation

mgmt 클러스터 장애 시에도 app1 워크로드는 독립적으로 동작한다.

| 컴포넌트 | 정상 시 | mgmt 장애 시 | 버퍼 |
|---------|--------|-------------|------|
| Alloy 메트릭 | remote_write | WAL 로컬 버퍼링 | ~2.7시간 |
| Alloy 로그 | Loki push | positions 파일 보존 | 디스크 용량 |
| External Secrets | Vault 동기화 | 캐시된 Secret 유지 | 1시간 |
| ArgoCD | Git Sync | 기존 워크로드 유지 | 무기한 |

---

## 7. 백업 구성

| 항목 | 설정 |
|------|------|
| 도구 | Velero 1.15 |
| 스토리지 | MinIO (mgmt 클러스터 내부) |
| BSL 상태 | mgmt: Available, app1: Available |
| 대상 | K8s 리소스 + PersistentVolume |

양쪽 클러스터 모두 Velero가 설치되어 있으며, mgmt의 MinIO를 중앙 백업 스토리지로 사용한다.

---

## 8. 네트워크 구성

| 항목 | 설정 |
|------|------|
| CNI | Cilium 1.19.0 (kube-proxy 대체) |
| 터널 모드 | VXLAN (Multipass 브리지 네트워크 제약) |
| LB | MetalLB (L2 모드) |
| Ingress | Istio IngressGateway |
| 도메인 | *.bocopile.io → Istio Gateway → VirtualService |
| L7 Mesh | Istio (트래픽 관리, mTLS, AuthZ) |
| L3/L4 | Cilium (NetworkPolicy, 네트워킹) |
| Gateway API | Cilium 네이티브 지원 활성화 |

---

## 9. 아키텍처 불변 조건 (업데이트)

구현이 변경되더라도 반드시 유지되어야 하는 조건을 정의했다.

| ID | 조건 | 상태 |
|----|------|------|
| C1 | mgmt 장애 시 app 워크로드 독립 실행 | 유지 |
| C2 | Alloy WAL 버퍼링 (~2.7시간) | 변경 (Prometheus Agent → Alloy) |
| C3 | External Secrets 1시간 캐시 | 유지 |
| C4 | Kyverno는 app만 배치 | 유지 |
| C5 | PKI 2-Phase 부트스트랩 (Self-signed → Vault) | 유지 |
| C6 | Cilium VXLAN 모드 | 유지 |
| **C7** | **app1 mTLS STRICT 강제** | **신규** |

---

## 10. 검증 결과

`tofu apply` 완료 후 `verify-infra.sh`가 자동 실행된다.
아래 결과는 기준 실행 1회의 예시다.

```
검증 결과 요약
=================================================================
  PASS: 25
  FAIL: 0
  WARN: 0
  INFO: 3
  합계: 28

  결과: 전체 통과 (참고사항 0 WARN / 3 INFO)
=================================================================
```

INFO 3건은 모두 운영 안내 사항이다:

| INFO | 내용 | 비고 |
|------|------|------|
| /etc/hosts 미등록 | 도메인 접근 시 수동 등록 필요 | `sudo bash scripts/update-hosts-bocopile.sh` |
| Vault 0/1 | unseal 필요 | `bash scripts/vault-unseal.sh` |
| 도메인 1개 503 | MinIO Console VirtualService 라우팅 오류 | 수정 완료 (현재 해소) |

---

## 11. 구축 후 실행 명령어

```bash
# 1. 전체 구축 (VM → K8s → Addon → 검증)
tofu apply -auto-approve

# 2. Vault 초기화 + unseal
bash scripts/vault-unseal.sh

# 3. /etc/hosts 등록 (도메인 접근용)
sudo bash scripts/update-hosts-bocopile.sh

# 4. 대시보드 접근
open http://grafana.bocopile.io
open http://argocd.bocopile.io
open http://kiali.bocopile.io
open http://prometheus.bocopile.io
open http://vault.bocopile.io
open http://minio.bocopile.io
open http://thanos.bocopile.io

# 5. 전체 삭제
tofu destroy -auto-approve
```

---

## 12. 삽질 기록

구축 과정에서 겪은 주요 이슈와 해결 방법을 기록한다.

### Grafana Init:CrashLoopBackOff

kube-prometheus-stack의 Grafana Pod에서 `init-chown-data` init container가 반복 실패했다. local-path StorageClass 환경에서 PVC 마운트 후 chown이 실패하는 문제로, `initChownData.enabled=false`와 `securityContext.fsGroup=472` 설정으로 해결했다.

### Kyverno Webhook 잔존

Kyverno를 삭제해도 `ValidatingWebhookConfiguration`이 남아서 후속 Addon 설치를 차단했다. 설치 순서를 변경하여 Kyverno를 맨 마지막에 설치하도록 조정했다.

### MinIO Console 503

VirtualService에서 `minio:9001`로 라우팅했지만, MinIO Helm chart는 Console을 `minio-console:9001` 별도 서비스로 생성한다. VirtualService의 host를 `minio-console`로 변경하여 해결했다.

### wait_for_lb_ip 로그 오염

`wait_for_lb_ip` 함수가 `log_info`를 stdout으로 출력하면서 `MINIO_IP=$(wait_for_lb_ip ...)`에 `[INFO]` 문자열이 캡처되었다. IP 파일에 로그가 섞여 들어가는 버그로, 함수 내 로그 출력을 `echo "..." >&2`로 직접 stderr 리다이렉트하여 해결했다.

### Vault exit code 2

`vault status`는 sealed 상태일 때 exit code 2를 반환한다. `set -e` 환경에서 이 명령이 스크립트를 중단시키는 문제가 있었다. `|| true`로 exit code를 무시하도록 처리했다.

---

## 13. 기술 스택 요약

| 분류 | 기술 |
|------|------|
| IaC | OpenTofu + Shell script |
| VM | Multipass (Apple Silicon) |
| K8s 설치 | kubeadm v1.35 |
| CNI | Cilium 1.19.0 |
| LB | MetalLB (L2) |
| Service Mesh | Istio 1.29 + Kiali 2.22 |
| 시크릿 | Vault + External Secrets Operator |
| 인증서 | cert-manager + Vault PKI |
| GitOps | ArgoCD |
| 메트릭 | Prometheus + Thanos (Receive) |
| 로그 | Loki |
| 트레이싱 | Tempo |
| 텔레메트리 에이전트 | Grafana Alloy |
| 시각화 | Grafana (28 dashboards) |
| 백업 | Velero + MinIO |
| 정책 보안 | Kyverno (app only) |
| 런타임 보안 | Falco + Tetragon |
| eBPF | Cilium + Tetragon |

---

## 14. 다음 버전 개선 로드맵

### 14-1. 아키텍처 개선

| 항목 | 현재 | 개선 방향 | 우선순위 |
|------|------|----------|---------|
| Cilium Cluster Mesh | 스크립트 준비 (`setup-clustermesh.sh`) | mgmt ↔ app1 간 Pod-to-Pod 직접 통신, 서비스 디스커버리. 적용 시 app1→Tempo 트레이스 경로 완성 | 높음 |
| Istio Ambient Mode | Sidecar 방식 | Sidecar-less L4/L7 처리로 리소스 절감 | 중간 |
| Tempo 차트 | tempo (deprecated) | tempo-distributed로 마이그레이션 | 중간 |
| Vault HA | Standalone (1 replica) | Raft 기반 HA 구성 (3 replica) | 낮음 |

### 14-2. 외부 분리 후보

mgmt-worker-0에 플랫폼 Addon이 집중되어 있어, 리소스 여유를 확보하려면 일부 컴포넌트를 클러스터 외부로 분리하는 것이 필요하다.

| 컴포넌트 | CPU 절감 | Memory 절감 | 외부 대안 |
|----------|---------|------------|----------|
| Thanos (5개 컴포넌트) | +400m | +960Mi | 별도 VM에 binary 실행 또는 Grafana Cloud Metrics |
| MinIO | +50m | +128Mi | macOS에 직접 설치 또는 AWS S3 |
| Grafana | +100m | +128Mi | Grafana Cloud 무료 티어 |
| **합계** | **+550m** | **+1.2Gi** | |

이를 통해 현재 설치 불가능한 OpenSearch(CPU 600m+)도 수용할 수 있게 된다.

### 14-3. 추가 도입 검토

| 도구 | 용도 | 도입 조건 |
|------|------|----------|
| OpenSearch + Dashboards | 로그 분석/검색 (Loki 보완) | 외부 분리로 리소스 확보 후 |
| Argo Rollouts | 카나리/블루그린 배포 | ArgoCD 안정화 후 |
| Crossplane | 인프라 리소스 GitOps화 | Azure 연동 활성화 후 |
| Harbor | Private Container Registry | Azure VM 또는 로컬 Docker |
| Trivy Operator | 이미지/K8s 취약점 스캔 | 리소스 여유 확보 후 |

### 14-4. 코드 정리

| 항목 | 내용 |
|------|------|
| Tempo deprecated 차트 | `grafana/tempo` → `grafana/tempo-distributed` 마이그레이션 |
| common.sh 레거시 함수 | `kubectl_ctx()`, `helm_ctx()` 미사용 함수 제거 |
| variables.tf 미사용 변수 | 5개 변수 → Addon 스크립트 연결 또는 제거 |
| shell/ 레거시 스크립트 | 초기 프로토타입 스크립트 5개 정리 |

### 14-5. 운영 안정성

| 항목 | 현재 | 개선 |
|------|------|------|
| Vault unseal | 수동 (`bash scripts/vault-unseal.sh`) | 자동 unseal (Transit 또는 Kubernetes Auth) |
| /etc/hosts | 수동 등록 | CoreDNS 연동 또는 dnsmasq 자동화 |
| 인프라 검증 | apply 후 1회 실행 | CronJob으로 주기적 헬스체크 |
| Grafana 알림 | 미설정 | Alertmanager → Slack/Email 연동 |

---

## 15. 참고 자료

### Kubernetes & IaC

| 기술 | 링크 |
|------|------|
| Kubernetes | https://kubernetes.io/docs/ |
| kubeadm | https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ |
| OpenTofu | https://opentofu.org/docs/ |
| Multipass | https://multipass.run/docs |

### CNI & 네트워크

| 기술 | 링크 |
|------|------|
| Cilium | https://docs.cilium.io/ |
| Cilium Cluster Mesh | https://docs.cilium.io/en/stable/network/clustermesh/ |
| Cilium Gateway API | https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/ |
| MetalLB | https://metallb.universe.tf/ |
| Gateway API | https://gateway-api.sigs.k8s.io/ |

### Service Mesh

| 기술 | 링크 |
|------|------|
| Istio | https://istio.io/latest/docs/ |
| Istio PeerAuthentication (mTLS) | https://istio.io/latest/docs/reference/config/security/peer_authentication/ |
| Kiali | https://kiali.io/docs/ |

### 관찰성 (Observability)

| 기술 | 링크 |
|------|------|
| Prometheus | https://prometheus.io/docs/ |
| Thanos | https://thanos.io/tip/thanos/getting-started.md/ |
| Grafana | https://grafana.com/docs/grafana/latest/ |
| Grafana Loki | https://grafana.com/docs/loki/latest/ |
| Grafana Tempo | https://grafana.com/docs/tempo/latest/ |
| Grafana Alloy | https://grafana.com/docs/alloy/latest/ |

### 보안

| 기술 | 링크 |
|------|------|
| Kyverno | https://kyverno.io/docs/ |
| Falco | https://falco.org/docs/ |
| Tetragon | https://tetragon.io/docs/ |
| Pod Security Admission | https://kubernetes.io/docs/concepts/security/pod-security-admission/ |

### 시크릿 & 인증서

| 기술 | 링크 |
|------|------|
| HashiCorp Vault | https://developer.hashicorp.com/vault/docs |
| External Secrets Operator | https://external-secrets.io/latest/ |
| cert-manager | https://cert-manager.io/docs/ |

### GitOps & 백업

| 기술 | 링크 |
|------|------|
| ArgoCD | https://argo-cd.readthedocs.io/en/stable/ |
| Velero | https://velero.io/docs/ |
| MinIO | https://min.io/docs/minio/kubernetes/upstream/ |

### Helm Charts

| Chart | Repository |
|-------|-----------|
| kube-prometheus-stack | https://github.com/prometheus-community/helm-charts |
| Loki | https://github.com/grafana/loki/tree/main/production/helm/loki |
| Tempo | https://github.com/grafana/helm-charts/tree/main/charts/tempo |
| Alloy | https://github.com/grafana/alloy/tree/main/operations/helm |
| Thanos | https://github.com/bitnami/charts/tree/main/bitnami/thanos |
| Vault | https://github.com/hashicorp/vault-helm |
| ArgoCD | https://github.com/argoproj/argo-helm |
| Kyverno | https://github.com/kyverno/kyverno/tree/main/charts/kyverno |
| Falco | https://github.com/falcosecurity/charts |
| Velero | https://github.com/vmware-tanzu/helm-charts |
| Kiali | https://github.com/kiali/helm-charts |

# Mac Studio 한 대로 프로덕션급 K8s 멀티클러스터 구축하기

> `tofu apply` 한 번이면 VM 4개, K8s 클러스터 2개, Addon 21개가 자동으로 올라갑니다.
> 이 글은 **왜 이렇게 만들었고, 어떤 문제를 만났고, 실제로 어떻게 돌아가는지** 공유하는 구축기입니다.
>
> 이전 글: [k8s-pattern-on-premise-01](https://velog.io/@gjrjr4545/k8s-pattern-on-premise-01) | [완료 편](https://velog.io/@gjrjr4545/k8s-multicluster-complete)

---

# Part 1. 왜 만들었나

## 1. 구축 동기

"클라우드 없이, 로컬 Mac 한 대에서 프로덕션과 동일한 K8s 플랫폼을 운영할 수 있을까?"

이 질문에서 시작했습니다. 목표는 세 가지였습니다:

1. **클라우드 비용 없이** EKS/GKE 수준의 플랫폼을 재현하는 것
2. **한 번의 명령**으로 전체 인프라가 올라가는 자동화를 만드는 것
3. 실무에서 쓰이는 **CNCF 생태계 도구들을 직접 조합**해보는 것

제약 조건은 명확했습니다:

| 제약 | 내용 |
|------|------|
| **하드웨어** | Mac Studio M1 Max 1대 (64GB RAM, 10-core CPU) |
| **네트워크** | 공인 IP 없음, DNS 없음, macOS 브리지 네트워크만 사용 |
| **비용** | 클라우드 비용 $0 (전부 로컬) |
| **운영** | 1인 운영, sudo 비밀번호 CLI 입력 불가 환경 |

64GB 중 23GB를 VM에 할당하고, 나머지는 호스트 OS와 개발 환경이 사용합니다. "넉넉하지 않은 리소스에서 얼마나 많은 것을 돌릴 수 있는가"가 이 프로젝트의 핵심 도전이었습니다.

---

## 2. 설계 결정 — 왜 이 스택인가?

"왜 이걸 썼어요?" 라는 질문에 답하기 위해, 주요 의사결정을 정리했습니다.

### kubeadm vs k3s vs kind

| | kubeadm | k3s | kind |
|---|---------|-----|------|
| **프로덕션 유사도** | 높음 (실제 운영과 동일) | 중간 (경량화됨) | 낮음 (Docker-in-Docker) |
| **CNI 선택 자유도** | 자유 | 제한적 (Flannel 기본) | 제한적 |
| **학습 가치** | 높음 | 중간 | 낮음 |
| **리소스 사용량** | 높음 | 낮음 | 가장 낮음 |

k3s가 리소스 면에서 유리하지만, **Cilium을 CNI로 직접 구성하고 kubeadm의 동작 원리를 이해하는 것**이 목적이었으므로 kubeadm을 선택했습니다.

### Cilium vs Calico vs Flannel

| | Cilium | Calico | Flannel |
|---|--------|--------|---------|
| **eBPF 기반** | O | 부분적 | X |
| **kube-proxy 대체** | O | X | X |
| **NetworkPolicy** | L3/L4/L7 | L3/L4 | X |
| **Cluster Mesh** | 내장 | 별도 구성 | X |
| **Hubble (관찰성)** | 내장 | X | X |

CNI + kube-proxy 대체 + NetworkPolicy + 관찰성을 **하나의 도구로 해결**할 수 있는 건 Cilium뿐이었습니다. CNCF Graduated 프로젝트이기도 하고요.

### Loki vs OpenSearch (로그)

| | Loki | OpenSearch |
|---|------|-----------|
| **메모리** | ~400MB | ~1.2GB+ |
| **인덱싱** | 라벨만 (namespace, pod) | 전문 인덱싱 |
| **Grafana 연동** | 네이티브 | 플러그인 |
| **운영 복잡도** | 낮음 (SingleBinary) | 높음 (클러스터 모드) |

23GB RAM에서 관찰성 스택 전체를 돌려야 하므로, **메모리 400MB로 운영 가능한 Loki**를 선택했습니다. 전문 검색이 필요하면 향후 OpenSearch를 Azure VM으로 분리할 계획입니다.

### Istio + Cilium 듀얼 vs Cilium 단독

Cilium만으로도 L7 정책과 mTLS가 가능하지만, **Istio의 VirtualService/AuthorizationPolicy/Kiali 생태계**를 포기하기 어려웠습니다. 역할을 명확히 분리했습니다:

- **Cilium**: L3/L4 네트워킹, kube-proxy 대체, NetworkPolicy
- **Istio**: L7 라우팅, mTLS, IngressGateway, 서비스 메시 관찰성

### Terraform → OpenTofu

HashiCorp가 Terraform 라이선스를 BSL로 변경한 후, 동일 HCL 문법을 지원하는 **OpenTofu (MPL 2.0)** 로 마이그레이션했습니다. `terraform` → `tofu`로 바꾸는 것 외에 코드 변경은 없었습니다.

### 뺀 것들 — 리소스와의 싸움

처음에는 27개 Addon을 설치했습니다. mgmt-worker-0의 **CPU가 97% (1940m/2000m)** 에 도달하면서, 6개를 제거해야 했습니다:

| 제거된 Addon | 이유 |
|-------------|------|
| K8sGPT + HolmesGPT | AI 모델 로딩에 CPU/메모리 과다 소비 |
| Chaos Mesh | 테스트 도구, 상시 운영 불필요 |
| OpenCost + Goldilocks | 비용 최적화 도구, 로컬 환경에 불필요 |
| BotKube | Slack 연동 알림, 1인 운영에 과잉 |

동시에 **app2 클러스터를 제거**하고, 확보된 리소스를 mgmt-worker-0에 재분배했습니다 (2CPU/10GB → 4CPU/12GB).

> K8sGPT는 "kubectl로 디버깅하면 AI가 원인을 분석해주는" 트렌디한 도구였지만, 상시 운영하기엔 리소스 대비 효용이 낮았습니다. 필요 시 수동 설치 스크립트(`install-platform-addons.sh`)를 남겨두었습니다.

---

## 3. 따라하기 — Quick Start

### 사전 조건

| 도구 | 용도 | 필수 여부 |
|------|------|----------|
| Multipass | VM 생성/관리 | 필수 |
| OpenTofu >= 1.11 | IaC 실행 | 필수 |
| Helm >= 3.x | 패키지 설치 | 필수 |
| kubectl >= 1.35 | 클러스터 관리 | 필수 |
| jq | JSON 파싱 | 필수 |
| Cilium CLI | 네트워크 관리 | 필수 |
| ArgoCD CLI | 클러스터 등록 | 선택 (없으면 수동 등록) |

| 호스트 리소스 | 권장 |
|-------------|------|
| RAM | 32GB 이상 (64GB 권장) |
| 디스크 여유 | 200GB 이상 |
| CPU | Apple Silicon (M1/M2/M3/M4) |

### 구축 명령 (5줄)

```bash
# 1. 사전 점검 (1분)
bash scripts/check-prerequisites.sh

# 2. 인프라 + K8s + 21개 Addon 자동 설치 (30~45분)
tofu apply -auto-approve

# 3. Vault 초기화 (수동, 1분)
bash scripts/vault-unseal.sh

# 4. 도메인 접근 설정 (수동, /etc/hosts 등록)
sudo bash scripts/update-hosts-bocopile.sh

# 5. (선택) Cluster Mesh + Vault PKI 추가 설치
bash addons/install.sh --all --yes
```

**예상 소요 시간: 약 35~50분**
- Phase 1 (VM + K8s 초기화): ~15분
- Phase 2 (21개 Addon 설치): ~20~30분
- Phase 3 (수동 후처리): ~5분

### 실패 시 체크포인트

| 단계 | 실패 증상 | 확인 방법 |
|------|----------|----------|
| VM 생성 | `multipass launch` timeout | `multipass list`로 VM 상태 확인 |
| K8s 초기화 | kubeadm init 실패 | VM SSH 후 `journalctl -u kubelet` 확인 |
| Addon 설치 | Helm timeout | `kubectl get pods -A`로 Pending/CrashLoop 확인 |
| Vault | Sealed 상태 유지 | `vault-unseal.sh` 재실행 |
| 도메인 접근 | 브라우저 접속 불가 | `/etc/hosts`에 `192.168.64.204 *.bocopile.io` 등록 확인 |

> 전체를 처음부터 다시 시작하려면: `tofu destroy -auto-approve && tofu apply -auto-approve`

---

# Part 2. 무엇을 만들었나 (As-is)

## 4. 전체 아키텍처 — 현재 동작 상태

아래 다이어그램은 두 클러스터에 **어떤 컴포넌트가 어디에 배치되어 있는지** 보여줍니다.

![전체 아키텍처](https://velog.velcdn.com/images/gjrjr4545/post/4d22503e-09c1-4433-9a60-d41c9f2a1b47/image.png)

| VM | 클러스터 | CPU | RAM | Disk |
|----|---------|-----|-----|------|
| mgmt-cp | mgmt (CP) | 2 | 4GB | 40GB |
| mgmt-worker-0 | mgmt (Worker) | **4** | **12GB** | 60GB |
| app1-cp | app1 (CP) | 2 | 3GB | 30GB |
| app1-worker-0 | app1 (Worker) | 2 | 4GB | 40GB |
| **합계** | | **10** | **23GB** | **170GB** |

### 클러스터 간 데이터 흐름

| 데이터 | 출발 | 도착 | 경로 |
|--------|------|------|------|
| 메트릭 | app1 Alloy | mgmt Thanos Receive | MetalLB LB IP (192.168.64.202) |
| 로그 | app1 Alloy | mgmt Loki | MetalLB LB IP (192.168.64.203) |
| 트레이스 | app1 Alloy | mgmt Tempo | Cilium Cluster Mesh (별도 구성 필요) |
| 시크릿 | mgmt Vault | app1 ESO | MetalLB LB IP (192.168.64.201) |
| 백업 | 양쪽 Velero | mgmt MinIO | MetalLB LB IP (192.168.64.200) |
| WebUI | 브라우저 | Istio IngressGateway | /etc/hosts → 192.168.64.204 |

### 현재 한계 (As-is)

| 항목 | 상태 | 비고 |
|------|------|------|
| Cluster Mesh | 미구성 | 스크립트 준비됨, 트레이스 전송 경로 미완성 |
| Vault auto-unseal | 미적용 | 재시작 시 수동 unseal 필요 |
| Vault PKI | 미전환 | Self-signed 단계에 머무름 |
| HA 구성 | 없음 | Control Plane 1개씩 (SPOF) |
| 실제 워크로드 | 미배포 | 플랫폼만 구축, 애플리케이션 배포 전 |
| NetworkPolicy | 미적용 | 스크립트 준비됨, 수동 적용 필요 |

---

## 5. 인프라 계층 (5개)

### 5-1. Cilium — eBPF 기반 CNI

| 항목 | 내용 |
|------|------|
| **GitHub** | [cilium/cilium](https://github.com/cilium/cilium) |
| **버전** | 1.19.0 · CNCF Graduated |
| **배치** | 전 클러스터 (DaemonSet) |

Cilium은 **eBPF 기반 CNI**입니다. iptables 대신 커널의 eBPF를 사용하여 패킷을 처리하므로, 성능 저하가 적습니다.

| 기능 | 설명 |
|------|------|
| **Pod 네트워킹** | VXLAN 터널 모드로 클러스터 내 Pod 간 통신 |
| **kube-proxy 대체** | eBPF 기반 서비스 라우팅 (iptables 제거) |
| **NetworkPolicy** | L3/L4 수준 트래픽 제어 |
| **Cluster Mesh** | 클러스터 간 Pod-to-Pod 직접 통신 (스크립트 준비됨, 별도 실행 필요) |
| **Hubble** | 네트워크 트래픽 관찰성 (UI + Relay) |
| **Gateway API** | 네이티브 CRD 지원 |

```yaml
# 핵심 설정
routingMode: tunnel        # VXLAN (Multipass 브리지 네트워크 호환)
kubeProxyReplacement: true # kube-proxy 완전 대체
gatewayAPI.enabled: true
hubble.enabled: true
```

> **왜 VXLAN인가?** Multipass는 macOS 브리지 네트워크를 사용합니다. Native Routing은 호스트 라우팅 테이블 수정이 필요한데 macOS에서는 복잡하므로, 오버레이 네트워크인 VXLAN을 선택했습니다.

---

### 5-2. MetalLB — 베어메탈 로드밸런서

| 항목 | 내용 |
|------|------|
| **GitHub** | [metallb/metallb](https://github.com/metallb/metallb) |
| **버전** | v0.15.3 |
| **배치** | 전 클러스터 |

클라우드의 ELB/ALB 대신, 온프레미스에서 `type: LoadBalancer` 서비스에 External IP를 할당합니다. L2(ARP) 모드로 동작합니다.

| External IP | 서비스 |
|-------------|--------|
| 192.168.64.200 | MinIO (S3 API) |
| 192.168.64.201 | Vault (API) |
| 192.168.64.202 | Thanos Receive |
| 192.168.64.203 | Loki |
| 192.168.64.204 | Istio IngressGateway |

---

### 5-3. Gateway API — 차세대 Ingress 표준

| 항목 | 내용 |
|------|------|
| **GitHub** | [kubernetes-sigs/gateway-api](https://github.com/kubernetes-sigs/gateway-api) |
| **버전** | v1.2.1 (CRD) |
| **배치** | 전 클러스터 |

기존 Ingress 리소스의 한계를 해결하기 위한 **표준 CRD**입니다. Cilium(L3/L4)과 Istio(L7)가 각각 Gateway API 구현체로 활용합니다.

---

### 5-4. cert-manager — 인증서 자동화

| 항목 | 내용 |
|------|------|
| **GitHub** | [cert-manager/cert-manager](https://github.com/cert-manager/cert-manager) |
| **버전** | v1.17.1 · CNCF Graduated |
| **배치** | 전 클러스터 |

TLS 인증서의 **발급/갱신/관리를 자동화**합니다. PKI 부트스트랩 시 닭-달걀 문제(Vault에 필요한 인증서를 Vault가 발급해야 함)를 **Self-signed → Vault Issuer 2단계**로 해결합니다:

![PKI 부트스트랩](https://velog.velcdn.com/images/gjrjr4545/post/334f2e79-3140-4e8e-8373-663acffeda71/image.png)

---

### 5-5. Local Path Provisioner — 로컬 스토리지

| 항목 | 내용 |
|------|------|
| **GitHub** | [rancher/local-path-provisioner](https://github.com/rancher/local-path-provisioner) |
| **배치** | 전 클러스터 |

클라우드의 EBS/PD 대신, 노드 로컬 디스크를 PV로 자동 프로비저닝합니다.

| StorageClass | ReclaimPolicy | 용도 |
|-------------|---------------|------|
| local-path (기본) | Delete | 일반 워크로드, MinIO |
| local-path-retain | Retain | Vault, Prometheus, Loki, Grafana, Tempo |

---

## 6. 시크릿 & GitOps (3개)

### 6-1. HashiCorp Vault — 시크릿 관리 & PKI

| 항목 | 내용 |
|------|------|
| **GitHub** | [hashicorp/vault](https://github.com/hashicorp/vault) |
| **모드** | Standalone (1 replica) |
| **배치** | mgmt 클러스터 |

**시크릿 관리의 사실상 표준**으로, 이 프로젝트에서 두 가지 역할을 수행합니다:

![Vault 역할](https://velog.velcdn.com/images/gjrjr4545/post/446e3995-61b2-437c-90b7-071fc7ea7c42/image.png)

- **KV Secrets**: MinIO 자격증명, Grafana 비밀번호 등 모든 시크릿을 저장합니다
- **PKI Engine**: 내부 CA를 운영하고, cert-manager 연동으로 TLS 인증서를 자동 발급합니다

---

### 6-2. External Secrets Operator (ESO) — 시크릿 동기화

| 항목 | 내용 |
|------|------|
| **GitHub** | [external-secrets/external-secrets](https://github.com/external-secrets/external-secrets) |
| **CNCF 등급** | Incubating |
| **배치** | 전 클러스터 (`security` 네임스페이스) |

Vault의 시크릿을 K8s Secret으로 **1시간 주기로 자동 동기화**합니다. Vault가 다운되어도 캐시된 Secret이 1시간 유지되어 워크로드에 영향이 없습니다.

> 사전 조건: Vault 토큰 Secret(`vault-token`)이 ESO 설치 네임스페이스(`security`)에 생성되어 있어야 합니다.

---

### 6-3. ArgoCD — GitOps 배포 엔진

| 항목 | 내용 |
|------|------|
| **GitHub** | [argoproj/argo-cd](https://github.com/argoproj/argo-cd) |
| **차트 버전** | 9.4.7 · CNCF Graduated |
| **배치** | mgmt 클러스터 |

Git 저장소의 매니페스트와 클러스터 상태를 **지속적으로 동기화**하는 GitOps 엔진입니다. mgmt 클러스터에서 양쪽 클러스터를 관리할 수 있습니다.

> app1 클러스터 등록은 ArgoCD CLI 로그인 성공 시 자동으로 수행됩니다. CLI가 없거나 로그인 실패 시 수동 등록이 필요합니다.

---

## 7. 관찰성 (5개)

관찰성은 **Metrics(메트릭)**, **Logs(로그)**, **Traces(트레이스)** 세 축으로 구성됩니다.

![관찰성 3-pillar](https://velog.velcdn.com/images/gjrjr4545/post/816a391c-7804-4302-af55-33b14725ef1c/image.png)

> 이전에는 Prometheus Agent + Promtail + OTel Collector 3개 DaemonSet이 필요했습니다. **Alloy 하나로 통합**하여 리소스와 설정 관리가 단순해졌습니다.

### 7-1. Prometheus + Grafana + Alertmanager — 메트릭 수집 & 시각화

| 항목 | 내용 |
|------|------|
| **GitHub** | [prometheus/prometheus](https://github.com/prometheus/prometheus) / [grafana/grafana](https://github.com/grafana/grafana) |
| **배치** | mgmt 클러스터 ([kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)) |

하나의 Helm chart로 세 컴포넌트를 설치합니다:

| 컴포넌트 | 역할 |
|---------|------|
| **Prometheus** | K8s 메트릭 수집 (kubelet, cAdvisor, node-exporter, ServiceMonitor) |
| **Grafana** | 28개 대시보드 (클러스터, 노드, Pod, 네트워크 등) |
| **Alertmanager** | 알림 규칙 평가 및 알림 전송 |

---

### 7-2. Thanos — 멀티클러스터 메트릭 집계

| 항목 | 내용 |
|------|------|
| **GitHub** | [thanos-io/thanos](https://github.com/thanos-io/thanos) |
| **모드** | Receive · CNCF Incubating |
| **배치** | mgmt 클러스터 |

단일 클러스터라면 Prometheus만으로 충분하지만, 멀티클러스터에서는 **메트릭을 한 곳에서 조회**할 수 있어야 합니다.

| 컴포넌트 | 역할 |
|---------|------|
| **Receive** | app1 Alloy에서 remote_write로 전송된 메트릭 수신 |
| **Query** | Prometheus 로컬 + Receive 데이터를 통합 조회 |
| **Compactor** | 다운샘플링, MinIO에 장기 저장 |

---

### 7-3. Grafana Loki — 로그 집계

| 항목 | 내용 |
|------|------|
| **GitHub** | [grafana/loki](https://github.com/grafana/loki) |
| **차트 버전** | 6.53.0 · SingleBinary 모드 |
| **저장소** | 노드 로컬 디스크 (filesystem, `local-path-retain` PVC) |
| **배치** | mgmt 클러스터 |

**경량 로그 집계 시스템**입니다. Elasticsearch와 달리 로그 본문을 인덱싱하지 않고, **라벨(namespace, pod 등)만 인덱싱**하여 메모리 400MB 수준으로 운영 가능합니다.

---

### 7-4. Grafana Tempo — 분산 트레이싱

| 항목 | 내용 |
|------|------|
| **GitHub** | [grafana/tempo](https://github.com/grafana/tempo) |
| **차트 버전** | 1.24.4 |
| **저장소** | 노드 로컬 디스크 (`local-path-retain` PVC) |
| **배치** | mgmt 클러스터 |

마이크로서비스에서 하나의 요청이 거치는 **전체 경로를 추적**합니다 (OpenTelemetry/Jaeger/Zipkin 호환). Grafana에서 메트릭 알림 확인 → 해당 시간대 로그 조회 → 특정 요청 트레이스 추적이 하나의 흐름으로 가능해집니다.

---

### 7-5. Grafana Alloy — 통합 텔레메트리 에이전트

| 항목 | 내용 |
|------|------|
| **GitHub** | [grafana/alloy](https://github.com/grafana/alloy) |
| **버전** | 1.6.1 |
| **배치** | 전 클러스터 (DaemonSet) |

메트릭(remote_write) + 로그(loki.write) + 트레이스(otlp.export)를 **단일 에이전트로 수집/전달**합니다.

> mgmt 장애 시에도 app1의 Alloy는 **WAL 로컬 버퍼링**으로 약 2.7시간 분량의 메트릭을 보존하며, 복구 후 자동 재전송합니다.

---

## 8. Service Mesh (2개)

### 8-1. Istio — L7 트래픽 관리 & mTLS

| 항목 | 내용 |
|------|------|
| **GitHub** | [istio/istio](https://github.com/istio/istio) |
| **버전** | 1.29.0 · CNCF Graduated |
| **배치** | mgmt + app1 |

각 Pod에 Sidecar Proxy(Envoy)를 주입하여 암호화/인증/라우팅/관찰성을 투명하게 제공합니다.

**Cilium(L3/L4)과 Istio(L7)의 역할 분담:**

| 영역 | Cilium | Istio |
|------|--------|-------|
| Pod 네트워킹, NetworkPolicy | O | - |
| kube-proxy 대체 | O | - |
| HTTP/gRPC 라우팅, Retry/Timeout | - | O |
| mTLS (서비스 간 암호화) | - | O |
| AuthorizationPolicy | - | O |
| 관찰성 | Hubble (패킷) | Kiali (서비스) |

**mTLS 설정:**
- **app1: STRICT** — 모든 워크로드 간 mTLS 강제, Sidecar 없이는 통신 불가
- **mgmt: PERMISSIVE** — Sidecar 없는 플랫폼 서비스 호환

**IngressGateway를 통한 도메인 접근:**

![Istio IngressGateway](https://velog.velcdn.com/images/gjrjr4545/post/1410a03e-db20-4e9b-b55f-44520816c647/image.png)

---

### 8-2. Kiali — Service Mesh 시각화

| 항목 | 내용 |
|------|------|
| **GitHub** | [kiali/kiali](https://github.com/kiali/kiali) |
| **버전** | 2.22.0 |
| **배치** | mgmt + app1 |

Istio 전용 관찰성 대시보드로, **서비스 간 트래픽 흐름을 그래프로 시각화**하고 에러율/지연시간/요청 수를 실시간으로 보여줍니다. Istio Config 오류도 자동 감지합니다.

---

## 9. 보안 (3개)

### 9-1. Tetragon — eBPF 런타임 보안 관찰

| 항목 | 내용 |
|------|------|
| **GitHub** | [cilium/tetragon](https://github.com/cilium/tetragon) |
| **버전** | 1.3.0 · CNCF Incubating |
| **배치** | 전 클러스터 (DaemonSet) |

Cilium 프로젝트의 일부로, **커널 레벨에서 프로세스 실행/파일 접근/네트워크 연결/권한 변경**을 관찰합니다. syscall 후킹이 아닌 eBPF 프로브를 사용하므로 오버헤드가 낮습니다.

---

### 9-2. Falco — 런타임 위협 탐지

| 항목 | 내용 |
|------|------|
| **GitHub** | [falcosecurity/falco](https://github.com/falcosecurity/falco) |
| **버전** | 4.16.0 · CNCF Graduated |
| **배치** | app1 클러스터 |

커널 syscall을 모니터링하여 **비정상 행위를 실시간 탐지**합니다: 컨테이너 내 셸 실행, 민감 파일 접근, 비정상 네트워크 연결, 권한 상승 시도, 바이너리 변조 등.

**Tetragon vs Falco — 보완 관계:**

| | Tetragon | Falco |
|---|----------|-------|
| **목적** | 이벤트 **관찰** (데이터 수집) | 위협 **탐지** (규칙 기반 알림) |
| **방식** | eBPF 프로브 (커널 네이티브) | syscall 후킹 |
| **강점** | 낮은 오버헤드, Cilium 통합 | 풍부한 규칙 생태계 |
| **배치** | 전 클러스터 | app1만 (워크로드 보호) |

> Tetragon은 "무엇이 일어나고 있는지" 관찰하고, Falco는 "무엇이 비정상인지" 탐지합니다. 두 도구를 함께 사용하면 관찰 + 탐지가 모두 커버됩니다.

---

### 9-3. Kyverno — 정책 엔진

| 항목 | 내용 |
|------|------|
| **GitHub** | [kyverno/kyverno](https://github.com/kyverno/kyverno) |
| **버전** | 3.3.4 · CNCF Incubating |
| **배치** | **app1 클러스터만** |

K8s Admission Webhook 기반 정책 엔진으로, Pod 생성 시 규칙을 검증하고 위반 시 거부합니다.

| 정책 | 모드 | 내용 |
|------|------|------|
| `restrict-image-registries` | **Enforce** | `registry.k8s.io`, `docker.io`, `quay.io`, `ghcr.io`만 허용 |
| `require-resource-limits` | **Enforce** | 모든 컨테이너에 requests/limits 필수 |
| `disallow-privileged-containers` | **Enforce** | privileged: true 금지 |
| `require-labels` | Audit | app, version 라벨 필수 |

> **왜 app1만?** mgmt는 플랫폼 운영자 영역이므로 PSA baseline만 적용합니다. app1은 개발팀 워크로드 영역이므로 엄격하게 제어합니다.
>
> **왜 맨 마지막에 설치?** Kyverno Webhook이 후속 Helm install을 차단할 수 있으므로 모든 Addon 설치 완료 후 마지막에 설치합니다.

---

## 10. 백업 (2개)

### 10-1. MinIO — S3 호환 오브젝트 스토리지

| 항목 | 내용 |
|------|------|
| **GitHub** | [minio/minio](https://github.com/minio/minio) |
| **배치** | mgmt 클러스터 |

**AWS S3 호환 오브젝트 스토리지**로, 온프레미스에서 S3 API로 데이터를 저장합니다.

| 버킷 | 용도 | 쓰기 주체 |
|------|------|----------|
| `velero-backups` | K8s 리소스 + PV 백업 | Velero |
| `thanos` | 메트릭 장기 저장 | Thanos Compactor |

> Loki와 Tempo는 현재 노드 로컬 디스크(`local-path-retain` PVC)를 사용합니다. 향후 데이터 내구성을 위해 MinIO S3 백엔드로 전환할 수 있습니다.

---

### 10-2. Velero — K8s 백업/복원

| 항목 | 내용 |
|------|------|
| **GitHub** | [vmware-tanzu/velero](https://github.com/vmware-tanzu/velero) |
| **차트 버전** | 8.2.0 · CNCF Sandbox |
| **배치** | 전 클러스터 |

K8s 리소스와 PV 데이터를 **매일 02:00에 자동 백업**합니다. 양쪽 클러스터 모두 설치되어 있으며, mgmt MinIO를 중앙 스토리지로 사용합니다 (클러스터별 prefix: `mgmt/`, `app1/`).

---

## 11. 보안 계층 요약 (5-Layer)

이 플랫폼은 **5계층 보안 모델**을 적용하고 있습니다:

![5-Layer 보안 모델](https://velog.velcdn.com/images/gjrjr4545/post/d10fae53-d6eb-4cd6-8aa7-814906fbd438/image.png)

| 계층 | mgmt | app1 |
|------|------|------|
| L1 RBAC | O | O |
| L2 PSA baseline | O | O |
| L2 Kyverno Enforce | X | O (4개 정책) |
| L3 Cilium NetworkPolicy | O (수동 적용) | O (수동 적용) |
| L3 Istio mTLS | PERMISSIVE | **STRICT** |
| L4 Vault + ESO | O (origin) | O (동기화) |
| L5 Falco | X | O |
| L5 Tetragon | O | O |

> NetworkPolicy(deny-all 기본 모델)는 `bash addons/scripts/security/apply-network-policies.sh`로 수동 적용이 필요합니다.

---

## 12. 설치 순서와 의존성

![설치 순서와 의존성](https://velog.velcdn.com/images/gjrjr4545/post/e4e853e6-4920-4fb3-b464-f08041254293/image.png)

![설치 실행 결과](https://velog.velcdn.com/images/gjrjr4545/post/cfe8a5c4-4eff-40d4-86df-8b5bad39d285/image.png)

> Tetragon은 보안 도구이지만 Cilium과 동일한 eBPF 기반이므로, Cilium 직후 Phase 1에서 설치합니다.
>
> Cluster Mesh와 Vault PKI는 `bash addons/install.sh --all`로 별도 실행 시 추가 설치됩니다.

---

# Part 3. 실제로 어땠나

## 13. 삽질 기록

정답만 보면 쉬워 보이지만, 여기까지 오는 데 수많은 시행착오가 있었습니다. 그중 인상적이었던 것들을 공유합니다.

### 13-1. macOS bash 3.2 호환성 지옥

macOS 기본 bash는 **3.2 (2007년 릴리즈)** 입니다. GPLv3 라이선스 때문에 Apple이 업데이트를 멈췄기 때문인데, 이것 때문에 스크립트 전체가 깨졌습니다.

**문제**: `mapfile`, `associative array`, `nameref` 등 bash 4+ 기능을 사용한 스크립트가 macOS에서 실패

**해결**: Homebrew bash 5.x를 설치하고, 모든 스크립트에 `PATH=/opt/homebrew/bin:$PATH`를 추가. `mapfile` → `jq + for` 루프로 대체.

### 13-2. 닭-달걀 문제 — "설정 파일을 읽으려면 설정이 필요해"

`install.sh`가 `clusters.json`을 읽어 클러스터 목록을 얻는데, `clusters.json`은 `tofu apply`가 생성합니다. 그런데 `check-prerequisites.sh`는 `tofu apply` 전에 실행되어야 하고, 이 스크립트도 `common.sh`의 `setup_common_vars()`를 호출합니다.

**문제**: `check-prerequisites.sh` 실행 시 `clusters.json`이 없어서 에러

**해결**: `setup_common_vars()`에 early return 로직 추가 — `clusters.json`이 없으면 스킵하고, 필요한 기본값만 사용.

### 13-3. Thanos ServiceMonitor CRD 미존재

처음에는 Thanos를 Prometheus Stack보다 먼저 설치했습니다.

**문제**: Thanos Helm chart가 ServiceMonitor CRD를 참조하는데, 이 CRD는 Prometheus Stack이 제공합니다. 없는 CRD를 참조하니 설치 실패.

**해결**: INSTALL_ORDER에서 `prometheus-stack → thanos` 순서로 변경. 이런 "암묵적 의존성"이 설치 순서를 결정하는 핵심이었습니다.

### 13-4. PVC 4개 동시 Pending

Vault, Prometheus, Loki, Grafana 4개가 동시에 PVC Pending 상태에 빠졌습니다.

**문제**: `local-path-retain` StorageClass가 Addon 설치 단계에서 생성되는데, 해당 SC를 참조하는 PVC가 먼저 생성됨

**해결**: `local-path-retain` SC 생성을 인프라 단계(Phase 1)로 이동. Local Path Provisioner 설치 직후 바로 생성되도록 변경.

### 13-5. CPU 97% — app2 클러스터 제거 결정

27개 Addon을 3개 클러스터에 설치한 결과:

```
mgmt-worker-0:  CPU 1940m/2000m (97%)  Memory 3.6Gi/10Gi (36%)
```

CPU가 거의 포화 상태였습니다.

**결정**: app2 클러스터를 제거하고, 확보된 리소스를 mgmt-worker-0에 재분배 (2CPU/10GB → 4CPU/12GB). 동시에 상시 운영이 불필요한 6개 Addon을 제거.

**교훈**: 로컬 환경에서는 "무엇을 넣을까"보다 **"무엇을 뺄까"** 가 더 중요한 설계 결정이었습니다.

### 13-6. ESO namespace 버그 — 코드 리뷰의 중요성

ESO 설치 스크립트에서 `ClusterSecretStore`의 `tokenSecretRef.namespace`가 `"external-secrets"`로 하드코딩되어 있었습니다. 하지만 실제 ESO는 `security` 네임스페이스에 설치됩니다.

**문제**: Vault 토큰 Secret을 `security` 네임스페이스에 만들어도, ESO가 `external-secrets` 네임스페이스에서 찾으려 함

**해결**: 하드코딩을 `"${NAMESPACE_SECURITY}"` 변수로 교체. 문서화 과정에서 코드를 꼼꼼히 읽으며 발견한 버그였습니다.

### 13-7. Vault Pod 스케줄링 대기

Vault StatefulSet이 worker 노드에 스케줄링되기까지 시간이 걸리는데, 스크립트가 그 전에 다음 단계로 넘어갔습니다.

**문제**: Vault Pod가 아직 Running이 아닌데 ESO가 Vault에 연결 시도 → 실패

**해결**: 노드 할당 대기 루프 추가, Helm timeout을 180s → 300s로 확대. "느린 것은 실패가 아니다"를 코드에 반영.

---

## 14. 구축 결과

> 이 섹션은 실제 `tofu apply` 실행 후 캡처한 결과물로 채워질 예정입니다.

### 14-1. Pod 상태

```bash
kubectl get pods -A --context kubernetes-admin@mgmt | grep -v Completed
kubectl get pods -A --context kubernetes-admin@app1 | grep -v Completed
```

> `~/.kube/config`에 자동 병합되므로 `--kubeconfig` 플래그 없이 사용 가능합니다.

**mgmt 클러스터 (57개 Pod):**

![mgmt pods](https://velog.velcdn.com/images/gjrjr4545/post/5dd272ec-a654-4bbc-bb3e-bea16fff29fb/image.png)

**app1 클러스터 (40개 Pod):**

![app1 pods](https://velog.velcdn.com/images/gjrjr4545/post/e8e9f7e6-9b7-45e6-9df9-449211bb1b4e/image.png)

![app1 pods 2](https://velog.velcdn.com/images/gjrjr4545/post/b0c84ef1-2eeb-459c-9096-21c8da8673ec/image.png)

### 14-2. 리소스 사용량

```bash
multipass info mgmt-cp mgmt-worker-0 app1-cp app1-worker-0
```

![리소스 사용량](https://velog.velcdn.com/images/gjrjr4545/post/6c41d346-e3d1-473e-a4f6-109a69b164ef/image.png)

### 14-3. 서비스 접근 화면

| 서비스 | URL | 캡처 |
|--------|-----|------|
| Grafana | grafana.bocopile.io | <!-- TODO: 스크린샷 --> |
| ArgoCD | argocd.bocopile.io | <!-- TODO: 스크린샷 --> |
| Kiali | kiali.bocopile.io | <!-- TODO: 스크린샷 --> |
| Vault | vault.bocopile.io | <!-- TODO: 스크린샷 --> |
| Prometheus | prometheus.bocopile.io | <!-- TODO: 스크린샷 --> |

---

# Part 4. 앞으로

## 15. To-be 아키텍처 — 목표 상태

As-is에서 해결하지 못한 부분들의 로드맵입니다.

![To-be 아키텍처](https://velog.velcdn.com/images/gjrjr4545/post/2a529e4c-65bc-4fd7-859c-f3bf7f769b8a/image.png)

| 우선순위 | 항목 | 기대 효과 |
|---------|------|----------|
| 1 | Vault unseal + PKI 전환 | Self-signed → 내부 CA 자동 발급 |
| 2 | Cluster Mesh 완성 | app1 → mgmt 트레이스 전송 경로 확보 |
| 3 | Azure VM 연동 | Harbor(컨테이너 레지스트리) + Nexus(아티팩트) 분리 |
| 4 | OpenSearch 분리 | 전문 검색 필요 시 Loki 보완 |
| 5 | AIOps 재도입 | K8sGPT — 리소스 확보 후 검토 |

---

## 16. 기술 스택 한눈에 보기

| 분류 | 기술 | 선택 이유 |
|------|------|----------|
| **IaC** | OpenTofu 1.11 | Terraform 호환 + BSL 라이선스 우회 |
| **VM** | Multipass | macOS에서 가장 간단한 Ubuntu VM (hyperkit/QEMU 직접 설정 불필요) |
| **K8s** | kubeadm v1.35 | 프로덕션 표준, 세밀한 클러스터 제어 가능 (k3s/kind 대비) |
| **CNI** | Cilium 1.19.0 | eBPF로 kube-proxy 대체 + NetworkPolicy + Hubble 관찰성 통합 |
| **LB** | MetalLB v0.15.3 | 온프레미스에서 `type: LoadBalancer` 유일한 선택지 |
| **Gateway** | Gateway API v1.2.1 | Ingress 대체 K8s 표준, Cilium/Istio 모두 지원 |
| **Storage** | Local Path Provisioner | EBS 없는 환경에서 PV 자동 프로비저닝 (Retain 정책 지원) |
| **Service Mesh** | Istio 1.29.0 | L7 라우팅 + mTLS + AuthorizationPolicy (Cilium이 못 하는 영역) |
| **Mesh 시각화** | Kiali 2.22.0 | Istio 전용 서비스 그래프 + Config 오류 자동 감지 |
| **시크릿** | Vault + ESO | 사실상 표준 시크릿 저장소 + K8s Secret 자동 동기화 |
| **인증서** | cert-manager v1.17.1 | TLS 인증서 자동화 CNCF 표준, Vault PKI 연동 |
| **GitOps** | ArgoCD 9.4.7 | 멀티클러스터 Git 동기화 + CNCF Graduated |
| **메트릭** | Prometheus + Thanos | K8s 메트릭 표준 + 멀티클러스터 집계 (Receive 모드) |
| **로그** | Loki | 인덱싱 없이 라벨만으로 검색 → 메모리 400MB급 운영 가능 |
| **트레이싱** | Tempo 1.24.4 | Grafana 네이티브, OTLP 호환, 별도 인덱싱 DB 불필요 |
| **에이전트** | Alloy 1.6.1 | Promtail + OTel Collector + Prometheus Agent 3개를 1개로 통합 |
| **시각화** | Grafana | Prometheus/Loki/Tempo 네이티브 연동, 28개 대시보드 자동 프로비저닝 |
| **백업** | Velero 8.2.0 + MinIO | K8s 리소스 + PV 백업 CNCF 표준 + 온프레미스 S3 스토리지 |
| **정책** | Kyverno 3.3.4 | YAML로 정책 작성 (OPA/Rego 학습 불필요) |
| **런타임 보안** | Falco 4.16.0 | syscall 기반 위협 탐지, 풍부한 규칙 생태계 |
| **eBPF 보안** | Tetragon 1.3.0 | eBPF 네이티브로 낮은 오버헤드, Cilium 생태계 통합 |

---

## 17. 마치며

이 프로젝트를 통해 배운 것들을 정리하면:

**기술적으로 배운 것:**
- "프로덕션급"이란 도구를 많이 넣는 게 아니라, **의존성을 관리하고 장애에 대비하는 것**이라는 걸 체감했습니다
- CNCF 생태계는 잘 조합하면 강력하지만, 조합의 순서와 호환성을 맞추는 데 가장 많은 시간이 들었습니다
- eBPF 기반 도구들(Cilium, Tetragon)이 전통적인 방식(iptables, syscall hooking)을 얼마나 효율적으로 대체하는지 직접 확인할 수 있었습니다

**설계 관점에서 배운 것:**
- 로컬 환경의 제약은 오히려 **좋은 설계를 강제**했습니다. 리소스가 넉넉했다면 27개 Addon을 모두 띄우고 끝냈을 텐데, 제약 때문에 "정말 필요한가?"를 매번 질문하게 되었습니다
- 자동화는 "한 번에 완성"이 아니라, **실패 → 원인 분석 → 순서 조정 → 재시도**의 반복이었습니다
- 문서화는 "나중에 하는 것"이 아니라, 코드를 읽으며 버그를 찾는 **디버깅 도구**이기도 했습니다

**이 구조가 적합한 경우:**
- K8s 플랫폼 엔지니어링을 학습하고 싶은 분
- 클라우드 비용 없이 CNCF 도구들을 직접 경험해보고 싶은 분
- 온프레미스 K8s PoC를 준비하는 팀

전체 코드는 GitHub에 공개되어 있습니다: <!-- TODO: GitHub 저장소 URL -->

---

## 참고 자료

| 프로젝트 | 공식 문서 | GitHub |
|---------|----------|--------|
| Kubernetes | https://kubernetes.io/docs/ | [kubernetes/kubernetes](https://github.com/kubernetes/kubernetes) |
| Cilium | https://docs.cilium.io/ | [cilium/cilium](https://github.com/cilium/cilium) |
| Istio | https://istio.io/latest/docs/ | [istio/istio](https://github.com/istio/istio) |
| Prometheus | https://prometheus.io/docs/ | [prometheus/prometheus](https://github.com/prometheus/prometheus) |
| Thanos | https://thanos.io/ | [thanos-io/thanos](https://github.com/thanos-io/thanos) |
| Grafana | https://grafana.com/docs/grafana/latest/ | [grafana/grafana](https://github.com/grafana/grafana) |
| Loki | https://grafana.com/docs/loki/latest/ | [grafana/loki](https://github.com/grafana/loki) |
| Tempo | https://grafana.com/docs/tempo/latest/ | [grafana/tempo](https://github.com/grafana/tempo) |
| Alloy | https://grafana.com/docs/alloy/latest/ | [grafana/alloy](https://github.com/grafana/alloy) |
| Kiali | https://kiali.io/docs/ | [kiali/kiali](https://github.com/kiali/kiali) |
| Vault | https://developer.hashicorp.com/vault/docs | [hashicorp/vault](https://github.com/hashicorp/vault) |
| External Secrets | https://external-secrets.io/ | [external-secrets/external-secrets](https://github.com/external-secrets/external-secrets) |
| cert-manager | https://cert-manager.io/docs/ | [cert-manager/cert-manager](https://github.com/cert-manager/cert-manager) |
| ArgoCD | https://argo-cd.readthedocs.io/ | [argoproj/argo-cd](https://github.com/argoproj/argo-cd) |
| Velero | https://velero.io/docs/ | [vmware-tanzu/velero](https://github.com/vmware-tanzu/velero) |
| MinIO | https://min.io/docs/ | [minio/minio](https://github.com/minio/minio) |
| Kyverno | https://kyverno.io/docs/ | [kyverno/kyverno](https://github.com/kyverno/kyverno) |
| Falco | https://falco.org/docs/ | [falcosecurity/falco](https://github.com/falcosecurity/falco) |
| Tetragon | https://tetragon.io/docs/ | [cilium/tetragon](https://github.com/cilium/tetragon) |
| MetalLB | https://metallb.universe.tf/ | [metallb/metallb](https://github.com/metallb/metallb) |
| Gateway API | https://gateway-api.sigs.k8s.io/ | [kubernetes-sigs/gateway-api](https://github.com/kubernetes-sigs/gateway-api) |
| OpenTofu | https://opentofu.org/docs/ | [opentofu/opentofu](https://github.com/opentofu/opentofu) |
| Multipass | https://multipass.run/docs | [canonical/multipass](https://github.com/canonical/multipass) |
| Local Path Provisioner | - | [rancher/local-path-provisioner](https://github.com/rancher/local-path-provisioner) |

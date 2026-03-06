# TODO: 문제 및 작업 리스트

## 1. 스크립트 버그 (수정 완료, 미커밋)

아래 스크립트들은 버그를 발견하고 수정했지만 아직 커밋되지 않았다.

### install-metallb.sh — 4건 수정
- [x] GitHub raw URL에 `v` prefix 누락 → 404
- [x] `constants.sh` 미 source → `TIMEOUT_POD_READY` unbound
- [x] speaker pod label selector 불일치 (`app.kubernetes.io/component=speaker` → `component=speaker`)
- [x] webhook 서비스 준비 전 CRD 적용 → 실패. sleep 10 추가

### install-cert-manager.sh — 2건 수정
- [x] v1.17.1에서 `priorityClassName` 위치 변경 → `global.priorityClassName` 사용
- [x] ServiceMonitor CRD 미존재 (prometheus-stack 미설치) → `prometheus.enabled=false`

### install-eso.sh — 3건 수정
- [x] ServiceMonitor CRD 미존재 → `prometheus.enabled=false`
- [x] ClusterSecretStore에 유효하지 않은 `conditions` 필드 제거
- [x] `refreshInterval` 타입 오류 (string → integer)

### install-falco.sh — 2건 수정
- [x] kernel module 드라이버 → `modern_ebpf` (VM에 커널 소스 없음)
- [x] ServiceMonitor CRD 미존재 → `serviceMonitor.enabled=false`

### install-thanos.sh — 3건 수정
- [x] bitnami 이미지 삭제됨 → `quay.io/thanos/thanos:v0.37.2` 오버라이드
- [x] bitnami 이미지 검증 우회 → `global.security.allowInsecureImages=true`
- [x] `objstoreConfig` 파라미터명 → `existingObjstoreSecret`

### install-tempo.sh — 2건 수정
- [x] 기본 버전이 app 버전(2.6.1)이었음 → chart 버전(1.24.4)으로 수정
- [x] `--set tempo.tag` 제거 (chart 버전을 image tag로 잘못 사용)

### install-opensearch.sh — 2건 수정
- [x] 복잡한 config YAML string → 개별 `--set` 파라미터로 분리
- [x] `extraEnvs[0]` discovery.type 중복 제거

### install-velero.sh — 2건 수정
- [x] bitnami kubectl 이미지 삭제됨 → `alpine/k8s:1.35.2` 사용
- [x] ServiceMonitor CRD 미존재 → `metrics.serviceMonitor.enabled=false`

### install-minio.sh — 재작성 완료
- [x] bitnami chart → minio-official/minio chart v5.4.0으로 재작성

---

## 2. bitnami Docker Hub 이미지 전면 삭제 문제

Docker Hub의 `bitnami/*` 이미지가 전면 삭제됨. 영향받는 차트:

| 차트 | 영향 | 우회 방법 | 상태 |
|------|------|----------|------|
| MinIO (bitnami/minio) | 이미지 pull 실패 | minio-official/minio chart 사용 | 수정 완료 |
| Thanos (bitnami/thanos) | 이미지 pull 실패 | quay.io/thanos/thanos 이미지 오버라이드 | 수정 완료 |
| Velero (kubectl init) | bitnami/kubectl pull 실패 | alpine/k8s 이미지로 교체 | 수정 완료 |

---

## 3. 리소스 부족 (mgmt-worker-0 CPU 97%)

- [x] mgmt-worker-0 CPU 스펙 증가: 2 core → 3 core (`locals.tf`)

---

## 4. 미설치 Addon 목록

### 설치 실패 (재시도 필요)
| Addon | 실패 원인 | 조치 |
|-------|----------|------|
| velero | CRD job의 kubectl 이미지 문제 | `alpine/k8s` 이미지로 교체 완료, 재시도 필요 |

### 별도 VM 구축 예정
| Addon | 비고 |
|-------|------|
| opensearch | 별도 VM에 구축 (Harbor/Nexus와 동일 패턴). 감사/보안 로그 분석 전용 |

### 미착수
| Addon | 비고 |
|-------|------|
| clustermesh | Cilium 클러스터 메시 (멀티클러스터 네트워킹) |
| platform-addons | local-path-retain StorageClass 등 플랫폼 기본 설정 |
| prometheus-agent | app 클러스터 → mgmt Thanos remote_write |
| istio | 서비스 메시 — 리소스 소비 큼, Ambient mode 검토 |
| kiali | Istio 대시보드 — Istio 의존 |
| k8sgpt | AI 기반 K8s 진단 |
| holmesgpt | AI 기반 장애 분석 |
| botkube | ChatOps (Slack/Teams 연동) |

---

## 5. 인프라 레벨 이슈

### local-path-provisioner
- [x] 설치 스크립트 작성 완료 (`install-local-path-provisioner.sh`)
- [x] `addons/install.sh` 설치 순서에 추가 완료 (priority-classes 다음)
- [x] privileged PSA 라벨 자동 설정 (스크립트 내 `ensure_namespace_privileged` 사용)

### PSA (Pod Security Admission) 자동화
- [x] `ensure_namespace()`에 `is_privileged_namespace()` 자동 체크 통합 완료
- [x] `is_privileged_namespace()`에 backup, security, local-path-storage 추가 완료
- 별도 수동 PSA 설정 불필요

### Vault 초기화
- 수동 unseal/init 필요 (자동화 스크립트 있지만 첫 실행 시 수동 개입)

---

## 6. 코드 품질 / 기술 부채

- [ ] `addons/install.sh` — bash 4+ 필수 (`declare -A`). macOS 기본 bash 3.2와 비호환
- [ ] ServiceMonitor 활성화 — prometheus-stack 설치 이후 cert-manager, ESO, Falco 등에서 재활성화
- [ ] Helm chart 버전 고정 — 일부 차트가 버전 미지정 (latest 사용)
- [x] `scripts/lib/common.sh` — 레거시 함수 `kubectl_ctx()`, `helm_ctx()` 이미 제거됨

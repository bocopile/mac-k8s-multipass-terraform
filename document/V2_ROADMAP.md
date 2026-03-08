# v2.0 로드맵: OpenTofu + Ansible + Helmfile 전환

> **버전**: 1.0.0
> **작성일**: 2026-03-08
> **현재 버전**: v1.0 (OpenTofu + cloud-init + Shell Script)
> **목표 버전**: v2.0 (OpenTofu + Ansible + Helmfile)

---

## 목차

0. [v1.0 즉시 보완 필요 사항](#0-v10-즉시-보완-필요-사항-v20-전환-전-선행-작업)
1. [현재 아키텍처 (v1.0) 요약](#1-현재-아키텍처-v10-요약)
2. [v1.0의 한계점](#2-v10의-한계점)
3. [v2.0 목표 아키텍처](#3-v20-목표-아키텍처)
4. [작업 항목](#4-작업-항목)
5. [마이그레이션 전략](#5-마이그레이션-전략)
6. [디렉토리 구조 (v2.0)](#6-디렉토리-구조-v20)
7. [의존성 그래프](#7-의존성-그래프)
8. [리스크 및 고려사항](#8-리스크-및-고려사항)
9. [CI/품질 게이트](#9-ci품질-게이트-v20-추가-권장)

---

## 0. v1.0 즉시 보완 필요 사항 (v2.0 전환 전 선행 작업)

> v2.0과 무관하게 현재 코드의 버그/리스크를 먼저 수정해야 합니다.

### 0.1 INSTALL_ORDER 누락 버그

`install.sh`의 카테고리에는 `prometheus-agent`, `otel-collector`가 정의되어 있으나 `INSTALL_ORDER` 배열에 누락:

```
# install.sh:18 — 카테고리 정의에는 있음
observability) echo "thanos prometheus-stack prometheus-agent loki tempo alloy otel-collector" ;;

# install.sh:61 — INSTALL_ORDER에는 prometheus-agent, otel-collector 없음
```

- **영향**: `--all` 또는 `--category observability` 실행 시 `prometheus-agent`, `otel-collector`가 설치되지 않음
- **수정**: INSTALL_ORDER에 `prometheus-agent`, `otel-collector` 추가

### 0.2 app2 드리프트

app2 클러스터가 `locals.tf:45`에서 제거되었으나, 아래 파일들에 app2 참조가 남아있음:

| 파일 | 라인 | 내용 |
|------|------|------|
| `README.md` | :30, :46, :54-55, :121, :161, :328, :368-371 | 클러스터 구성도, 노드 스펙, 접속 명령어, 정지/시작 |
| `main.tf` | :331-340 | kubeconfig 정리 시 `app2` 패턴 포함 (동작에는 무해하나 혼동) |

- **수정**: README.md에서 app2 참조 전면 제거, main.tf는 패턴 매칭이라 무해하지만 정리 권장

### 0.3 verify.sh bash 호환성

`addons/verify.sh:17`에서 `declare -A` (연관 배열)를 사용하고 있으나, macOS 기본 bash는 3.2로 연관 배열 미지원:

```bash
declare -A ADDON_CHECK=(  # bash 4.0+ 필요
```

- **영향**: macOS에서 `/bin/bash`로 실행 시 syntax error
- **현재 회피**: shebang이 `#!/bin/bash`이고 Homebrew bash 4+가 PATH에 있으면 동작
- **수정**: shebang을 `#!/usr/bin/env bash`로 변경하거나, 연관 배열 제거 (install.sh처럼 case문 사용)

---

## 1. 현재 아키텍처 (v1.0) 요약

### 워크플로우

```
OpenTofu (main.tf)
  → Multipass VM 4대 생성 (mgmt-cp, mgmt-worker-0, app1-cp, app1-worker-0)
    → cloud-init (containerd, kubelet, kubeadm 설치)
      → scripts/cluster-init.sh (kubeadm init + join)
        → addons/install.sh (쉘 스크립트 26개로 addon 설치)
```

### 기술 스택

| 계층 | 도구 | 비고 |
|------|------|------|
| VM 프로비저닝 | OpenTofu + Multipass | locals.tf에 클러스터 정의 |
| OS 초기화 | cloud-init | 패키지, containerd, kubeadm 설치 |
| K8s 클러스터 | kubeadm init/join | scripts/cluster-init.sh |
| Addon 설치 | Shell Script 26개 | addons/install.sh 오케스트레이터 |
| 공통 라이브러리 | common.sh, constants.sh, credentials.sh | scripts/lib/ |

### 클러스터 구성

| 클러스터 | 노드 | 리소스 | 역할 |
|---------|------|--------|------|
| mgmt | mgmt-cp (2C/4G), mgmt-worker-0 (4C/12G) | 플랫폼 서비스 집중 | Vault, ArgoCD, Prometheus, Thanos, Loki, Tempo, MinIO |
| app1 | app1-cp (2C/3G), app1-worker-0 (2C/4G) | 워크로드 클러스터 | Kyverno, Falco, Prometheus Agent, Alloy |

### Addon 설치 현황 (26개, 7개 카테고리)

| 카테고리 | Addon | 설치 방식 |
|---------|-------|----------|
| **infrastructure** | priority-classes | kubectl apply (인라인 YAML) |
| | local-path-provisioner | kubectl apply (원격 manifest) |
| | cilium | cilium CLI |
| | tetragon | Helm |
| | metallb | kubectl apply (manifest) + CRD |
| | gateway-api | kubectl apply (CRD) + cilium upgrade |
| | cert-manager | Helm + kubectl apply (ClusterIssuer) |
| | clustermesh | cilium CLI |
| **secrets** | vault | Helm + kubectl exec (init/unseal) |
| | vault-pki | kubectl exec (vault CLI) |
| | eso | Helm + kubectl apply (ClusterSecretStore) |
| **gitops** | argocd | Helm + kubectl apply (PDB) + argocd CLI |
| **observability** | prometheus-stack | Helm + kubectl apply (ConfigMap datasource) |
| | prometheus-agent | Helm |
| | thanos | Helm + kubectl create secret |
| | loki | Helm + kubectl apply (LB Service, datasource) |
| | tempo | Helm + kubectl apply (datasource) |
| | alloy | Helm |
| | otel-collector | Helm |
| **servicemesh** | istio | istioctl (IstioOperator) |
| | kiali | Helm |
| **security** | kyverno | Helm + kubectl apply (4 ClusterPolicy) |
| | falco | Helm |
| **backup** | minio | Helm |
| | velero | Helm + kubectl create secret + velero CLI |

---

## 2. v1.0의 한계점

### 2.1 cloud-init 1회성 실행

- cloud-init은 VM 최초 부팅 시만 실행됨
- OS 패키지 업데이트, kubeadm 설정 변경 후 재적용 불가
- 변경 시 VM destroy → recreate 필요

### 2.2 멱등성 부족

- 각 쉘 스크립트가 `if ! kubectl get ...` 같은 수동 멱등성 체크를 개별 구현
- 일관된 패턴 없음 (일부는 체크, 일부는 무조건 실행)
- 중간 실패 후 재실행 시 예측 불가능한 결과

### 2.3 에러 복구 어려움

- 실패 시 어디서부터 재시작할지 불명확
- `install.sh`는 순차 실행만 지원 (부분 재실행은 개별 addon 지정 필요)
- 재시도 로직 없음

### 2.4 generated/ 파일 산재

- IP 주소, 토큰, 자격증명이 여러 파일로 분산:
  ```
  generated/vault-lb-ip
  generated/vault-root-token
  generated/vault-init.json
  generated/minio-ip
  generated/thanos-receive-ip
  generated/loki-lb-ip
  generated/.credentials.env
  ```
- 스크립트 간 파일 의존성이 암묵적

### 2.5 하드코딩된 값

- 도메인 (`bocopile.io`), 타임아웃, 리소스 프로필이 constants.sh에 고정
- 환경별 (dev/staging/prod) 오버라이드 불가
- 프로필 기반 리소스 선택 불가

### 2.6 CLI 도구 의존성 과다

현재 7개 외부 CLI 필요:
```
kubectl, helm, jq, cilium, istioctl, velero, argocd
```

### 2.7 병렬 설치 미활용

- 모든 addon이 순차 설치
- 독립적인 addon (cert-manager ∥ metallb, loki ∥ tempo 등)도 직렬 실행
- 전체 설치 시간 불필요하게 길어짐

### 2.8 `multipass exec` 원격 실행 한계

- `multipass exec`는 SSH 대비 기능 제한적 (파일 전송, 조건부 실행 등)
- 에러 핸들링이 단순 (`$?` 체크만)

---

## 3. v2.0 목표 아키텍처

### 3.1 워크플로우

```
OpenTofu (main.tf)
  → Multipass VM 4대 생성 (동일)
    → Ansible
      ├── Phase 1: OS 초기화 (cloud-init 대체)
      │   └── role: common (containerd, kubelet, kubeadm)
      ├── Phase 2: K8s 클러스터 구성
      │   ├── role: kubeadm-cp (kubeadm init)
      │   └── role: kubeadm-worker (kubeadm join)
      └── Phase 3: Addon 설치
          └── Helmfile (선언적 Helm 릴리스 관리)
              └── hooks/ (비-Helm 작업: vault init, CRD apply 등)
```

### 3.2 도구별 역할 분담

| 도구 | 역할 | 대체 대상 (v1.0) |
|------|------|-----------------|
| **OpenTofu** | VM 생성, 네트워크 설정 | 동일 (변경 없음) |
| **Ansible** | OS 설정, kubeadm, addon 오케스트레이션 | cloud-init + cluster-init.sh + install.sh |
| **Helmfile** | Helm 릴리스 선언적 관리 | 개별 `helm install` 호출 (22개) |
| **Helm** | 차트 설치 (Helmfile이 호출) | 동일 |
| **kubectl** | CRD, Policy 등 비-Helm 리소스 | 동일 (축소) |

### 3.3 v1.0 → v2.0 비교

| 항목 | v1.0 | v2.0 |
|------|------|------|
| OS 초기화 | cloud-init (1회성) | Ansible role (재실행 가능) |
| K8s 클러스터 | cluster-init.sh | Ansible role (멱등성 내장) |
| Addon 오케스트레이션 | install.sh + 26개 스크립트 | Ansible playbook + Helmfile |
| Helm 릴리스 관리 | 개별 `helm install` 스크립트 | Helmfile 선언적 정의 |
| 비-Helm 작업 | 각 스크립트에 인라인 | Helmfile hooks + Ansible tasks |
| 변수 관리 | constants.sh + generated/ 파일 | Ansible group_vars + Helmfile environments |
| 자격증명 관리 | credentials.sh + .credentials.env | Ansible vault (암호화) |
| 원격 실행 | `multipass exec` | SSH (Ansible 네이티브) |
| 부분 재실행 | 개별 addon 지정 | `--tags`, `--start-at-task` |
| 병렬 실행 | 불가 | Helmfile `needs` 기반 자동 병렬 |
| 멱등성 | 수동 체크 (불일관) | Ansible 모듈 + Helm 내장 |
| 환경 분리 | 불가 | Helmfile environments + Ansible group_vars |

---

## 4. 작업 항목

### Phase 1: 기반 구축

#### 1.1 Ansible 프로젝트 초기화

- [ ] `ansible/` 디렉토리 구조 생성
- [ ] `ansible.cfg` 작성 (SSH 설정, inventory 경로)
- [ ] Multipass VM SSH 접근 설정 (SSH key 기반)
- [ ] `requirements.yml` 작성 (Ansible Galaxy 의존성)

#### 1.2 동적 Inventory 구성

- [ ] OpenTofu output → Ansible inventory 변환 스크립트 작성
- [ ] `inventory/hosts.yml` 동적 생성 (클러스터별 그룹: `mgmt`, `app1`)
- [ ] 또는 `inventory/multipass.py` 동적 inventory 플러그인 작성
- [ ] 연결 테스트 (`ansible all -m ping`)

#### 1.3 변수 체계 설계

- [ ] `group_vars/all.yml` — 공통 변수 (도메인, Helm repo URL, 타임아웃)
- [ ] `group_vars/mgmt.yml` — mgmt 클러스터 전용 (관찰성, 백업 addon 목록)
- [ ] `group_vars/app1.yml` — app1 클러스터 전용 (보안 정책, Prometheus agent)
- [ ] constants.sh의 모든 상수를 Ansible 변수로 마이그레이션
- [ ] 자격증명 → Ansible Vault로 암호화 관리

---

### Phase 2: OS 초기화 Role (cloud-init 대체)

#### 2.1 role: common

현재 cloud-init이 하는 작업을 Ansible role로 전환:

- [ ] 시스템 패키지 설치 (apt: containerd, kubelet, kubeadm, kubectl)
- [ ] containerd 설정 (`/etc/containerd/config.toml`)
- [ ] kubelet 설정 (`/var/lib/kubelet/config.yaml`)
- [ ] 커널 모듈 로드 (`br_netfilter`, `overlay`)
- [ ] sysctl 설정 (`net.bridge.bridge-nf-call-iptables` 등)
- [ ] swap 비활성화
- [ ] kubeadm 설정 파일 생성 (`kubeadm-config.yaml`)
- [ ] handler: containerd, kubelet 재시작

---

### Phase 3: K8s 클러스터 Role (cluster-init.sh 대체)

#### 3.1 role: kubeadm-cp (Control Plane)

- [ ] `kubeadm init --config` 실행 (멱등성: `/etc/kubernetes/admin.conf` 존재 여부 체크)
- [ ] kubeconfig 복사 (`/home/ubuntu/.kube/config`)
- [ ] join token 생성 및 fact 등록 (`set_fact`)
- [ ] kubeconfig 로컬 머신으로 fetch

#### 3.2 role: kubeadm-worker (Worker Node)

- [ ] `kubeadm join` 실행 (멱등성: `/etc/kubernetes/kubelet.conf` 존재 여부 체크)
- [ ] CP의 join command를 변수로 수신 (hostvars 참조)

#### 3.3 role: kubeconfig-merge

- [ ] 현재 `scripts/merge-kubeconfigs.sh` 대체
- [ ] 로컬 `~/.kube/config`에 멀티클러스터 kubeconfig 병합
- [ ] context 이름 규칙: `kubernetes-admin@{cluster-name}`

---

### Phase 4: Helmfile 구성 (addon 쉘 스크립트 대체)

#### 4.1 Helmfile 초기화

- [ ] `helmfile.yaml` (메인 파일) 작성
- [ ] `environments/default.yaml` — 공통 values (도메인, 리소스 프로필)
- [ ] `environments/dev.yaml` — 개발 환경 오버라이드

#### 4.2 Infrastructure 릴리스

| Addon | Helmfile 전환 | 추가 작업 (hooks) |
|-------|-------------|------------------|
| priority-classes | ❌ Helm chart 아님 | Ansible task로 `kubectl apply` |
| local-path-provisioner | ❌ 원격 manifest | Ansible task로 `kubectl apply` |
| cilium | ✅ 공식 Helm chart로 전환 (cilium CLI 제거) | — |
| tetragon | ✅ Helmfile 릴리스 | — |
| metallb | ✅ 공식 Helm chart로 전환 | postsync hook: IPAddressPool CRD |
| gateway-api | ❌ CRD manifest | Ansible task + cilium values 업데이트 |
| cert-manager | ✅ Helmfile 릴리스 | postsync hook: ClusterIssuer 생성 |
| clustermesh | ❌ cilium CLI | Ansible task (cilium Helm values로 대체 검토) |

작업 목록:
- [ ] cilium Helm chart 전환 (cilium CLI 제거, `values/cilium.yaml` 확장)
- [ ] metallb Helm chart 전환 + IPAddressPool/L2Advertisement hook
- [ ] cert-manager Helmfile 릴리스 + ClusterIssuer postsync hook
- [ ] tetragon Helmfile 릴리스
- [ ] priority-classes → Ansible task
- [ ] local-path-provisioner → Ansible task
- [ ] gateway-api CRD → Ansible task
- [ ] clustermesh → Ansible task 또는 cilium Helm values

#### 4.3 Secrets 릴리스

| Addon | Helmfile 전환 | 추가 작업 |
|-------|-------------|----------|
| vault | ✅ Helmfile 릴리스 | postsync: Ansible task (operator init/unseal, KV enable) |
| vault-pki | ❌ kubectl exec | Ansible task (vault CLI 명령어) |
| eso | ✅ Helmfile 릴리스 | postsync hook: ClusterSecretStore + Vault 토큰 Secret 자동 생성 |

작업 목록:
- [ ] vault Helmfile 릴리스 + Ansible task (init/unseal/KV enable)
- [ ] vault-pki → Ansible task
- [ ] eso Helmfile 릴리스 + ClusterSecretStore hook
- [ ] Vault 토큰 Secret 자동 생성 (현재 수동)

#### 4.4 GitOps 릴리스

| Addon | Helmfile 전환 | 추가 작업 |
|-------|-------------|----------|
| argocd | ✅ Helmfile 릴리스 | postsync: app1 클러스터 등록 (Ansible task) |

작업 목록:
- [ ] argocd Helmfile 릴리스
- [ ] PDB 생성 → Helm values로 통합 (별도 kubectl apply 제거)
- [ ] app1 클러스터 등록 → Ansible task (argocd CLI 또는 Secret 기반)

#### 4.5 Observability 릴리스

| Addon | Helmfile 전환 | 추가 작업 |
|-------|-------------|----------|
| prometheus-stack | ✅ Helmfile 릴리스 | postsync hook: Grafana datasource ConfigMap |
| prometheus-agent | ✅ Helmfile 릴리스 | Thanos Receive IP를 Ansible fact로 주입 |
| thanos | ✅ Helmfile 릴리스 | presync hook: MinIO objstore Secret |
| loki | ✅ Helmfile 릴리스 | postsync hook: LB Service + Grafana datasource |
| tempo | ✅ Helmfile 릴리스 | postsync hook: Grafana datasource |
| alloy | ✅ Helmfile 릴리스 | — |
| otel-collector | ✅ Helmfile 릴리스 | — |

작업 목록:
- [ ] prometheus-stack Helmfile 릴리스 (mgmt 전용)
- [ ] prometheus-agent Helmfile 릴리스 (app 클러스터 전용)
- [ ] thanos Helmfile 릴리스 + objstore Secret hook
- [ ] loki Helmfile 릴리스 + LB Service/datasource hook
- [ ] tempo Helmfile 릴리스 + datasource hook
- [ ] alloy Helmfile 릴리스
- [ ] otel-collector Helmfile 릴리스
- [ ] Grafana datasource들을 Helm values `sidecar.datasources`로 통합 검토
- [ ] generated/ IP 파일 → Ansible fact 또는 Helmfile 변수로 통합

#### 4.6 Service Mesh 릴리스

| Addon | Helmfile 전환 | 추가 작업 |
|-------|-------------|----------|
| istio | ✅ 공식 Helm chart로 전환 (istioctl 제거) | 클러스터별 values 분리 (mTLS mode 등) |
| kiali | ✅ Helmfile 릴리스 | — |

작업 목록:
- [ ] istio Helm 기반 설치로 전환 (istioctl 제거)
  - `istio/base` + `istio/istiod` + `istio/gateway` 3개 chart
  - mgmt: sidecar 비활성화, PERMISSIVE mTLS
  - app1: sidecar 활성화, STRICT mTLS
- [ ] kiali Helmfile 릴리스
- [ ] IstioOperator YAML 생성 → Helm values로 통합

#### 4.7 Security 릴리스

| Addon | Helmfile 전환 | 추가 작업 |
|-------|-------------|----------|
| kyverno | ✅ Helmfile 릴리스 | postsync hook: 4개 ClusterPolicy |
| falco | ✅ Helmfile 릴리스 | — |

작업 목록:
- [ ] kyverno Helmfile 릴리스 (app1 전용) + ClusterPolicy hook
- [ ] falco Helmfile 릴리스 (app1 전용)
- [ ] ClusterPolicy들을 별도 YAML 파일로 관리 (`policies/`)

#### 4.8 Backup 릴리스

| Addon | Helmfile 전환 | 추가 작업 |
|-------|-------------|----------|
| minio | ✅ Helmfile 릴리스 | — |
| velero | ✅ Helmfile 릴리스 | presync: S3 자격증명 Secret, postsync: backup schedule |

작업 목록:
- [ ] minio Helmfile 릴리스
- [ ] velero Helmfile 릴리스 + S3 Secret hook + schedule 생성
- [ ] 자격증명 관리를 Ansible Vault로 통합

---

### Phase 5: 통합 및 CLI 의존성 제거

#### 5.1 CLI 도구 의존성 정리

| CLI | v1.0 | v2.0 | 비고 |
|-----|------|------|------|
| kubectl | 필수 | 필수 | 유지 |
| helm | 필수 | 필수 | Helmfile이 내부 호출 |
| helmfile | 없음 | **신규** | Addon 오케스트레이션 |
| ansible | 없음 | **신규** | OS/K8s/Addon 오케스트레이션 |
| jq | 필수 | 선택 | Ansible에서 json_query로 대체 가능 |
| cilium | 필수 | **제거** | Helm chart로 전환 |
| istioctl | 필수 | **제거** | Helm chart로 전환 |
| velero | 필수 | **제거 검토** | backup schedule을 CRD로 관리 가능 |
| argocd | 선택 | **제거 검토** | 클러스터 등록을 Secret 기반으로 전환 |

#### 5.2 OpenTofu → Ansible 연결

- [ ] OpenTofu `local-exec` provisioner로 Ansible playbook 자동 실행
- [ ] 또는 `terraform_data` 리소스로 트리거
- [ ] OpenTofu output → Ansible inventory 자동 변환

#### 5.3 generated/ 파일 통합

현재 산재된 파일들을 Ansible fact으로 통합:

```
# v1.0 (파일 기반)
generated/vault-lb-ip          → ansible fact: vault_lb_ip
generated/vault-root-token     → ansible vault 암호화
generated/minio-ip             → ansible fact: minio_ip
generated/thanos-receive-ip    → ansible fact: thanos_receive_ip
generated/loki-lb-ip           → ansible fact: loki_lb_ip
generated/.credentials.env     → ansible vault 암호화
```

- [ ] Ansible fact 캐싱 설정 (`fact_caching = jsonfile`)
- [ ] 민감 정보 Ansible Vault 암호화
- [ ] Helmfile에서 환경변수로 참조 (`{{ requiredEnv "VAULT_LB_IP" }}`)

#### 5.4 스크립트 라이브러리 마이그레이션

| v1.0 파일 | v2.0 대체 |
|-----------|----------|
| `scripts/lib/common.sh` | Ansible modules (`k8s`, `helm`, `wait_for`) |
| `scripts/lib/constants.sh` | `group_vars/all.yml` |
| `scripts/lib/credentials.sh` | Ansible Vault + `password_lookup` |
| `scripts/cluster-init.sh` | `roles/kubeadm-cp/`, `roles/kubeadm-worker/` |
| `scripts/merge-kubeconfigs.sh` | `roles/kubeconfig-merge/` |
| `addons/install.sh` | `playbooks/addons.yml` + Helmfile |
| `addons/uninstall.sh` | `playbooks/teardown.yml` + `helmfile destroy` |
| `addons/verify.sh` | `playbooks/verify.yml` |

---

### Phase 6: 운영 기능 강화

#### 6.1 부분 재실행 지원

```bash
# 카테고리별 실행
ansible-playbook playbooks/addons.yml --tags observability

# 특정 addon만
ansible-playbook playbooks/addons.yml --tags vault

# K8s 클러스터만 재구성
ansible-playbook playbooks/cluster.yml

# 전체 (VM 생성 제외)
ansible-playbook playbooks/site.yml
```

- [ ] 모든 role/task에 tag 체계 설계
- [ ] tag 계층: `infrastructure`, `secrets`, `gitops`, `observability`, `servicemesh`, `security`, `backup`
- [ ] addon 레벨 tag: `vault`, `argocd`, `prometheus`, `istio` 등

#### 6.2 Helmfile 환경 분리

```yaml
# helmfile.yaml
environments:
  default:
    values:
      - environments/default.yaml
  dev:
    values:
      - environments/default.yaml
      - environments/dev.yaml    # 리소스 축소, 레플리카 1 등

# 실행
helmfile -e dev apply
```

- [ ] `environments/default.yaml` — 공통 (도메인, repo URL)
- [ ] `environments/dev.yaml` — 개발 환경 (리소스 축소, retention 단축)
- [ ] 향후 `environments/prod.yaml` 추가 가능

#### 6.3 검증 자동화

- [ ] Ansible playbook: `playbooks/verify.yml` (현재 `addons/verify.sh` 대체)
- [ ] Helmfile: `helmfile status` / `helmfile diff`
- [ ] Smoke test role: 각 addon health check

#### 6.4 Uninstall/Teardown

- [ ] `playbooks/teardown.yml` — addon 역순 제거
- [ ] `helmfile destroy` — Helm 릴리스 일괄 삭제
- [ ] `playbooks/destroy.yml` — K8s 클러스터 + VM 정리

---

## 5. 마이그레이션 전략

### 단계적 전환 (Big Bang 아님)

v1.0과 v2.0을 병행하면서 단계적으로 전환:

```
Step 1: Ansible 기반 + 기존 쉘 스크립트 호출
  → Ansible에서 기존 install-*.sh를 shell 모듈로 호출
  → 최소 변경으로 Ansible 프레임워크 검증

Step 2: Helmfile 도입 + Helm addon 전환
  → Helm으로 설치하는 22개 addon을 Helmfile로 전환
  → 기존 values/ 파일 재활용

Step 3: 비-Helm 작업 Ansible task 전환
  → kubectl apply, CLI 명령어를 Ansible task로 변환
  → cilium CLI → Helm, istioctl → Helm 전환

Step 4: cloud-init 최소화 + Ansible role 완성
  → cloud-init은 SSH 접근만 설정
  → OS 초기화, kubeadm 전체를 Ansible로
  → cluster-init.sh 제거

Step 5: generated/ 파일 정리 + 자격증명 Ansible Vault 전환
  → IP 파일 → Ansible fact
  → credentials.sh → Ansible Vault
  → constants.sh → group_vars/all.yml
```

### 롤백 전략

- v1.0 스크립트를 즉시 삭제하지 않음
- `scripts-v1/` 디렉토리로 이동하여 보존
- v2.0 안정화 후 최종 제거

---

## 6. 디렉토리 구조 (v2.0)

```
mac-k8s-multipass-terraform/
├── main.tf                          # VM 프로비저닝 (변경 최소화)
├── locals.tf                        # 클러스터 정의 (동일)
├── variables.tf
├── outputs.tf
├── versions.tf
│
├── ansible/                         # [신규] Ansible 프로젝트
│   ├── ansible.cfg                  # Ansible 설정
│   ├── requirements.yml             # Galaxy 의존성
│   │
│   ├── inventory/
│   │   ├── hosts.yml                # 정적 inventory (또는 동적)
│   │   └── multipass_inventory.py   # 동적 inventory 플러그인
│   │
│   ├── playbooks/
│   │   ├── site.yml                 # 전체 실행 (OS + K8s + Addon)
│   │   ├── cluster.yml              # K8s 클러스터만
│   │   ├── addons.yml               # Addon만 (Helmfile 호출)
│   │   ├── verify.yml               # 검증
│   │   └── teardown.yml             # 정리
│   │
│   ├── roles/
│   │   ├── common/                  # OS 초기화 (containerd, kubelet, kubeadm)
│   │   │   ├── tasks/main.yml
│   │   │   ├── handlers/main.yml
│   │   │   ├── templates/
│   │   │   └── defaults/main.yml
│   │   ├── kubeadm-cp/              # Control Plane 초기화
│   │   ├── kubeadm-worker/          # Worker Join
│   │   ├── kubeconfig-merge/        # kubeconfig 로컬 병합
│   │   ├── helmfile/                # Helmfile 실행 role
│   │   ├── vault-init/              # Vault 초기화 (init/unseal/PKI)
│   │   ├── clustermesh/             # Cilium ClusterMesh 설정
│   │   └── post-install/            # 검증, /etc/hosts 등
│   │
│   └── group_vars/
│       ├── all.yml                  # 공통 변수 (constants.sh 대체)
│       ├── mgmt.yml                 # mgmt 클러스터 변수
│       └── app1.yml                 # app1 클러스터 변수
│
├── helmfile/                        # [신규] Helmfile 프로젝트
│   ├── helmfile.yaml                # 메인 Helmfile
│   ├── environments/
│   │   ├── default.yaml             # 공통 환경 값
│   │   └── dev.yaml                 # 개발 환경 오버라이드
│   ├── releases/
│   │   ├── infrastructure.yaml      # cilium, metallb, cert-manager, tetragon
│   │   ├── secrets.yaml             # vault, eso
│   │   ├── gitops.yaml              # argocd
│   │   ├── observability.yaml       # prometheus, thanos, loki, tempo, alloy, otel
│   │   ├── servicemesh.yaml         # istio, kiali
│   │   ├── security.yaml            # kyverno, falco
│   │   └── backup.yaml              # minio, velero
│   ├── values/                      # 기존 addons/values/ 이동
│   │   ├── cilium.yaml
│   │   ├── cert-manager.yaml
│   │   ├── vault.yaml
│   │   ├── argocd.yaml
│   │   ├── prometheus-stack-mgmt.yaml
│   │   ├── prometheus-agent-app.yaml
│   │   └── ... (기존 20개 values 파일)
│   ├── hooks/                       # Helmfile hooks (비-Helm 작업)
│   │   ├── metallb-config.sh        # IPAddressPool CRD
│   │   ├── cert-issuer.sh           # ClusterIssuer
│   │   ├── eso-secretstore.sh       # ClusterSecretStore
│   │   ├── kyverno-policies.sh      # ClusterPolicy 4개
│   │   └── grafana-datasources.sh   # Grafana datasource ConfigMap
│   └── policies/                    # Kyverno ClusterPolicy YAML
│       ├── restrict-registries.yaml
│       ├── require-resource-limits.yaml
│       ├── disallow-privileged.yaml
│       └── require-labels.yaml
│
├── cloud-init/                      # 최소화 (SSH 접근만)
│   └── base.yaml                    # SSH key 설정 + 기본 패키지
│
├── scripts/                         # 축소 (유틸리티만 잔존)
│   ├── port-forward-all.sh
│   ├── show-loadbalancer-ips.sh
│   └── update-hosts-bocopile.sh
│
├── addons/                          # [v1.0 → 제거 예정]
│   ├── install.sh                   # → playbooks/addons.yml
│   ├── scripts/                     # → roles/ + helmfile/
│   └── values/                      # → helmfile/values/
│
└── document/
    ├── on-premise/ARCHITECTURE.md
    └── V2_ROADMAP.md                # 이 문서
```

---

## 7. 의존성 그래프

### Helmfile `needs` 의존성 (자동 병렬 실행)

```
                    ┌──────────────────┐
                    │ priority-classes │
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │  local-path-     │
                    │  provisioner     │
                    └────────┬─────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
     ┌────────▼───┐  ┌──────▼──────┐  ┌───▼────────┐
     │   cilium   │  │   metallb   │  │cert-manager│
     └──┬────┬────┘  └──────┬──────┘  └───┬────────┘
        │    │              │              │
        │    │         ┌────▼────┐    ┌───▼────────┐
        │    │         │  vault  │    │ vault-pki  │
        │    │         └────┬────┘    └────────────┘
        │    │              │
   ┌────▼┐ ┌▼────┐    ┌───▼──┐
   │mesh │ │gw-  │    │ eso  │
   │     │ │api  │    └───┬──┘
   └─────┘ └─────┘        │
                      ┌────▼────┐
                      │ argocd  │
                      └────┬────┘
                           │
        ┌───────┬──────────┼──────────┬────────┐
        │       │          │          │        │
   ┌────▼──┐ ┌─▼────┐ ┌───▼────┐ ┌──▼───┐ ┌──▼────┐
   │ minio │ │istio │ │prom-   │ │falco │ │kyverno│
   └───┬───┘ └──┬───┘ │stack   │ └──────┘ └───────┘
       │        │     └───┬────┘
  ┌────▼───┐ ┌──▼──┐     │
  │ velero │ │kiali│  ┌───▼───┬──────┬──────┐
  └────────┘ └─────┘  │      │      │      │
                  ┌────▼──┐┌─▼───┐┌─▼───┐┌─▼──────────┐
                  │thanos ││loki ││tempo ││otel-       │
                  └───┬───┘└──┬──┘└─────┘│collector   │
                      │       │          └────────────┘
                  ┌───▼───────▼───┐
                  │  alloy        │
                  └───┬───────────┘
                      │
                  ┌───▼──────────────┐
                  │ prometheus-agent │
                  │ (app 클러스터)     │
                  └──────────────────┘
```

### 병렬 실행 가능 그룹

```
Group 1 (독립):  cilium ∥ metallb ∥ cert-manager
Group 2 (독립):  vault ∥ gateway-api ∥ clustermesh
Group 3 (독립):  minio ∥ istio ∥ falco ∥ kyverno
Group 4 (독립):  loki ∥ tempo ∥ otel-collector
```

---

## 8. 리스크 및 고려사항

### 8.1 학습 곡선

| 도구 | 난이도 | 비고 |
|------|--------|------|
| Ansible 기본 | 중 | YAML + Jinja2 문법, module 이해 |
| Ansible Vault | 하 | 암호화/복호화 명령어 |
| Helmfile | 하 | Helm 경험 있으면 쉬움, `needs` 문법 |
| 동적 Inventory | 중 | Multipass → SSH → Ansible 연결 |

### 8.2 Multipass + SSH 설정

- Multipass VM은 기본적으로 `multipass exec`로 접근
- Ansible은 SSH 필요 → cloud-init에서 SSH key 주입 필수
- `multipass info --format json`으로 IP 조회 가능
- 동적 inventory에서 자동화 가능하지만 초기 설정 필요

### 8.3 전환 기간 복잡도

- v1.0과 v2.0 병행 기간 동안 두 가지 방식이 공존
- `addons/` (v1.0)과 `helmfile/` (v2.0) 디렉토리 공존
- 단계적 전환으로 리스크 최소화하되, 완료 후 v1.0 코드 정리 필요

### 8.4 테스트 전략

- 각 Phase 완료 후 `tofu destroy` → `tofu apply` → Ansible playbook 풀 테스트
- 기존 `addons/verify.sh`의 체크 항목을 Ansible verify playbook으로 포팅
- 개별 role 테스트: `ansible-playbook playbooks/addons.yml --tags vault`

### 8.5 유지보수 부담 변화

| 항목 | v1.0 | v2.0 |
|------|------|------|
| 새 addon 추가 | 스크립트 1개 작성 (~100줄) | Helmfile 릴리스 추가 (~10줄) + values 파일 |
| 버전 업그레이드 | 스크립트에서 버전 수정 | values 파일에서 버전 수정 |
| 환경 추가 | 불가 | environments/ 파일 추가 |
| 디버깅 | 스크립트 `set -x` | `ansible-playbook -vvv`, `helmfile diff` |
| 부분 재실행 | `install.sh vault argocd` | `--tags vault,argocd` |

---

## 9. CI/품질 게이트 (v2.0 추가 권장)

### 9.1 정적 분석 파이프라인

| 도구 | 대상 | 용도 |
|------|------|------|
| `ansible-lint` | Ansible playbooks/roles | best practice 검증, deprecated 모듈 감지 |
| `helm lint` | Helm values | 차트 렌더링 오류 사전 감지 |
| `helmfile diff` | Helmfile 릴리스 | 실제 변경 사항 사전 확인 (dry-run) |
| `shellcheck` | 잔존 쉘 스크립트 | 쉘 스크립트 품질 검증 |
| `tofu validate` | Terraform 코드 | HCL 문법 검증 |

- [ ] GitHub Actions 또는 pre-commit hook으로 최소 품질 게이트 구성
- [ ] PR 머지 전 lint 통과 필수화

### 9.2 Phase별 스모크 테스트

각 Phase 완료 후 자동 검증:

```yaml
# playbooks/verify.yml 예시
- name: Phase 1 - OS 검증
  tasks:
    - name: containerd 서비스 상태
      service_facts:
      assert:
        that: ansible_facts.services['containerd.service'].state == 'running'

- name: Phase 2 - K8s 검증
  tasks:
    - name: 노드 Ready 상태
      k8s_info:
        kind: Node
      assert:
        that: item.status.conditions | selectattr('type', 'eq', 'Ready') | map(attribute='status') | first == 'True'

- name: Phase 3 - Addon 검증
  tasks:
    - name: 각 addon deployment/statefulset Ready
      # helmfile status 또는 kubectl rollout status
```

- [ ] 실패 시 재시도 정책 표준화 (max_retries, delay, backoff)
- [ ] 스모크 테스트 결과를 Ansible callback으로 리포팅

### 9.3 Secret 관리 감사 체계

| 항목 | v1.0 | v2.0 |
|------|------|------|
| 저장 방식 | 평문 파일 (`generated/`) | Ansible Vault 암호화 |
| 접근 제어 | 파일 퍼미션 (chmod 600) | Vault 비밀번호 + 파일 퍼미션 |
| 변경 이력 | 없음 (git에서 제외) | `ansible-vault rekey` + git 커밋 이력 |
| 로테이션 | 수동 | Ansible task로 자동화 가능 |

- [ ] `ansible-vault encrypt` 기반 자격증명 파일 관리
- [ ] Vault root token, MinIO 자격증명 등 민감 정보 암호화
- [ ] 자격증명 변경 시 git diff에서 평문 노출 방지

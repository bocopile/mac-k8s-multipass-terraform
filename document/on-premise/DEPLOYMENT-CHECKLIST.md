# Deployment Checklist: 인프라 구축 전 과정 검증

`tofu init`부터 addon 설치 완료까지의 전체 체크리스트.
각 Phase가 완료되어야 다음 Phase로 진행한다.

---

## Phase 0: 사전 환경 (Host)

| # | 체크 항목 | 명령어 | 기대값 |
|---|----------|--------|--------|
| 0-1 | Multipass 설치 | `multipass version` | 1.15+ |
| 0-2 | OpenTofu 또는 Terraform | `tofu version` | 1.9+ |
| 0-3 | Helm CLI | `helm version --short` | 3.16+ |
| 0-4 | kubectl | `kubectl version --client` | v1.35+ |
| 0-5 | jq | `jq --version` | 1.7+ |
| 0-6 | RAM >= 24GB | `sysctl -n hw.memsize` | >= 25769803776 |
| 0-7 | Disk >= 270GB free | `df -g /` | Available >= 270 |
| 0-8 | Apple Silicon (arm64) | `uname -m` | arm64 |

```bash
bash scripts/check-prerequisites.sh
```

---

## Phase 1: IaC — VM 프로비저닝

| # | 체크 항목 | 명령어 | 기대값 |
|---|----------|--------|--------|
| 1-1 | tofu init 성공 | `tofu init` | Initialized successfully |
| 1-2 | tofu plan 오류 없음 | `tofu plan` | Plan: 6 to add (VM 6개) |
| 1-3 | tofu apply 완료 | `tofu apply -auto-approve` | Apply complete |
| 1-4 | VM 6개 Running | `multipass list` | 6 Running (mgmt-cp, mgmt-worker-0, app1-cp, app1-worker-0, app2-cp, app2-worker-0) |
| 1-5 | kubeconfig 생성 | `ls generated/kubeconfig-*` | kubeconfig-mgmt, kubeconfig-app1, kubeconfig-app2, kubeconfig-multi |
| 1-6 | 클러스터 컨텍스트 | `kubectl --kubeconfig ~/kubeconfig-multi config get-contexts` | 3개 컨텍스트 (kubernetes-admin@mgmt/app1/app2) |

---

## Phase 2: K8s 클러스터 상태

| # | 체크 항목 | 명령어 | 기대값 |
|---|----------|--------|--------|
| 2-1 | 노드 Ready | `kubectl get nodes` (각 클러스터) | 모든 노드 Ready |
| 2-2 | CoreDNS 정상 | `kubectl -n kube-system get pods -l k8s-app=kube-dns` | 2/2 Running |
| 2-3 | kube-proxy 또는 CNI 대체 | `kubectl -n kube-system get ds` | cilium or kube-proxy Running |
| 2-4 | Pod CIDR 분리 확인 | 각 클러스터 `kubectl cluster-info dump \| grep cluster-cidr` | mgmt: 10.100.0.0/16, app1: 10.101.0.0/16, app2: 10.102.0.0/16 |

---

## Phase 3: Addon 설치 (`addons/install.sh --all --yes`)

### 3-A. Infrastructure (의존성 없음, 최초 설치)

| # | Addon | 체크 방법 | 기대값 |
|---|-------|----------|--------|
| 3A-1 | priority-classes | `kubectl get pc` | platform-critical, platform-normal 존재 |
| 3A-2 | local-path-provisioner | `kubectl -n local-path-storage get deploy` | 1/1 Ready |
| 3A-3 | Cilium | `kubectl -n kube-system get pods -l k8s-app=cilium` | Running (각 노드) |
| 3A-4 | Tetragon | `kubectl -n kube-system get ds tetragon` | Running (각 노드) |
| 3A-5 | MetalLB | `kubectl -n metallb-system get pods` | controller + speaker Running |
| 3A-6 | Gateway API | `kubectl get crd gateways.gateway.networking.k8s.io` | CRD 존재 |
| 3A-7 | cert-manager | `kubectl -n cert-manager get deploy` | 3 deployments Ready |

### 3-B. Secrets & GitOps

| # | Addon | 체크 방법 | 기대값 |
|---|-------|----------|--------|
| 3B-1 | Vault | `kubectl -n vault get sts vault` | 1/1 Ready (Sealed 상태) |
| 3B-2 | Vault LB | `kubectl -n vault get svc vault` | External IP 할당 |
| 3B-3 | ESO | `kubectl -n security get deploy external-secrets` | 1/1 Ready |
| 3B-4 | ArgoCD | `kubectl -n argocd get deploy argocd-server` | 1/1 Ready |

### 3-C. Backup

| # | Addon | 체크 방법 | 기대값 |
|---|-------|----------|--------|
| 3C-1 | MinIO | `kubectl -n backup get deploy minio` | 1/1 Ready |
| 3C-2 | MinIO LB | `kubectl -n backup get svc minio` | External IP 할당 |
| 3C-3 | MinIO health | `curl http://<MINIO_LB>:9000/minio/health/live` | 응답 수신 |
| 3C-4 | Velero (전 클러스터) | `kubectl -n backup get deploy velero` | 1/1 Ready |
| 3C-5 | Velero BSL | `kubectl -n backup get bsl default` | phase: Available |
| 3C-6 | Velero Schedule | `velero schedule get` | daily-{cluster} 존재 |

### 3-D. Observability

| # | Addon | 체크 방법 | 기대값 |
|---|-------|----------|--------|
| 3D-1 | Thanos Query | `kubectl -n observability get deploy thanos-query` | 1/1 Ready |
| 3D-2 | Thanos Receive | `kubectl -n observability get sts thanos-receive` | 1/1 Ready |
| 3D-3 | Thanos LB | `kubectl -n observability get svc thanos-receive` | External IP 할당 |
| 3D-4 | Prometheus | `kubectl -n monitoring get sts` | prometheus + alertmanager Ready |
| 3D-5 | Prometheus targets | `curl localhost:9090/api/v1/targets` (port-forward) | down targets <= 3 (control plane) |
| 3D-6 | Loki | `kubectl -n observability get sts loki` | 1/1 Ready |
| 3D-7 | Loki LB | `kubectl -n observability get svc loki-lb` | External IP 할당 |
| 3D-8 | Tempo | `kubectl -n observability get sts tempo` | 1/1 Ready |
| 3D-9 | Alloy (전 클러스터) | `kubectl -n observability get ds alloy` | Desired = Ready |

### 3-E. Security (app 클러스터)

| # | Addon | 체크 방법 | 기대값 |
|---|-------|----------|--------|
| 3E-1 | Kyverno | `kubectl -n security get deploy` (app1, app2) | admission-controller Ready |
| 3E-2 | Falco | `kubectl -n security get ds falco` (app1, app2) | Running |

---

## Phase 4: 네트워크 통신 검증

### 4-A. 클러스터 내부 DNS

| # | 체크 항목 | 명령어 (mgmt 클러스터) | 기대값 |
|---|----------|----------------------|--------|
| 4A-1 | Service DNS | `kubectl run test --rm -it --image=busybox -- nslookup kubernetes.default` | 응답 수신 |
| 4A-2 | Cross-ns DNS | `kubectl run test --rm -it --image=busybox -- nslookup loki.observability.svc.cluster.local` | IP 반환 |

### 4-B. Cross-Cluster (app -> mgmt LB)

| # | 체크 항목 | 테스트 방법 | 기대값 |
|---|----------|-----------|--------|
| 4B-1 | app -> Loki | mgmt pod에서 `wget http://<LOKI_LB>:3100/ready` | "ready" |
| 4B-2 | app -> Thanos | mgmt pod에서 `wget http://<THANOS_LB>:10902/-/ready` | "OK" |
| 4B-3 | app -> MinIO | mgmt pod에서 `wget http://<MINIO_LB>:9000/minio/health/live` | 응답 수신 |

### 4-C. Alloy Endpoint IP 일치 확인

| # | 체크 항목 | 방법 | 기대값 |
|---|----------|------|--------|
| 4C-1 | Alloy → Thanos IP | Alloy ConfigMap의 remote_write URL | 실제 thanos-receive LB IP와 일치 |
| 4C-2 | Alloy → Loki IP | Alloy ConfigMap의 loki push URL | 실제 loki-lb LB IP와 일치 |

> **주의**: `tofu destroy` → `tofu apply` 재구축 시 MetalLB IP가 변경될 수 있다.
> Alloy는 Thanos/Loki보다 먼저 설치되므로, 설치 순서에 따라 IP 불일치가 발생할 수 있다.
> **해결**: Thanos/Loki 설치 후 `addons/install.sh alloy` 재실행.

---

## Phase 5: 데이터 흐름 검증 (Grafana)

### 5-A. Grafana 접근

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# 브라우저: http://localhost:3000
# ID: admin / PW: kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

### 5-B. Datasource 확인

| # | Datasource | 타입 | 출처 |
|---|-----------|------|------|
| 5B-1 | Prometheus | prometheus | kube-prometheus-stack 자동 생성 |
| 5B-2 | Alertmanager | alertmanager | kube-prometheus-stack 자동 생성 |
| 5B-3 | Loki | loki | grafana-datasource-loki ConfigMap |
| 5B-4 | Tempo | tempo | grafana-datasource-tempo ConfigMap |
| 5B-5 | Thanos | prometheus | grafana-datasource-thanos ConfigMap |

### 5-C. 데이터 수집 확인

| # | 체크 항목 | Grafana Explore 쿼리 | 기대값 |
|---|----------|---------------------|--------|
| 5C-1 | mgmt 메트릭 | Prometheus → `up` | 18+ targets |
| 5C-2 | mgmt 로그 | Loki → `{cluster="mgmt"}` | 로그 스트림 표시 |
| 5C-3 | app1 로그 | Loki → `{cluster="app1"}` | 로그 스트림 표시 |
| 5C-4 | app2 로그 | Loki → `{cluster="app2"}` | 로그 스트림 표시 |
| 5C-5 | app1 메트릭 (Thanos) | Thanos → `up{cluster="app1"}` | kubelet/cadvisor 메트릭 존재 |
| 5C-6 | app2 메트릭 (Thanos) | Thanos → `up{cluster="app2"}` | kubelet/cadvisor 메트릭 존재 |
| 5C-7 | 대시보드 로드 | Dashboards → K8s / Compute Resources | 그래프 정상 렌더링 |

---

## Phase 6: 수동 후속 작업

이 항목들은 자동 설치 이후 수동으로 진행해야 한다.

| # | 작업 | 의존성 | 비고 |
|---|------|--------|------|
| 6-1 | Vault init/unseal | Vault pod Ready | `vault operator init`, `vault operator unseal` |
| 6-2 | Vault PKI 설정 | Vault unsealed | `addons/install.sh vault-pki` |
| 6-3 | ClusterMesh 설정 | Cilium 전 클러스터 | `addons/install.sh clustermesh` |
| 6-4 | Istio + Kiali | 리소스 여유 확인 | `addons/install.sh istio kiali` |
| 6-5 | HolmesGPT | Slack sink 설정 | Robusta values에 sink 추가 후 설치 |

---

## 알려진 제약/경고

1. **Control plane 메트릭**: kube-controller-manager, kube-scheduler, etcd가 `127.0.0.1`에만 바인드되어 Prometheus scrape 불가. kubeadm 설정에서 `--bind-address=0.0.0.0` 변경 필요.
2. **Grafana PVC chown**: local-path PVC에서 init-chown-data가 Permission denied로 실패할 수 있음. 기존 pod가 정상이면 새 RS의 rollout이 stuck 상태가 됨.
3. **Kyverno 정책**: app 클러스터에서 debug pod 실행 시 정책 위반으로 차단됨. `--overrides`로 securityContext + resources 설정 필요.
4. **IP 변경**: `tofu destroy` → `apply` 시 MetalLB IP pool이 재할당되므로, LB IP 의존 설정(Alloy, Velero 등) 재배포 필요.

# 구현 가이드 (Implementation Guide)

> **버전**: 2.0.0
> **관련 문서**: [아키텍처](ARCHITECTURE.md) | [운영 런북](OPERATIONS-RUNBOOK.md)

이 문서는 Kubernetes 멀티클러스터 환경의 실제 구현 코드와 설치 절차를 포함합니다.

---

## 목차

1. [사전 요구사항](#1-사전-요구사항)
2. [Terraform 구성](#2-terraform-구성)
3. [Kubernetes 클러스터 설정](#3-kubernetes-클러스터-설정)
4. [CNI (Cilium) 설정](#4-cni-cilium-설정)
5. [스토리지 설정](#5-스토리지-설정)
6. [시크릿 관리 (Vault)](#6-시크릿-관리-vault)
7. [인증서 관리 (cert-manager)](#7-인증서-관리-cert-manager)
8. [관찰성 스택](#8-관찰성-스택)
9. [보안 정책](#9-보안-정책)
10. [외부 서비스 (Docker)](#10-외부-서비스-docker)
11. [설치 순서](#11-설치-순서)

---

## 1. 사전 요구사항

### 1.1 소프트웨어 설치

```bash
# 필수
brew install terraform        # >= 1.11.3
brew install multipass       # >= 1.15.1
brew install kubectl         # >= 1.35.0
brew install helm            # >= 3.14.0

# 선택
brew install cilium-cli      # Cilium 관리
brew install k9s             # K8s TUI
brew install k8sgpt          # AI 기반 분석
```

### 1.2 버전 확인

```bash
terraform version
multipass version
kubectl version --client
helm version
```

---

## 2. Terraform 구성

### 2.1 프로젝트 구조

```
terraform/
├── main.tf
├── variables.tf
├── outputs.tf
├── versions.tf
└── modules/
    ├── multipass-vm/
    └── kubernetes-cluster/
```

### 2.2 Multipass VM 모듈

```hcl
# modules/multipass-vm/main.tf
resource "multipass_instance" "vm" {
  name   = var.name
  cpus   = var.cpus
  memory = var.memory
  disk   = var.disk
  image  = "24.04"

  cloudinit_file = templatefile("${path.module}/cloud-init.yaml", {
    hostname = var.name
    ssh_key  = var.ssh_public_key
  })
}

# modules/multipass-vm/variables.tf
variable "name" {
  type = string
}

variable "cpus" {
  type    = number
  default = 2
}

variable "memory" {
  type    = string
  default = "4G"
}

variable "disk" {
  type    = string
  default = "40G"
}

variable "ssh_public_key" {
  type = string
}
```

### 2.3 클러스터 정의

```hcl
# main.tf
module "mgmt_cp" {
  source         = "./modules/multipass-vm"
  name           = "mgmt-cp"
  cpus           = 2
  memory         = "4G"
  disk           = "40G"
  ssh_public_key = file("~/.ssh/id_rsa.pub")
}

module "mgmt_worker" {
  source         = "./modules/multipass-vm"
  name           = "mgmt-worker-0"
  cpus           = 2
  memory         = "6G"
  disk           = "60G"
  ssh_public_key = file("~/.ssh/id_rsa.pub")
}

# app1, app2 클러스터도 동일한 패턴
```

---

## 3. Kubernetes 클러스터 설정

### 3.1 kubeadm 설정

```yaml
# kubeadm-config.yaml (mgmt 클러스터)
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.35.0
clusterName: mgmt
controlPlaneEndpoint: "mgmt-cp:6443"
networking:
  podSubnet: "10.100.0.0/16"
  serviceSubnet: "10.96.0.0/16"
  dnsDomain: "cluster.local"
apiServer:
  extraArgs:
    - name: admission-control-config-file
      value: /etc/kubernetes/psa/admission-config.yaml
controllerManager:
  extraArgs:
    - name: bind-address
      value: "0.0.0.0"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
```

### 3.2 PSA 설정

```yaml
# /etc/kubernetes/psa/admission-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      defaults:
        enforce: "baseline"
        enforce-version: "latest"
        audit: "restricted"
        audit-version: "latest"
        warn: "restricted"
        warn-version: "latest"
      exemptions:
        namespaces:
          - kube-system
          - cilium-system
          - monitoring
          - vault
```

### 3.3 클러스터 초기화 스크립트

```bash
#!/bin/bash
# scripts/init-cluster.sh

CLUSTER_NAME="${1:-mgmt}"
CONFIG_FILE="kubeadm-config-${CLUSTER_NAME}.yaml"

# kubeadm 초기화
sudo kubeadm init --config ${CONFIG_FILE}

# kubeconfig 설정
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo "클러스터 ${CLUSTER_NAME} 초기화 완료"
```

---

## 4. CNI (Cilium) 설정

### 4.1 Cilium 설치

```bash
# Cilium CLI로 설치
cilium install \
  --version 1.19.0 \
  --set cluster.id=1 \
  --set cluster.name=mgmt \
  --set tunnel=vxlan \
  --set ipam.mode=kubernetes \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true
```

### 4.2 Helm values

```yaml
# values-cilium.yaml
cluster:
  id: 1
  name: mgmt

tunnel: vxlan

ipam:
  mode: kubernetes

hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true

clustermesh:
  useAPIServer: true
```

### 4.3 Cluster Mesh 연결

```bash
# mgmt 클러스터에서
cilium clustermesh enable --service-type LoadBalancer

# app1, app2 클러스터 연결
cilium clustermesh connect --destination-context app1
cilium clustermesh connect --destination-context app2

# 상태 확인
cilium clustermesh status
```

---

## 5. 스토리지 설정

### 5.1 Local Path Provisioner 설치

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml
```

### 5.2 StorageClass 정의

```yaml
# storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path-retain
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
```

---

## 6. 시크릿 관리 (Vault)

### 6.1 Vault Helm 설치

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  --values values-vault.yaml
```

### 6.2 Vault values

```yaml
# values-vault.yaml
server:
  ha:
    enabled: false  # 로컬 환경
  dataStorage:
    storageClass: local-path-retain
    size: 10Gi

ui:
  enabled: true
  serviceType: LoadBalancer
```

### 6.3 External Secrets Operator

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace
```

### 6.4 ClusterSecretStore 설정

```yaml
# cluster-secret-store.yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "http://vault.vault.svc:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "external-secrets"
```

---

## 7. 인증서 관리 (cert-manager)

### 7.1 cert-manager 설치

```bash
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true
```

### 7.2 Phase 1: Self-signed Issuer

```yaml
# selfsigned-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
```

### 7.3 Phase 2: Vault Issuer

```yaml
# vault-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-issuer
spec:
  vault:
    server: http://vault.vault.svc:8200
    path: pki_int/sign/k8s-certs
    auth:
      kubernetes:
        mountPath: /v1/auth/kubernetes
        role: cert-manager
        secretRef:
          name: cert-manager-vault-token
          key: token
```

---

## 8. 관찰성 스택

### 8.1 kube-prometheus-stack (mgmt)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --values values-prometheus-mgmt.yaml
```

### 8.2 Prometheus values (mgmt)

```yaml
# values-prometheus-mgmt.yaml
prometheus:
  prometheusSpec:
    retention: 15d
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          resources:
            requests:
              storage: 20Gi

    thanos:
      objectStorageConfig:
        existingSecret:
          name: thanos-objstore
          key: config.yaml

grafana:
  enabled: true
  adminPassword: admin
  persistence:
    enabled: true
    storageClassName: local-path
```

### 8.3 Prometheus Agent (app 클러스터)

```yaml
# values-prometheus-agent.yaml
prometheus:
  prometheusSpec:
    mode: Agent
    remoteWrite:
      - url: http://thanos-receive.mgmt.svc:19291/api/v1/receive
        queueConfig:
          capacity: 10000
          maxShards: 50
          maxBackoff: 5m
```

### 8.4 Loki 설치

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm install loki grafana/loki-stack \
  --namespace monitoring \
  --values values-loki.yaml
```

---

## 9. 보안 정책

### 9.1 Kyverno 설치 (app 클러스터)

```bash
helm repo add kyverno https://kyverno.github.io/kyverno
helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace
```

### 9.2 이미지 레지스트리 제한 정책

```yaml
# require-harbor-registry.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-harbor-registry
spec:
  validationFailureAction: enforce
  rules:
    - name: validate-image-registry
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "이미지는 Harbor 레지스트리에서만 Pull 가능합니다"
        pattern:
          spec:
            containers:
              - image: "harbor.local.dev/*"
```

### 9.3 리소스 제한 필수 정책

```yaml
# require-resources.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resources
spec:
  validationFailureAction: enforce
  rules:
    - name: require-requests-limits
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "모든 컨테이너에 requests와 limits가 필요합니다"
        pattern:
          spec:
            containers:
              - resources:
                  requests:
                    memory: "?*"
                    cpu: "?*"
                  limits:
                    memory: "?*"
```

---

## 10. 외부 서비스 (Docker)

### 10.1 Docker Compose

```yaml
# docker-compose.yaml
version: '3.8'

services:
  harbor:
    image: goharbor/harbor-core:v2.10.0
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - harbor-data:/data
    deploy:
      resources:
        limits:
          memory: 2G

  nexus:
    image: sonatype/nexus3:latest
    ports:
      - "8081:8081"
    volumes:
      - nexus-data:/nexus-data
    deploy:
      resources:
        limits:
          memory: 2G

volumes:
  harbor-data:
  nexus-data:
```

### 10.2 서비스 시작

```bash
docker-compose up -d
```

---

## 11. 설치 순서

### 11.1 의존성 그래프

```
Terraform (VM 생성)
    │
    ▼
kubeadm (클러스터 초기화)
    │
    ▼
Cilium CNI
    │
    ├──► MetalLB
    │
    ▼
cert-manager (Phase 1: Self-signed)
    │
    ▼
Vault
    │
    ▼
cert-manager (Phase 2: Vault Issuer)
    │
    ▼
External Secrets Operator
    │
    ▼
관찰성 스택 (Prometheus, Loki, Grafana)
    │
    ▼
보안 (Kyverno, Falco)
    │
    ▼
Velero (백업)
```

### 11.2 전체 설치 스크립트

```bash
#!/bin/bash
# scripts/deploy-all.sh

set -e

echo "=== 1. Terraform 실행 ==="
cd terraform && terraform apply -auto-approve && cd ..

echo "=== 2. 클러스터 초기화 ==="
./scripts/init-cluster.sh mgmt
./scripts/init-cluster.sh app1
./scripts/init-cluster.sh app2

echo "=== 3. Cilium 설치 ==="
./scripts/install-cilium.sh

echo "=== 4. 플랫폼 서비스 설치 ==="
./scripts/install-platform.sh

echo "=== 설치 완료 ==="
kubectl get nodes -A
```

---

## 부록: 디렉토리 구조

```
.
├── terraform/              # IaC
│   ├── main.tf
│   ├── variables.tf
│   └── modules/
├── manifests/              # K8s 매니페스트
│   ├── mgmt/
│   ├── app1/
│   └── app2/
├── scripts/                # 자동화 스크립트
│   ├── init-cluster.sh
│   ├── install-cilium.sh
│   └── deploy-all.sh
├── helm-values/            # Helm values
│   ├── prometheus/
│   ├── vault/
│   └── cilium/
└── docker-compose.yaml     # 외부 서비스
```

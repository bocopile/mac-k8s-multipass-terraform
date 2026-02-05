# Azure 운영 런북 (Operations Runbook)

> **버전**: 2.0.0
> **관련 문서**: [아키텍처](ARCHITECTURE-AZURE.md) | [구현 가이드](IMPLEMENTATION-AZURE.md)

이 문서는 Azure Kubernetes 환경의 운영 절차를 포함합니다.

---

## 목차

1. [일상 운영](#1-일상-운영)
2. [백업 절차](#2-백업-절차)
3. [복구 절차](#3-복구-절차)
4. [업그레이드 절차](#4-업그레이드-절차)
5. [비용 관리](#5-비용-관리)
6. [트러블슈팅](#6-트러블슈팅)

---

## 1. 일상 운영

### 1.1 클러스터 상태 확인

```bash
# AKS 클러스터 상태
az aks show --resource-group rg-k8s-demo --name aks-mgmt --query provisioningState

# 노드 상태
kubectl get nodes -o wide

# 시스템 Pod 상태
kubectl get pods -n kube-system
```

### 1.2 리소스 사용량

```bash
# 노드 리소스
kubectl top nodes

# Container Insights 대시보드
az aks show --resource-group rg-k8s-demo --name aks-mgmt --query addonProfiles.omsagent
```

### 1.3 비업무시간 클러스터 중지/시작

```bash
# 클러스터 중지 (비용 절감)
az aks stop --resource-group rg-k8s-demo --name aks-mgmt

# 클러스터 시작
az aks start --resource-group rg-k8s-demo --name aks-mgmt

# 상태 확인
az aks show --resource-group rg-k8s-demo --name aks-mgmt --query powerState
```

---

## 2. 백업 절차

### 2.1 Azure Backup for AKS

```bash
# 백업 Extension 설치 확인
az aks show --resource-group rg-k8s-demo --name aks-mgmt \
  --query "addonProfiles.azureKeyvaultSecretsProvider"

# 백업 트리거 (Azure Portal 또는 CLI)
az dataprotection backup-instance adhoc-backup \
  --backup-instance-name aks-mgmt \
  --resource-group rg-k8s-demo \
  --vault-name rsv-k8s-backup
```

### 2.2 Velero 백업

```bash
# Velero 상태 확인
velero backup get

# 수동 백업
velero backup create daily-backup-$(date +%Y%m%d) \
  --include-namespaces default,app \
  --ttl 168h

# 백업 로그 확인
velero backup logs <backup-name>
```

### 2.3 Terraform 상태 백업

```bash
# Terraform 상태는 Azure Storage에 자동 저장
# 수동 백업이 필요한 경우:
terraform state pull > terraform-state-backup-$(date +%Y%m%d).json
```

---

## 3. 복구 절차

### 3.1 Velero 복구

```bash
# 백업 목록 확인
velero backup get

# 복구 실행
velero restore create --from-backup <backup-name>

# 특정 네임스페이스만 복구
velero restore create --from-backup <backup-name> --include-namespaces app

# 복구 상태 확인
velero restore describe <restore-name>
```

### 3.2 AKS 클러스터 재생성

```bash
# Terraform으로 재생성
cd terraform-azure
terraform destroy -target=module.aks_mgmt
terraform apply -target=module.aks_mgmt

# kubeconfig 갱신
az aks get-credentials --resource-group rg-k8s-demo --name aks-mgmt --overwrite-existing
```

---

## 4. 업그레이드 절차

### 4.1 AKS 버전 업그레이드

```bash
# 사용 가능한 버전 확인
az aks get-upgrades --resource-group rg-k8s-demo --name aks-mgmt --output table

# Control Plane 업그레이드
az aks upgrade \
  --resource-group rg-k8s-demo \
  --name aks-mgmt \
  --kubernetes-version 1.30.0 \
  --control-plane-only

# Node Pool 업그레이드
az aks nodepool upgrade \
  --resource-group rg-k8s-demo \
  --cluster-name aks-mgmt \
  --name nodepool1 \
  --kubernetes-version 1.30.0
```

### 4.2 Node Image 업그레이드

```bash
# Node Image만 업그레이드 (OS 패치)
az aks nodepool upgrade \
  --resource-group rg-k8s-demo \
  --cluster-name aks-mgmt \
  --name nodepool1 \
  --node-image-only
```

### 4.3 자동 업그레이드 설정

```bash
# 자동 업그레이드 채널 설정
az aks update \
  --resource-group rg-k8s-demo \
  --name aks-mgmt \
  --auto-upgrade-channel stable
```

---

## 5. 비용 관리

### 5.1 비용 확인

```bash
# 리소스 그룹별 비용
az consumption usage list \
  --start-date 2026-01-01 \
  --end-date 2026-01-31 \
  --query "[?contains(instanceId, 'rg-k8s-demo')]" \
  --output table
```

### 5.2 예산 알림 설정

```bash
# 예산 생성
az consumption budget create \
  --budget-name k8s-demo-budget \
  --amount 100 \
  --time-grain Monthly \
  --category Cost \
  --resource-group rg-k8s-demo
```

### 5.3 불필요 리소스 정리

```bash
# 사용하지 않는 디스크 확인
az disk list --resource-group rg-k8s-demo --query "[?diskState=='Unattached']"

# 오래된 이미지 정리 (ACR)
az acr run --registry <acr-name> --cmd "acr purge --filter '*:*' --ago 30d --untagged" /dev/null
```

---

## 6. 트러블슈팅

### 6.1 노드 문제

```bash
# 노드 상태 확인
kubectl describe node <node-name>

# 노드 이벤트 확인
kubectl get events --field-selector involvedObject.kind=Node

# Spot VM 회수 이벤트 확인
az aks nodepool show --resource-group rg-k8s-demo --cluster-name aks-mgmt --name spot \
  --query "count" -o tsv
```

### 6.2 네트워크 문제

```bash
# NSG 규칙 확인
az network nsg rule list --resource-group rg-k8s-demo --nsg-name <nsg-name> -o table

# DNS 해석 테스트
kubectl run test-dns --image=busybox --rm -it --restart=Never -- nslookup kubernetes.default
```

### 6.3 Key Vault 문제

```bash
# Key Vault 접근 확인
az keyvault secret list --vault-name kv-k8s-demo -o table

# Workload Identity 상태 확인
kubectl get serviceaccount -A | grep workload
```

### 6.4 로그 확인

```bash
# Container Insights 로그 쿼리 (Azure Portal)
# KQL 예시:
# ContainerLog
# | where ClusterName == "aks-mgmt"
# | where LogEntry contains "error"
# | take 100

# 직접 Pod 로그
kubectl logs -f deployment/<name> -n <namespace>
```

---

## 부록: 긴급 연락처

| 상황 | 담당 |
|-----|-----|
| AKS 클러스터 장애 | Platform Team |
| Azure 서비스 장애 | Azure Support |
| 비용 이상 | Finance/Platform Team |

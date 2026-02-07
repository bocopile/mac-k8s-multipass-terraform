# Azure 구현 가이드 (Implementation Guide)

> **버전**: 2.0.0
> **관련 문서**: [아키텍처](ARCHITECTURE.md) | [운영 런북](OPERATIONS-RUNBOOK.md)

이 문서는 Azure Kubernetes 환경의 Terraform 코드와 설정을 포함합니다.

---

## 목차

1. [사전 요구사항](#1-사전-요구사항)
2. [Terraform 구성](#2-terraform-구성)
3. [AKS 클러스터 설정](#3-aks-클러스터-설정)
4. [네트워크 설정](#4-네트워크-설정)
5. [Azure Key Vault 연동](#5-azure-key-vault-연동)
6. [관찰성 설정](#6-관찰성-설정)
7. [배포 절차](#7-배포-절차)

---

## 1. 사전 요구사항

### 1.1 도구 설치

```bash
# Azure CLI
brew install azure-cli

# Terraform
brew install terraform

# kubectl
brew install kubectl

# Helm
brew install helm
```

### 1.2 Azure 로그인

```bash
az login
az account set --subscription "<subscription-id>"
```

---

## 2. Terraform 구성

### 2.1 프로젝트 구조

```
terraform-azure/
├── main.tf
├── variables.tf
├── outputs.tf
├── versions.tf
└── modules/
    ├── aks/
    ├── vnet/
    └── keyvault/
```

### 2.2 Provider 설정

```hcl
# versions.tf
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "stterraformstate"
    container_name       = "tfstate"
    key                  = "k8s-demo.tfstate"
  }
}

provider "azurerm" {
  features {}
}
```

---

## 3. AKS 클러스터 설정

### 3.1 AKS 모듈

```hcl
# modules/aks/main.tf
resource "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version

  default_node_pool {
    name                = "system"
    node_count          = 1
    vm_size             = "Standard_D2s_v3"
    os_disk_size_gb     = 30
    vnet_subnet_id      = var.subnet_id
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"  # 또는 "none" for BYO CNI
    network_policy = "azure"
  }

  # Azure Monitor Agent (AMA) - Container Insights 연동
  # AzureRM provider에서는 oms_agent 블록으로 설정
  oms_agent {
    log_analytics_workspace_id = var.log_analytics_workspace_id
  }

  azure_policy_enabled = true

  tags = var.tags
}
```

### 3.2 Spot Node Pool

```hcl
resource "azurerm_kubernetes_cluster_node_pool" "spot" {
  name                  = "spot"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = "Standard_D2s_v3"
  node_count            = 2

  priority        = "Spot"
  eviction_policy = "Delete"
  spot_max_price  = 0.04

  node_labels = {
    "kubernetes.azure.com/scalesetpriority" = "spot"
  }

  node_taints = [
    "kubernetes.azure.com/scalesetpriority=spot:NoSchedule"
  ]

  tags = var.tags
}
```

---

## 4. 네트워크 설정

### 4.1 VNet 모듈

```hcl
# modules/vnet/main.tf
resource "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = ["10.0.0.0/8"]

  tags = var.tags
}

resource "azurerm_subnet" "aks_mgmt" {
  name                 = "subnet-aks-mgmt"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.1.0.0/16"]
}

resource "azurerm_subnet" "aks_app1" {
  name                 = "subnet-aks-app1"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.2.0.0/16"]
}
```

### 4.2 NSG (Subnet 간 트래픽 제어)

단일 VNet 내 Subnet 간에는 기본적으로 라우팅이 가능하므로 VNet Peering은 불필요합니다.
NSG로 Subnet 간 트래픽을 제어합니다:

```hcl
resource "azurerm_network_security_group" "aks_mgmt" {
  name                = "nsg-aks-mgmt"
  location            = var.location
  resource_group_name = var.resource_group_name

  security_rule {
    name                       = "allow-app-subnets"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefixes    = ["10.2.0.0/16", "10.3.0.0/16"]
    destination_address_prefix = "10.1.0.0/16"
    source_port_range          = "*"
    destination_port_range     = "*"
  }
}
```

---

## 5. Azure Key Vault 연동

### 5.1 Key Vault 생성

```hcl
resource "azurerm_key_vault" "main" {
  name                = "kv-k8s-demo"
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  enable_rbac_authorization = true
}
```

### 5.2 Workload Identity 설정

```hcl
resource "azurerm_user_assigned_identity" "workload" {
  name                = "id-workload-identity"
  location            = var.location
  resource_group_name = var.resource_group_name
}

resource "azurerm_federated_identity_credential" "workload" {
  name                = "federated-credential"
  resource_group_name = var.resource_group_name
  parent_id           = azurerm_user_assigned_identity.workload.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject             = "system:serviceaccount:default:workload-sa"
}
```

---

## 6. 관찰성 설정

### 6.1 Log Analytics Workspace

```hcl
resource "azurerm_log_analytics_workspace" "main" {
  name                = "law-k8s-demo"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  daily_quota_gb = 5  # 비용 제한
}

resource "azurerm_log_analytics_solution" "containers" {
  solution_name         = "ContainerInsights"
  location              = var.location
  resource_group_name   = var.resource_group_name
  workspace_resource_id = azurerm_log_analytics_workspace.main.id
  workspace_name        = azurerm_log_analytics_workspace.main.name

  plan {
    publisher = "Microsoft"
    product   = "OMSGallery/ContainerInsights"
  }
}
```

---

## 7. 배포 절차

### 7.1 Terraform 배포

```bash
# 초기화
terraform init

# 계획 확인
terraform plan -out=tfplan

# 배포
terraform apply tfplan

# 출력 확인
terraform output
```

### 7.2 kubeconfig 설정

```bash
# AKS 자격 증명 가져오기
az aks get-credentials --resource-group rg-k8s-demo --name aks-mgmt

# 컨텍스트 확인
kubectl config get-contexts
```

### 7.3 후속 설정

```bash
# ArgoCD 설치
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# External Secrets Operator 설치
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace
```

---

## 부록: 유용한 명령어

```bash
# 리소스 그룹 전체 삭제
az group delete -n rg-k8s-demo --yes --no-wait

# AKS 버전 확인
az aks get-versions -l koreacentral -o table

# Spot VM 가격 확인
az vm list-skus -l koreacentral --size Standard_D2s_v3 -o table
```

variable "multipass_image" {
  description = "Multipass에서 사용할 Ubuntu 이미지 버전"
  type        = string
  default     = "24.04"

  validation {
    condition     = can(regex("^[a-zA-Z0-9._:-]+$", var.multipass_image))
    error_message = "multipass_image must contain only alphanumeric characters, dots, underscores, colons, and hyphens"
  }
}

variable "k8s_version" {
  description = "Kubernetes 버전 (major.minor)"
  type        = string
  default     = "1.35"

  validation {
    condition     = can(regex("^1\\.(3[0-9]|[4-9][0-9])$", var.k8s_version))
    error_message = "k8s_version must be 1.30 or higher (format: major.minor, e.g., '1.35')"
  }
}

variable "cilium_version" {
  description = "Cilium CNI 버전 (k8s 1.35 호환: >= 1.19.0)"
  type        = string
  default     = "1.19.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.cilium_version))
    error_message = "cilium_version must be in semantic version format (e.g., '1.19.0')"
  }
}

variable "metallb_version" {
  description = "MetalLB 버전"
  type        = string
  default     = "v0.15.3"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.metallb_version))
    error_message = "metallb_version must be in format 'vX.Y.Z' (e.g., 'v0.15.3')"
  }
}

variable "tetragon_version" {
  description = "Tetragon eBPF 런타임 보안 버전"
  type        = string
  default     = "1.3.0"
}

variable "cert_manager_version" {
  description = "cert-manager 버전"
  type        = string
  default     = "v1.17.1"
}

variable "kyverno_version" {
  description = "Kyverno 정책 엔진 버전 (app 클러스터만)"
  type        = string
  default     = "3.3.4"
}

variable "falco_version" {
  description = "Falco 런타임 보안 버전 (app 클러스터만)"
  type        = string
  default     = "4.16.0"
}

variable "argocd_version" {
  description = "ArgoCD Helm 차트 버전 (mgmt 클러스터)"
  type        = string
  default     = "9.4.7"
}

variable "istio_version" {
  description = "Istio Service Mesh 버전 (mgmt, app1 클러스터)"
  type        = string
  default     = "1.29.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.istio_version))
    error_message = "istio_version must be in semantic version format (e.g., '1.29.0')"
  }

  validation {
    condition     = tonumber(split(".", var.istio_version)[0]) >= 1 && tonumber(split(".", var.istio_version)[1]) >= 29
    error_message = "istio_version must be 1.29.0 or higher for Kubernetes 1.35 compatibility"
  }
}

variable "tempo_version" {
  description = "Grafana Tempo 분산 추적 백엔드 버전 (mgmt 클러스터)"
  type        = string
  default     = "1.24.4"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.tempo_version))
    error_message = "tempo_version must be in semantic version format (e.g., '1.24.4')"
  }
}

variable "alloy_version" {
  description = "Grafana Alloy 버전 (전 클러스터 - Promtail/OTel Collector/Prometheus Agent 통합)"
  type        = string
  default     = "1.6.1"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.alloy_version))
    error_message = "alloy_version must be in semantic version format (e.g., '1.6.1')"
  }
}

variable "kiali_version" {
  description = "Kiali Service Mesh 관찰성 대시보드 버전 (mgmt, app1 클러스터)"
  type        = string
  default     = "2.22.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.kiali_version))
    error_message = "kiali_version must be in semantic version format (e.g., '2.22.0')"
  }
}


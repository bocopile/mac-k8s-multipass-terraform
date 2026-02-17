variable "multipass_image" {
  description = "Multipass에서 사용할 Ubuntu 이미지 버전"
  type        = string
  default     = "24.04"
}

variable "k8s_version" {
  description = "Kubernetes 버전 (major.minor)"
  type        = string
  default     = "1.35"
}

variable "cilium_version" {
  description = "Cilium CNI 버전 (k8s 1.35 호환: >= 1.19.0)"
  type        = string
  default     = "1.19.0"
}

variable "metallb_version" {
  description = "MetalLB 버전"
  type        = string
  default     = "v0.15.3"
}

variable "tetragon_version" {
  description = "Tetragon eBPF 런타임 보안 버전"
  type        = string
  default     = "1.3.0"
}

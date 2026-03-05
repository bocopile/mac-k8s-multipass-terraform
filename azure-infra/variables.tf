variable "location" {
  description = "Azure 리전"
  type        = string
  default     = "KoreaCentral"
}

variable "resource_group_name" {
  description = "리소스 그룹 이름 (tofu destroy 시 Harbor/Nexus 포함 전체 삭제)"
  type        = string
  # default 없음 → terraform.tfvars 에서 반드시 지정
}

variable "admin_username" {
  description = "VM 관리자 계정 이름"
  type        = string
  default     = "azureuser"
}

variable "harbor_vm_size" {
  description = "Harbor VM 크기 (2 vCPU, 4GB RAM)"
  type        = string
  default     = "Standard_B2s"
}

variable "nexus_vm_size" {
  description = "Nexus VM 크기 (2 vCPU, 8GB RAM - JVM heap 필요)"
  type        = string
  default     = "Standard_B2ms"
}

variable "harbor_disk_size_gb" {
  description = "Harbor OS 디스크 크기 (GB) - 이미지 레이어 저장"
  type        = number
  default     = 80
}

variable "nexus_disk_size_gb" {
  description = "Nexus OS 디스크 크기 (GB) - Maven/npm 아티팩트 저장"
  type        = number
  default     = 100
}

variable "harbor_admin_password" {
  description = "Harbor admin 비밀번호"
  type        = string
  sensitive   = true
  # default 없음 → terraform.tfvars 에서 반드시 지정
}

variable "allowed_ssh_cidr" {
  description = "SSH 접근 허용 IP CIDR (본인 공인 IP 권장, 예: 1.2.3.4/32)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "harbor_version" {
  description = "Harbor 버전"
  type        = string
  default     = "v2.12.1"
}

variable "extra_open_ports" {
  description = <<-EOT
    추가로 개방할 인바운드 포트 목록 (서비스 포트 외 커스텀 포트)
    - priority 범위: 200~499 (기존 룰 100~130과 충돌 방지)
    - port: 단일 포트("443") 또는 범위("9000-9001")
    - source: "*" (전체) 또는 특정 CIDR ("1.2.3.4/32")
  EOT
  type = list(object({
    name     = string
    priority = number
    port     = string
    protocol = optional(string, "Tcp")
    source   = optional(string, "*")
  }))
  default = []

  validation {
    condition = alltrue([
      for r in var.extra_open_ports : r.priority >= 200 && r.priority <= 499
    ])
    error_message = "extra_open_ports의 priority는 200~499 사이여야 합니다 (기존 룰 100~130과 충돌 방지)."
  }
}

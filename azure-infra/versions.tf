terraform {
  required_version = ">= 1.11.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      # 리소스 그룹 삭제 시 내부 리소스도 함께 삭제
      prevent_deletion_if_contains_resources = false
    }
    virtual_machine {
      # VM 삭제 시 OS 디스크도 함께 삭제
      delete_os_disk_on_deletion = true
    }
  }
}

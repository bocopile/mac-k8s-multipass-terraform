output "harbor_public_ip" {
  description = "Harbor VM 공인 IP (컨테이너 레지스트리)"
  value       = azurerm_public_ip.harbor.ip_address
}

output "nexus_public_ip" {
  description = "Nexus VM 공인 IP (라이브러리 저장소)"
  value       = azurerm_public_ip.nexus.ip_address
}

output "harbor_url" {
  description = "Harbor 접근 URL"
  value       = "http://${azurerm_public_ip.harbor.ip_address}"
}

output "nexus_url" {
  description = "Nexus 접근 URL"
  value       = "http://${azurerm_public_ip.nexus.ip_address}:8081"
}

output "ssh_harbor" {
  description = "Harbor VM SSH 접속 명령"
  value       = "ssh -i ../generated/azure-infra-key.pem ${var.admin_username}@${azurerm_public_ip.harbor.ip_address}"
}

output "ssh_nexus" {
  description = "Nexus VM SSH 접속 명령"
  value       = "ssh -i ../generated/azure-infra-key.pem ${var.admin_username}@${azurerm_public_ip.nexus.ip_address}"
}

output "next_step" {
  description = "다음 단계"
  value       = "K8s 클러스터 설정 적용: bash ../scripts/configure-k8s-for-azure-infra.sh"
}

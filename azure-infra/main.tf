# =============================================================================
# SSH 키 쌍 생성
# =============================================================================
resource "tls_private_key" "infra_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "ssh_private_key" {
  filename        = "${path.module}/../generated/azure-infra-key.pem"
  content         = tls_private_key.infra_ssh.private_key_pem
  file_permission = "0600"
}

# =============================================================================
# 리소스 그룹
# =============================================================================
resource "azurerm_resource_group" "infra" {
  name     = var.resource_group_name
  location = var.location

  tags = {
    project     = "mac-k8s-multipass"
    environment = "dev"
    managed-by  = "opentofu"
  }
}

# =============================================================================
# 네트워크 (VNet + Subnet)
# =============================================================================
resource "azurerm_virtual_network" "infra" {
  name                = "vnet-infra"
  address_space       = ["10.10.0.0/16"]
  location            = azurerm_resource_group.infra.location
  resource_group_name = azurerm_resource_group.infra.name
}

resource "azurerm_subnet" "infra" {
  name                 = "subnet-infra"
  resource_group_name  = azurerm_resource_group.infra.name
  virtual_network_name = azurerm_virtual_network.infra.name
  address_prefixes     = ["10.10.1.0/24"]
}

# =============================================================================
# Network Security Group
# =============================================================================
resource "azurerm_network_security_group" "infra" {
  name                = "nsg-infra"
  location            = azurerm_resource_group.infra.location
  resource_group_name = azurerm_resource_group.infra.name

  # SSH 관리용
  security_rule {
    name                       = "allow-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.allowed_ssh_cidr
    destination_address_prefix = "*"
  }

  # Harbor HTTP (컨테이너 레지스트리)
  security_rule {
    name                       = "allow-harbor-http"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Nexus Repository UI + Maven/npm
  security_rule {
    name                       = "allow-nexus-ui"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8081"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Nexus Docker hosted (Harbor와 분리된 선택적 Docker 레지스트리)
  security_rule {
    name                       = "allow-nexus-docker"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8082-8083"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # 사용자 정의 추가 포트 (extra_open_ports 변수, priority 200~499)
  dynamic "security_rule" {
    for_each = { for r in var.extra_open_ports : r.name => r }
    content {
      name                       = security_rule.value.name
      priority                   = security_rule.value.priority
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = security_rule.value.protocol
      source_port_range          = "*"
      destination_port_range     = security_rule.value.port
      source_address_prefix      = security_rule.value.source
      destination_address_prefix = "*"
    }
  }
}

# =============================================================================
# Public IP (Static) - 재시작 후에도 IP 고정
# =============================================================================
resource "azurerm_public_ip" "harbor" {
  name                = "pip-harbor"
  location            = azurerm_resource_group.infra.location
  resource_group_name = azurerm_resource_group.infra.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_public_ip" "nexus" {
  name                = "pip-nexus"
  location            = azurerm_resource_group.infra.location
  resource_group_name = azurerm_resource_group.infra.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# =============================================================================
# Network Interface
# =============================================================================
resource "azurerm_network_interface" "harbor" {
  name                = "nic-harbor"
  location            = azurerm_resource_group.infra.location
  resource_group_name = azurerm_resource_group.infra.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.infra.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.harbor.id
  }
}

resource "azurerm_network_interface" "nexus" {
  name                = "nic-nexus"
  location            = azurerm_resource_group.infra.location
  resource_group_name = azurerm_resource_group.infra.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.infra.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.nexus.id
  }
}

resource "azurerm_network_interface_security_group_association" "harbor" {
  network_interface_id      = azurerm_network_interface.harbor.id
  network_security_group_id = azurerm_network_security_group.infra.id
}

resource "azurerm_network_interface_security_group_association" "nexus" {
  network_interface_id      = azurerm_network_interface.nexus.id
  network_security_group_id = azurerm_network_security_group.infra.id
}

# =============================================================================
# Harbor VM (컨테이너 이미지 레지스트리)
# =============================================================================
resource "azurerm_linux_virtual_machine" "harbor" {
  name                  = "harbor-vm"
  location              = azurerm_resource_group.infra.location
  resource_group_name   = azurerm_resource_group.infra.name
  size                  = var.harbor_vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.harbor.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.infra_ssh.public_key_openssh
  }

  os_disk {
    name                 = "osdisk-harbor"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.harbor_disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # cloud-init: Docker CE 설치 (기존 templates/cloud-init-infra.yaml.tpl 재사용)
  custom_data = base64encode(templatefile("${path.module}/../templates/cloud-init-infra.yaml.tpl", {
    hostname = "harbor-vm"
    service  = "harbor"
  }))

  tags = {
    project = "mac-k8s-multipass"
    role    = "container-registry"
  }
}

# =============================================================================
# Nexus VM (Maven/npm 라이브러리 저장소)
# =============================================================================
resource "azurerm_linux_virtual_machine" "nexus" {
  name                  = "nexus-vm"
  location              = azurerm_resource_group.infra.location
  resource_group_name   = azurerm_resource_group.infra.name
  size                  = var.nexus_vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.nexus.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = tls_private_key.infra_ssh.public_key_openssh
  }

  os_disk {
    name                 = "osdisk-nexus"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.nexus_disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/../templates/cloud-init-infra.yaml.tpl", {
    hostname = "nexus-vm"
    service  = "nexus"
  }))

  tags = {
    project = "mac-k8s-multipass"
    role    = "artifact-repository"
  }
}

# =============================================================================
# Harbor 설치 (remote-exec via SSH)
# =============================================================================
resource "null_resource" "install_harbor" {
  depends_on = [azurerm_linux_virtual_machine.harbor]

  triggers = {
    vm_id          = azurerm_linux_virtual_machine.harbor.id
    harbor_version = var.harbor_version
  }

  connection {
    type        = "ssh"
    user        = var.admin_username
    private_key = tls_private_key.infra_ssh.private_key_pem
    host        = azurerm_public_ip.harbor.ip_address
    timeout     = "10m"
  }

  # cloud-init 완료 대기
  provisioner "remote-exec" {
    inline = ["cloud-init status --wait"]
  }

  # Harbor 설치 스크립트 전송
  provisioner "file" {
    content = templatefile("${path.module}/scripts/harbor-setup.sh.tpl", {
      harbor_version        = var.harbor_version
      harbor_ip             = azurerm_public_ip.harbor.ip_address
      harbor_admin_password = var.harbor_admin_password
    })
    destination = "/tmp/harbor-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/harbor-setup.sh",
      "bash /tmp/harbor-setup.sh",
    ]
  }
}

# =============================================================================
# Nexus 설치 (remote-exec via SSH)
# =============================================================================
resource "null_resource" "install_nexus" {
  depends_on = [azurerm_linux_virtual_machine.nexus]

  triggers = {
    vm_id = azurerm_linux_virtual_machine.nexus.id
  }

  connection {
    type        = "ssh"
    user        = var.admin_username
    private_key = tls_private_key.infra_ssh.private_key_pem
    host        = azurerm_public_ip.nexus.ip_address
    timeout     = "15m"
  }

  provisioner "remote-exec" {
    inline = ["cloud-init status --wait"]
  }

  provisioner "file" {
    source      = "${path.module}/scripts/nexus-setup.sh"
    destination = "/tmp/nexus-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/nexus-setup.sh",
      "bash /tmp/nexus-setup.sh",
    ]
  }
}

# =============================================================================
# IP 저장 + Nexus 초기 admin 비밀번호 수집
# =============================================================================
resource "null_resource" "save_ips" {
  depends_on = [null_resource.install_harbor, null_resource.install_nexus]

  triggers = {
    harbor_ip = azurerm_public_ip.harbor.ip_address
    nexus_ip  = azurerm_public_ip.nexus.ip_address
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      ROOT_DIR="${path.module}/.."

      # ── 1. IP 저장 ────────────────────────────────────────────────────────
      mkdir -p "$ROOT_DIR/generated"
      echo '${azurerm_public_ip.harbor.ip_address}' > "$ROOT_DIR/generated/harbor-ip"
      echo '${azurerm_public_ip.nexus.ip_address}'  > "$ROOT_DIR/generated/nexus-ip"
      echo "Harbor IP: ${azurerm_public_ip.harbor.ip_address} → generated/harbor-ip"
      echo "Nexus  IP: ${azurerm_public_ip.nexus.ip_address}  → generated/nexus-ip"

      # ── 2. Nexus 초기 admin 비밀번호 저장 ────────────────────────────────
      echo ""
      echo "━━━ Nexus admin 비밀번호 저장 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      NEXUS_PASS=$(ssh -i "$ROOT_DIR/generated/azure-infra-key.pem" \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=15 \
        ${var.admin_username}@'${azurerm_public_ip.nexus.ip_address}' \
        "sudo cat /opt/nexus/data/admin.password 2>/dev/null || echo ''" 2>/dev/null || echo "")
      if [[ -n "$NEXUS_PASS" ]]; then
        echo "$NEXUS_PASS" > "$ROOT_DIR/generated/nexus-admin-password"
        chmod 600 "$ROOT_DIR/generated/nexus-admin-password"
        echo "✅ Nexus 초기 admin 비밀번호 → generated/nexus-admin-password"
      else
        echo "⚠️  비밀번호 파일 미생성 (Nexus 초기화 미완료일 수 있음) → 수동 확인:"
        echo "     ssh -i generated/azure-infra-key.pem ${var.admin_username}@\$(cat generated/nexus-ip)"
        echo "     sudo cat /opt/nexus/data/admin.password"
      fi
    EOT
  }
}

# =============================================================================
# K8s 노드 설정 + Mac /etc/hosts 자동 업데이트 (IP 파일 의존)
# =============================================================================
resource "null_resource" "configure_local" {
  depends_on = [null_resource.save_ips]

  triggers = {
    harbor_ip = azurerm_public_ip.harbor.ip_address
    nexus_ip  = azurerm_public_ip.nexus.ip_address
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      ROOT_DIR="${path.module}/.."

      # ── 1. K8s 노드 설정 (clusters.json 있을 때만 실행) ──────────────────
      echo "━━━ K8s 노드 설정 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      if [[ -f "$ROOT_DIR/generated/clusters.json" ]]; then
        bash "$ROOT_DIR/scripts/configure-k8s-for-azure-infra.sh"
      else
        echo "⚠️  clusters.json 없음 → K8s 클러스터 생성 후 수동 실행:"
        echo "     bash scripts/configure-k8s-for-azure-infra.sh"
      fi

      # ── 2. Mac /etc/hosts 자동 업데이트 시도 (sudo -n) ───────────────────
      echo ""
      echo "━━━ Mac /etc/hosts 업데이트 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      if sudo -n bash "$ROOT_DIR/scripts/update-hosts-mac.sh" 2>/dev/null; then
        echo "✅ Mac /etc/hosts 업데이트 완료"
      else
        echo "⚠️  sudo 권한 없음 → 수동으로 실행하세요:"
        echo "     sudo bash scripts/update-hosts-mac.sh"
      fi
    EOT
  }
}

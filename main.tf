# =============================================================================
# generated/ 디렉토리 사전 생성 (local_file 리소스가 디렉토리를 자동 생성하지 않음)
# =============================================================================
resource "null_resource" "ensure_generated_dir" {
  provisioner "local-exec" {
    command = "mkdir -p ${path.module}/generated"
  }
}

# =============================================================================
# 클러스터 설정 JSON (스크립트 DRY 소스)
# =============================================================================
resource "local_file" "cluster_config" {
  depends_on      = [null_resource.ensure_generated_dir]
  filename        = "${path.module}/generated/clusters.json"
  content         = local.clusters_json
  file_permission = "0644"
}

# =============================================================================
# Cloud-Init 파일 렌더링
# =============================================================================
resource "local_file" "cloud_init" {
  for_each = local.all_nodes

  depends_on = [null_resource.ensure_generated_dir]

  filename = "${path.module}/generated/cloud-init-${each.key}.yaml"
  content = templatefile("${path.module}/templates/cloud-init-k8s.yaml.tpl", {
    hostname     = each.key
    role         = each.value.role
    cluster_name = each.value.cluster_name
    pod_cidr     = each.value.pod_cidr
    service_cidr = each.value.service_cidr
    k8s_version  = var.k8s_version
  })
  file_permission = "0644"
}

# =============================================================================
# VM 생성 (6개 노드)
# =============================================================================
resource "null_resource" "vm" {
  for_each = local.all_nodes

  depends_on = [local_file.cloud_init]

  triggers = {
    vm_name         = each.key
    cloud_init_hash = local_file.cloud_init[each.key].content_md5
    image           = var.multipass_image
    mem             = each.value.mem
    disk            = each.value.disk
    cpus            = each.value.cpus
  }

  provisioner "local-exec" {
    when    = destroy
    command = "multipass delete ${self.triggers.vm_name} --purge 2>/dev/null || true"
  }

  provisioner "local-exec" {
    command = <<-EOT
      multipass launch ${var.multipass_image} \
        --name ${each.key} \
        --memory ${each.value.mem} \
        --disk ${each.value.disk} \
        --cpus ${each.value.cpus} \
        --cloud-init ${path.module}/generated/cloud-init-${each.key}.yaml
    EOT
  }
}

# =============================================================================
# 클러스터 초기화 (각 CP 노드에서 kubeadm init) - DRY with for_each
# =============================================================================
resource "null_resource" "init_cluster" {
  for_each = local.clusters

  depends_on = [null_resource.vm]

  triggers = {
    cp_vm_id    = null_resource.vm["${each.key}-cp"].id
    k8s_version = var.k8s_version
    pod_cidr    = each.value.pod_cidr
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/cluster-init.sh ${each.key} ${each.key}-cp"
  }
}

# =============================================================================
# Worker Join (각 클러스터별) - DRY with for_each
# =============================================================================
resource "null_resource" "join_cluster" {
  for_each = local.clusters

  depends_on = [null_resource.init_cluster]

  triggers = {
    init_id      = null_resource.init_cluster[each.key].id
    worker_vm_id = null_resource.vm["${each.key}-worker-0"].id
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/cluster-join.sh ${each.key} ${each.key}-cp ${each.key}-worker-0"
  }
}

# =============================================================================
# Kubeconfig 병합
# =============================================================================
resource "null_resource" "merge_kubeconfigs" {
  depends_on = [null_resource.join_cluster]

  triggers = {
    # 모든 클러스터의 join ID를 동적으로 생성
    join_ids = join(",", [for k, v in null_resource.join_cluster : v.id])
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/merge-kubeconfigs.sh"
  }
}

# =============================================================================
# Addon 전체 설치 (Phase 2 자동 실행)
# =============================================================================
resource "null_resource" "install_addons" {
  depends_on = [null_resource.merge_kubeconfigs, local_file.cluster_config]

  triggers = {
    merge_id      = null_resource.merge_kubeconfigs.id
    clusters_hash = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "export PATH=/opt/homebrew/bin:$PATH && bash ${path.module}/addons/install.sh --all --yes"
  }
}


/*  COMMENTED OUT — Azure Infra 연동 (별도 적용 시 주석 해제)
# =============================================================================
# Azure Infra 연동 삭제 (tofu destroy 시 azure-infra도 함께 삭제)
# =============================================================================
resource "null_resource" "destroy_azure_infra" {
  # path.module을 triggers에 저장 → destroy provisioner에서 self.triggers로 참조
  triggers = {
    azure_infra_dir = "${path.module}/azure-infra"
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -euo pipefail
      AZURE_DIR="${self.triggers.azure_infra_dir}"

      # state 또는 tfvars가 없으면 azure-infra가 미적용 상태 → 스킵
      if [[ ! -f "$AZURE_DIR/terraform.tfstate" ]] || [[ ! -f "$AZURE_DIR/terraform.tfvars" ]]; then
        echo "=== Azure Infra: state/tfvars 없음 → 스킵 (azure-infra 미적용) ==="
        exit 0
      fi

      echo ""
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "  Azure Infra 리소스 삭제 (Harbor VM + Nexus VM)"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      cd "$AZURE_DIR"

      # .terraform 디렉토리가 없으면 init 재실행 (캐시 삭제 등의 경우)
      if [[ ! -d ".terraform" ]]; then
        echo "tofu init 실행..."
        tofu init -upgrade
      fi

      tofu destroy -auto-approve
      echo "=== Azure Infra 리소스 삭제 완료 ==="
    EOT
  }
}
*/

# =============================================================================
# Cleanup fallback (개별 VM destroy provisioner 실패 시 안전망)
# =============================================================================
resource "null_resource" "cleanup" {
  triggers = {
    vm_names = join(",", keys(local.all_nodes))
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "=== Cleanup fallback: ensuring all VMs are deleted ==="
      for vm in $(echo "${self.triggers.vm_names}" | tr ',' ' '); do
        multipass delete "$vm" --purge 2>/dev/null || true
      done
      multipass purge 2>/dev/null || true
    EOT
  }
}

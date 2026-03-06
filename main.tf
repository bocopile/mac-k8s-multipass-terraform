# =============================================================================
# Phase 0: 사전 환경 체크 (실패 시 전체 중단)
# =============================================================================
resource "null_resource" "preflight_check" {
  triggers = {
    script_hash = filemd5("${path.module}/scripts/check-prerequisites.sh")
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/check-prerequisites.sh"
  }
}

# =============================================================================
# generated/ 디렉토리 사전 생성 (local_file 리소스가 디렉토리를 자동 생성하지 않음)
# =============================================================================
resource "null_resource" "ensure_generated_dir" {
  depends_on = [null_resource.preflight_check]

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
# Phase 2-A: 기반 인프라 Addon (CNI, LB, StorageClass, cert-manager)
# =============================================================================
resource "null_resource" "addons_infra" {
  depends_on = [null_resource.merge_kubeconfigs, local_file.cluster_config]

  triggers = {
    merge_id      = null_resource.merge_kubeconfigs.id
    clusters_hash = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = <<-EOT
      export PATH=/opt/homebrew/bin:$PATH
      bash ${path.module}/addons/install.sh \
        priority-classes local-path-provisioner cilium tetragon metallb gateway-api cert-manager \
        --yes
    EOT
  }
}

# =============================================================================
# Phase 2-B: Secrets & GitOps (Vault, ESO, ArgoCD)
# =============================================================================
resource "null_resource" "addons_secrets" {
  depends_on = [null_resource.addons_infra]

  triggers = {
    infra_id = null_resource.addons_infra.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      export PATH=/opt/homebrew/bin:$PATH
      bash ${path.module}/addons/install.sh vault eso argocd --yes
    EOT
  }
}

# =============================================================================
# Phase 2-C: Backup (MinIO → Velero)
# MinIO LB IP가 할당되어야 Velero가 S3 endpoint를 설정할 수 있음
# =============================================================================
resource "null_resource" "addons_backup" {
  depends_on = [null_resource.addons_infra]

  triggers = {
    infra_id = null_resource.addons_infra.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      export PATH=/opt/homebrew/bin:$PATH
      bash ${path.module}/addons/install.sh minio velero --yes
    EOT
  }
}

# =============================================================================
# Phase 2-D: Observability (Thanos → Prometheus → Loki → Tempo → Alloy)
# Thanos/Loki LB IP가 할당된 후 Alloy가 해당 IP로 remote_write 설정
# =============================================================================
resource "null_resource" "addons_observability" {
  depends_on = [null_resource.addons_backup]

  triggers = {
    backup_id = null_resource.addons_backup.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      export PATH=/opt/homebrew/bin:$PATH
      bash ${path.module}/addons/install.sh \
        thanos prometheus-stack loki tempo alloy \
        --yes
    EOT
  }
}

# =============================================================================
# Phase 2-E: Security & Service Mesh (Kyverno, Falco, Platform Addons, Istio)
# =============================================================================
resource "null_resource" "addons_security" {
  depends_on = [null_resource.addons_observability]

  triggers = {
    observability_id = null_resource.addons_observability.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      export PATH=/opt/homebrew/bin:$PATH
      bash ${path.module}/addons/install.sh \
        kyverno falco platform-addons istio kiali \
        --yes
    EOT
  }
}

# =============================================================================
# Phase 2-F: Istio Gateway + VirtualService + /etc/hosts 안내
# =============================================================================
resource "null_resource" "addons_gateway" {
  depends_on = [null_resource.addons_security]

  triggers = {
    security_id = null_resource.addons_security.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      export PATH=/opt/homebrew/bin:$PATH
      bash ${path.module}/scripts/apply-bocopile-gateway.sh || true
    EOT
  }
}

# =============================================================================
# Phase 3: 인프라 검증 (전체 구축 완료 후 자동 실행)
# =============================================================================
resource "null_resource" "verify_infra" {
  depends_on = [null_resource.addons_gateway]

  triggers = {
    gateway_id = null_resource.addons_gateway.id
  }

  provisioner "local-exec" {
    command = "export PATH=/opt/homebrew/bin:$PATH && bash ${path.module}/scripts/verify-infra.sh"
  }
}


# =============================================================================
# Cleanup fallback (개별 VM destroy provisioner 실패 시 안전망)
# =============================================================================
resource "null_resource" "cleanup" {
  triggers = {
    vm_names      = join(",", keys(local.all_nodes))
    generated_dir = "${path.module}/generated"
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set -uo pipefail
      echo ""
      echo "================================================================="
      echo "  Infrastructure Cleanup"
      echo "================================================================="

      # 1. VM 삭제 (안전망 — 개별 destroy provisioner 실패 시)
      echo ""
      echo "--- [1/4] Deleting VMs ---"
      for vm in $(echo "${self.triggers.vm_names}" | tr ',' ' '); do
        echo "  Deleting $vm..."
        multipass delete "$vm" --purge 2>/dev/null || true
      done
      multipass purge 2>/dev/null || true
      echo "  VMs deleted."

      # 2. generated/ 비관리 파일 정리 (tofu가 관리하는 파일 외)
      echo ""
      echo "--- [2/4] Cleaning generated/ directory ---"
      GENERATED="${self.triggers.generated_dir}"
      if [[ -d "$GENERATED" ]]; then
        rm -f "$GENERATED"/kubeconfig-* \
              "$GENERATED"/join-*.sh \
              "$GENERATED"/istio-operator-*.yaml \
              "$GENERATED"/alloy-config-*.alloy \
              "$GENERATED"/*-ip \
              "$GENERATED"/*-lb-ip \
              "$GENERATED"/vault-*.json \
              "$GENERATED"/vault-*.b64 \
              "$GENERATED"/vault-root-token \
              "$GENERATED"/credentials.env \
              "$GENERATED"/minio-ip \
              2>/dev/null || true
        echo "  Generated files cleaned."
      fi

      # 3. ~/kubeconfig-multi 삭제
      echo ""
      echo "--- [3/4] Removing ~/kubeconfig-multi ---"
      rm -f "$HOME/kubeconfig-multi" 2>/dev/null || true
      echo "  Done."

      # 4. /etc/hosts 안내
      echo ""
      echo "--- [4/4] /etc/hosts ---"
      if grep -q 'bocopile\.io' /etc/hosts 2>/dev/null; then
        echo "  WARNING: /etc/hosts에 bocopile.io 항목이 남아있습니다."
        echo "  수동 삭제: sudo sed -i '' '/bocopile\\.io/d' /etc/hosts"
      else
        echo "  Clean (no bocopile.io entries)."
      fi

      echo ""
      echo "================================================================="
      echo "  Cleanup complete."
      echo "================================================================="
    EOT
  }
}

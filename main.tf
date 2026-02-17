# =============================================================================
# 클러스터 설정 JSON (스크립트 DRY 소스)
# =============================================================================
resource "local_file" "cluster_config" {
  filename        = "${path.module}/generated/clusters.json"
  content         = local.clusters_json
  file_permission = "0644"
}

# =============================================================================
# Cloud-Init 파일 렌더링
# =============================================================================
resource "local_file" "cloud_init" {
  for_each = local.all_nodes

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
# 클러스터 초기화 (각 CP 노드에서 kubeadm init)
# =============================================================================
resource "null_resource" "init_mgmt" {
  depends_on = [null_resource.vm]

  triggers = {
    cp_vm_id    = null_resource.vm["mgmt-cp"].id
    k8s_version = var.k8s_version
    pod_cidr    = local.clusters["mgmt"].pod_cidr
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/cluster-init.sh mgmt mgmt-cp"
  }
}

resource "null_resource" "init_app1" {
  depends_on = [null_resource.vm]

  triggers = {
    cp_vm_id    = null_resource.vm["app1-cp"].id
    k8s_version = var.k8s_version
    pod_cidr    = local.clusters["app1"].pod_cidr
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/cluster-init.sh app1 app1-cp"
  }
}

resource "null_resource" "init_app2" {
  depends_on = [null_resource.vm]

  triggers = {
    cp_vm_id    = null_resource.vm["app2-cp"].id
    k8s_version = var.k8s_version
    pod_cidr    = local.clusters["app2"].pod_cidr
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/cluster-init.sh app2 app2-cp"
  }
}

# =============================================================================
# Worker Join (각 클러스터별)
# =============================================================================
resource "null_resource" "join_mgmt" {
  depends_on = [null_resource.init_mgmt]

  triggers = {
    init_id      = null_resource.init_mgmt.id
    worker_vm_id = null_resource.vm["mgmt-worker-0"].id
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/cluster-join.sh mgmt mgmt-cp mgmt-worker-0"
  }
}

resource "null_resource" "join_app1" {
  depends_on = [null_resource.init_app1]

  triggers = {
    init_id      = null_resource.init_app1.id
    worker_vm_id = null_resource.vm["app1-worker-0"].id
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/cluster-join.sh app1 app1-cp app1-worker-0"
  }
}

resource "null_resource" "join_app2" {
  depends_on = [null_resource.init_app2]

  triggers = {
    init_id      = null_resource.init_app2.id
    worker_vm_id = null_resource.vm["app2-worker-0"].id
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/cluster-join.sh app2 app2-cp app2-worker-0"
  }
}

# =============================================================================
# Kubeconfig 병합
# =============================================================================
resource "null_resource" "merge_kubeconfigs" {
  depends_on = [
    null_resource.join_mgmt,
    null_resource.join_app1,
    null_resource.join_app2,
  ]

  triggers = {
    join_mgmt_id = null_resource.join_mgmt.id
    join_app1_id = null_resource.join_app1.id
    join_app2_id = null_resource.join_app2.id
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/merge-kubeconfigs.sh"
  }
}

# =============================================================================
# Cilium CNI 설치 (3개 클러스터)
# =============================================================================
resource "null_resource" "install_cilium" {
  depends_on = [null_resource.merge_kubeconfigs, local_file.cluster_config]

  triggers = {
    merge_id       = null_resource.merge_kubeconfigs.id
    cilium_version = var.cilium_version
    clusters_hash  = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/install-cilium.sh ${var.cilium_version}"
  }
}

# =============================================================================
# MetalLB 설치 (3개 클러스터)
# =============================================================================
resource "null_resource" "install_metallb" {
  depends_on = [null_resource.install_cilium, local_file.cluster_config]

  triggers = {
    cilium_id       = null_resource.install_cilium.id
    metallb_version = var.metallb_version
    clusters_hash   = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/install-metallb.sh ${var.metallb_version}"
  }
}

# =============================================================================
# Cilium Cluster Mesh 설정
# =============================================================================
resource "null_resource" "setup_clustermesh" {
  depends_on = [null_resource.install_metallb, local_file.cluster_config]

  triggers = {
    metallb_id    = null_resource.install_metallb.id
    clusters_hash = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/setup-clustermesh.sh"
  }
}

# =============================================================================
# Tetragon eBPF 런타임 보안 (전 클러스터 DaemonSet)
# =============================================================================
resource "null_resource" "install_tetragon" {
  depends_on = [null_resource.install_cilium, local_file.cluster_config]

  triggers = {
    cilium_id        = null_resource.install_cilium.id
    tetragon_version = var.tetragon_version
    clusters_hash    = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/install-tetragon.sh ${var.tetragon_version}"
  }
}

# =============================================================================
# 플랫폼 부가 도구 (mgmt 클러스터: Trivy, K8sGPT, OpenCost, VPA, Chaos Mesh)
# =============================================================================
resource "null_resource" "install_platform_addons" {
  depends_on = [
    null_resource.setup_clustermesh,
    null_resource.install_tetragon,
    local_file.cluster_config,
  ]

  triggers = {
    clustermesh_id = null_resource.setup_clustermesh.id
    tetragon_id    = null_resource.install_tetragon.id
    clusters_hash  = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/install-platform-addons.sh"
  }
}

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

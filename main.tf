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

/*  ARCHIVED — Terraform-managed addon installation (moved to addons/install.sh)
    Run after infrastructure: bash addons/install.sh --all
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
    command = "bash ${path.module}/addons/scripts/install-cilium.sh ${var.cilium_version}"
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
    command = "bash ${path.module}/addons/scripts/install-metallb.sh ${var.metallb_version}"
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
    command = "bash ${path.module}/addons/scripts/setup-clustermesh.sh"
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
    command = "bash ${path.module}/addons/scripts/install-tetragon.sh ${var.tetragon_version}"
  }
}

# =============================================================================
# Gateway API CRD + Cilium Gateway 활성화 (전 클러스터)
# =============================================================================
resource "null_resource" "install_gateway_api" {
  depends_on = [null_resource.install_cilium, local_file.cluster_config]

  triggers = {
    cilium_id     = null_resource.install_cilium.id
    clusters_hash = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/addons/scripts/install-gateway-api.sh"
  }
}

# =============================================================================
# cert-manager (전 클러스터, Phase 1: Self-signed) — ADR-004
# =============================================================================
resource "null_resource" "install_cert_manager" {
  depends_on = [null_resource.setup_clustermesh, local_file.cluster_config]

  triggers = {
    clustermesh_id       = null_resource.setup_clustermesh.id
    cert_manager_version = var.cert_manager_version
    clusters_hash        = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/addons/scripts/install-cert-manager.sh ${var.cert_manager_version}"
  }
}

# =============================================================================
# 플랫폼 부가 도구 (mgmt: Trivy, K8sGPT, OpenCost, VPA, Chaos Mesh, local-path-retain)
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
    command = "bash ${path.module}/addons/scripts/install-platform-addons.sh"
  }
}

# =============================================================================
# Thanos Receive + Query (mgmt 클러스터) — ADR-006
# =============================================================================
resource "null_resource" "install_thanos" {
  depends_on = [
    null_resource.install_platform_addons,
    local_file.cluster_config,
  ]

  triggers = {
    platform_addons_id = null_resource.install_platform_addons.id
    clusters_hash      = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/addons/scripts/install-thanos.sh"
  }
}

# =============================================================================
# External Secrets Operator (전 클러스터) — C3
# =============================================================================
resource "null_resource" "install_eso" {
  depends_on = [
    null_resource.install_cert_manager,
    null_resource.install_vault,
    local_file.cluster_config,
  ]

  triggers = {
    cert_manager_id = null_resource.install_cert_manager.id
    vault_id        = null_resource.install_vault.id
    clusters_hash   = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/addons/scripts/install-eso.sh"
  }
}

# =============================================================================
# OpenSearch (mgmt 클러스터) — 감사·보안 로그 검색 분석
# =============================================================================
resource "null_resource" "install_opensearch" {
  depends_on = [
    null_resource.install_loki,
    local_file.cluster_config,
  ]

  triggers = {
    loki_id            = null_resource.install_loki.id
    opensearch_version = var.opensearch_version
    clusters_hash      = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/addons/scripts/install-opensearch.sh ${var.opensearch_version}"
  }
}

# =============================================================================
# Grafana Alloy (전 클러스터) — ADR-006, C2
# Promtail + Prometheus Agent + OTel Collector 통합 에이전트
# OpenSearch 설치 후 선별 로그 이중화 활성화
# =============================================================================
resource "null_resource" "install_alloy" {
  depends_on = [
    null_resource.install_thanos,
    null_resource.install_loki,
    null_resource.install_tempo,
    null_resource.install_opensearch,
    local_file.cluster_config,
  ]

  triggers = {
    thanos_id          = null_resource.install_thanos.id
    loki_id            = null_resource.install_loki.id
    tempo_id           = null_resource.install_tempo.id
    opensearch_id      = null_resource.install_opensearch.id
    alloy_version      = var.alloy_version
    clusters_hash      = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/addons/scripts/install-alloy.sh"
  }
}

# =============================================================================
# Kyverno (app 클러스터만) — ADR-003, C4
# =============================================================================
resource "null_resource" "install_kyverno" {
  depends_on = [null_resource.setup_clustermesh, local_file.cluster_config]

  triggers = {
    clustermesh_id  = null_resource.setup_clustermesh.id
    kyverno_version = var.kyverno_version
    clusters_hash   = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/addons/scripts/install-kyverno.sh ${var.kyverno_version}"
  }
}

# =============================================================================
# Falco 런타임 보안 (app 클러스터만) — L5
# =============================================================================
resource "null_resource" "install_falco" {
  depends_on = [null_resource.setup_clustermesh, local_file.cluster_config]

  triggers = {
    clustermesh_id = null_resource.setup_clustermesh.id
    falco_version  = var.falco_version
    clusters_hash  = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/addons/scripts/install-falco.sh ${var.falco_version}"
  }
}

# =============================================================================
# MinIO 백업 저장소 (mgmt 클러스터)
# =============================================================================
resource "null_resource" "install_minio" {
  depends_on = [
    null_resource.install_platform_addons,
    local_file.cluster_config,
  ]

  triggers = {
    platform_addons_id = null_resource.install_platform_addons.id
    clusters_hash      = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/addons/scripts/install-minio.sh"
  }
}

# =============================================================================
# Velero 백업 (전 클러스터 → MinIO) — §10
# =============================================================================
resource "null_resource" "install_velero" {
  depends_on = [
    null_resource.install_minio,
    local_file.cluster_config,
  ]

  triggers = {
    minio_id      = null_resource.install_minio.id
    clusters_hash = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/addons/scripts/install-velero.sh"
  }
}

# =============================================================================
# Vault 시크릿 관리 (mgmt 클러스터) — ADR-004, C5
# =============================================================================
resource "null_resource" "install_vault" {
  depends_on = [
    null_resource.install_platform_addons,
    local_file.cluster_config,
  ]

  triggers = {
    platform_addons_id = null_resource.install_platform_addons.id
    clusters_hash      = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/addons/scripts/install-vault.sh"
  }
}

# =============================================================================
# kube-prometheus-stack (mgmt: Prometheus Full + Grafana + Alertmanager) — ADR-006
# =============================================================================
resource "null_resource" "install_prometheus_stack" {
  depends_on = [
    null_resource.install_platform_addons,
    local_file.cluster_config,
  ]

  triggers = {
    platform_addons_id = null_resource.install_platform_addons.id
    clusters_hash      = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/addons/scripts/install-prometheus-stack.sh"
  }
}

# =============================================================================
# Loki + Promtail 로그 수집 (mgmt: Loki, 전 클러스터: Promtail) — ADR-006
# =============================================================================
resource "null_resource" "install_loki" {
  depends_on = [
    null_resource.install_prometheus_stack,
    local_file.cluster_config,
  ]

  triggers = {
    prometheus_stack_id = null_resource.install_prometheus_stack.id
    clusters_hash       = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/addons/scripts/install-loki.sh"
  }
}

# =============================================================================
# ArgoCD GitOps 컨트롤러 (mgmt 클러스터) — §1.3
# =============================================================================
resource "null_resource" "install_argocd" {
  depends_on = [
    null_resource.setup_clustermesh,
    local_file.cluster_config,
  ]

  triggers = {
    clustermesh_id = null_resource.setup_clustermesh.id
    argocd_version = var.argocd_version
    clusters_hash  = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/addons/scripts/install-argocd.sh"
  }
}

# =============================================================================
# Vault PKI Phase 2 전환 (Istio Gateway 인증서용) — ADR-004, ADR-007
# =============================================================================
resource "null_resource" "setup_vault_pki" {
  depends_on = [
    null_resource.install_vault,
    null_resource.install_cert_manager,
    local_file.cluster_config,
  ]

  triggers = {
    vault_id        = null_resource.install_vault.id
    cert_manager_id = null_resource.install_cert_manager.id
    clusters_hash   = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/addons/scripts/setup-vault-pki.sh"
  }
}

# =============================================================================
# Istio Service Mesh (mgmt + app1 클러스터) — ADR-007
# =============================================================================
resource "null_resource" "install_istio" {
  depends_on = [
    null_resource.install_gateway_api,
    null_resource.setup_vault_pki,
    local_file.cluster_config,
  ]

  triggers = {
    gateway_api_id = null_resource.install_gateway_api.id
    vault_pki_id   = null_resource.setup_vault_pki.id
    istio_version  = var.istio_version
    clusters_hash  = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/addons/scripts/install-istio.sh ${var.istio_version}"
  }
}

# =============================================================================
# Observability Stack - Distributed Tracing
# =============================================================================
# Grafana Tempo (분산 추적 백엔드, mgmt 클러스터)
resource "null_resource" "install_tempo" {
  depends_on = [
    null_resource.install_prometheus_stack,
    local_file.cluster_config,
  ]

  triggers = {
    prometheus_id = null_resource.install_prometheus_stack.id
    tempo_version = var.tempo_version
    clusters_hash = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/addons/scripts/install-tempo.sh ${var.tempo_version}"
  }
}

# Kiali (Istio Service Mesh 관찰성 대시보드, mgmt + app1 클러스터)
resource "null_resource" "install_kiali" {
  depends_on = [
    null_resource.install_istio,
    null_resource.install_alloy,
    null_resource.install_prometheus_stack,
    local_file.cluster_config,
  ]

  triggers = {
    istio_id      = null_resource.install_istio.id
    alloy_id      = null_resource.install_alloy.id
    prometheus_id = null_resource.install_prometheus_stack.id
    kiali_version = var.kiali_version
    clusters_hash = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/addons/scripts/install-kiali.sh ${var.kiali_version}"
  }
}

# =============================================================================
# AI 운영 도구 (Kubernetes 클러스터 관리 자동화)
# =============================================================================
# K8sGPT - 클러스터 문제 자동 진단
resource "null_resource" "install_k8sgpt" {
  depends_on = [
    null_resource.install_platform_addons, # K8sGPT Operator 포함
    local_file.cluster_config,
  ]

  triggers = {
    platform_addons_id = null_resource.install_platform_addons.id
    clusters_hash      = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/addons/scripts/install-k8sgpt.sh"
  }
}

# HolmesGPT (Robusta) - AI 기반 알림 자동 조사
resource "null_resource" "install_holmesgpt" {
  depends_on = [
    null_resource.install_prometheus_stack,
    null_resource.install_loki,
    null_resource.install_tempo,
    null_resource.install_k8sgpt, # LocalAI 재사용
    local_file.cluster_config,
  ]

  triggers = {
    prometheus_id    = null_resource.install_prometheus_stack.id
    loki_id          = null_resource.install_loki.id
    tempo_id         = null_resource.install_tempo.id
    k8sgpt_id        = null_resource.install_k8sgpt.id
    robusta_version  = var.robusta_version
    clusters_hash    = md5(local.clusters_json)
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/addons/scripts/install-holmesgpt.sh"
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

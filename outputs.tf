output "clusters" {
  description = "클러스터 정보 요약"
  value = {
    for name, cluster in local.clusters : name => {
      id           = cluster.id
      pod_cidr     = cluster.pod_cidr
      service_cidr = cluster.service_cidr
      metallb_pool = cluster.metallb_pool
      cp_node      = local.cluster_cp_map[name]
      worker_nodes = local.cluster_worker_map[name]
    }
  }
}

output "all_vm_names" {
  description = "생성되는 전체 VM 이름 목록"
  value       = keys(local.all_nodes)
}

output "kubeconfig_path" {
  description = "병합된 kubeconfig 경로"
  value       = pathexpand("~/kubeconfig-multi")
}

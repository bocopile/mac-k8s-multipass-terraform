locals {
  clusters = {
    mgmt = {
      name         = "mgmt"
      id           = 1
      pod_cidr     = "10.100.0.0/16"
      service_cidr = "10.96.0.0/16"
      metallb_pool = "192.168.64.200-192.168.64.210"
      nodes = {
        "mgmt-cp" = {
          role = "control-plane"
          mem  = "4G"
          disk = "40G"
          cpus = 2
        }
        "mgmt-worker-0" = {
          role = "worker"
          mem  = "12G"
          disk = "60G"
          cpus = 4
        }
      }
    }
    app1 = {
      name         = "app1"
      id           = 2
      pod_cidr     = "10.101.0.0/16"
      service_cidr = "10.97.0.0/16"
      metallb_pool = "192.168.64.211-192.168.64.220"
      nodes = {
        "app1-cp" = {
          role = "control-plane"
          mem  = "3G"
          disk = "30G"
          cpus = 2
        }
        "app1-worker-0" = {
          role = "worker"
          mem  = "4G"
          disk = "40G"
          cpus = 2
        }
      }
    }
    # app2 클러스터 제거 — 리소스 절약 (4CPU/7GB → mgmt에 재분배)
  }

  # Flatten all nodes with cluster context
  all_nodes = merge([
    for cluster_key, cluster in local.clusters : {
      for node_name, node in cluster.nodes :
      node_name => merge(node, {
        cluster_name = cluster.name
        cluster_id   = cluster.id
        pod_cidr     = cluster.pod_cidr
        service_cidr = cluster.service_cidr
        metallb_pool = cluster.metallb_pool
      })
    }
  ]...)

  cp_nodes = {
    for name, node in local.all_nodes :
    name => node if node.role == "control-plane"
  }

  worker_nodes = {
    for name, node in local.all_nodes :
    name => node if node.role == "worker"
  }

  # Map cluster name to its CP node name
  cluster_cp_map = {
    for name, node in local.cp_nodes :
    node.cluster_name => name
  }

  # 스크립트용 클러스터 설정 JSON (DRY: 단일 소스)
  clusters_json = jsonencode({
    for name, cluster in local.clusters : name => {
      id           = cluster.id
      pod_cidr     = cluster.pod_cidr
      service_cidr = cluster.service_cidr
      metallb_pool = cluster.metallb_pool
      nodes        = keys(cluster.nodes)
      cp_node = [
        for node_name, node in cluster.nodes :
        node_name if node.role == "control-plane"
      ][0]
      worker_nodes = [
        for node_name, node in cluster.nodes :
        node_name if node.role == "worker"
      ]
    }
  })

  # Map cluster name to its worker node names
  cluster_worker_map = {
    for cluster_key, cluster in local.clusters :
    cluster_key => [
      for node_name, node in cluster.nodes :
      node_name if node.role == "worker"
    ]
  }
}

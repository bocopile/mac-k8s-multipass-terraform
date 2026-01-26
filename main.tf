
resource "null_resource" "masters" {
  count = var.masters

  provisioner "local-exec" {
    command = "multipass launch ${var.multipass_image} --name k8s-master-${count.index} --mem 4G --disk 40G --cpus 2 --cloud-init init/k8s.yaml"
  }
}

resource "null_resource" "workers" {
  depends_on = [null_resource.masters]
  count = var.workers

  provisioner "local-exec" {
    command = "multipass launch ${var.multipass_image} --name k8s-worker-${count.index} --mem 4G --disk 50G --cpus 2 --cloud-init init/k8s.yaml"
  }
}


resource "null_resource" "init_cluster" {
  depends_on = [null_resource.workers]

  provisioner "local-exec" {
    command = <<EOT
      multipass transfer ./shell/cluster-init.sh k8s-master-0:/home/ubuntu/cluster-init.sh
      multipass exec k8s-master-0 -- bash -c "chmod +x /home/ubuntu/cluster-init.sh && sudo bash /home/ubuntu/cluster-init.sh"
    EOT
  }
}

resource "null_resource" "join_all" {
  depends_on = [null_resource.init_cluster]
  provisioner "local-exec" {
    command = "bash shell/join-all.sh"
  }
}


resource "null_resource" "cleanup" {
  triggers = {
    always_run = "${timestamp()}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<EOT
      multipass delete --all && multipass purge
    EOT
  }
}

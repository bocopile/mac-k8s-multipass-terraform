
#!/bin/bash

# Master-0에서 join 스크립트 추출
multipass transfer k8s-master-0:/home/ubuntu/join.sh ./shell/join.sh
multipass transfer k8s-master-0:/home/ubuntu/join-controlplane.sh ./shell/join-controlplane.sh

# Control Plane Join (1, 2)
for i in 1 2; do
  multipass transfer ./shell/join-controlplane.sh k8s-master-${i}:/home/ubuntu/join-controlplane.sh
  multipass exec k8s-master-${i} -- bash -c "chmod +x /home/ubuntu/join-controlplane.sh && sudo bash /home/ubuntu/join-controlplane.sh"
done

# Worker Join (0 ~ 2)
for i in {0..2}; do
  multipass transfer ./shell/join.sh k8s-worker-${i}:/home/ubuntu/join.sh
  multipass exec k8s-worker-${i} -- bash -c "chmod +x /home/ubuntu/join.sh && sudo bash /home/ubuntu/join.sh"
done

multipass exec k8s-master-0 -- bash -c "\
  sudo mkdir -p /home/ubuntu/.kube && \
  sudo cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config && \
  sudo chown ubuntu:ubuntu /home/ubuntu/.kube/config"

multipass transfer k8s-master-0:/home/ubuntu/.kube/config ~/kubeconfig

echo 'export KUBECONFIG=~/kubeconfig' >> ~/.zshrc
source ~/.zshrc

rm -rf ./shell/join-controlplane.sh
rm -rf ./shell/join.sh

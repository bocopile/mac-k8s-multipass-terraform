
#!/bin/bash

if hostname | grep -q "k8s-master-0"; then
  MASTER_IP=$(hostname -I | awk '{print $1}')

  kubeadm init \
    --control-plane-endpoint "${MASTER_IP}:6443" \
    --upload-certs \
    --pod-network-cidr=10.244.0.0/16

  mkdir -p $HOME/.kube
  cp /etc/kubernetes/admin.conf $HOME/.kube/config
  chown $(id -u):$(id -g) $HOME/.kube/config

  kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml

  JOIN_CMD=$(kubeadm token create --print-join-command)
  echo "sudo $JOIN_CMD" > /home/ubuntu/join.sh
  chmod +x /home/ubuntu/join.sh


  kubeadm token create --print-join-command --certificate-key $(kubeadm init phase upload-certs --upload-certs | tail -n1) > /home/ubuntu/join-controlplane.sh
  CERT_KEY=$(kubeadm init phase upload-certs --upload-certs | tail -n1)
  JOIN_CP_CMD=$(kubeadm token create --print-join-command --certificate-key $CERT_KEY)
  echo "sudo $JOIN_CP_CMD" > /home/ubuntu/join-controlplane.sh
  chmod +x /home/ubuntu/join-controlplane.sh
fi

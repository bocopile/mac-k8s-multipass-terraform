#cloud-config
# NOTE: Ubuntu 24.04 ships containerd 1.7.x (last version supported by k8s 1.35).
#       For k8s 1.36+, containerd 2.0+ from Docker's official repo will be required.
package_update: true
package_upgrade: true
packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - lsb-release
  - containerd
  - net-tools
  - jq

hostname: ${hostname}
manage_etc_hosts: true

write_files:
  - path: /etc/modules-load.d/k8s.conf
    content: |
      overlay
      br_netfilter

  - path: /etc/sysctl.d/99-k8s.conf
    content: |
      net.bridge.bridge-nf-call-iptables = 1
      net.ipv4.ip_forward = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      fs.inotify.max_user_instances = 512
      fs.inotify.max_user_watches = 524288

%{ if role == "control-plane" ~}
  - path: /etc/kubernetes/psa/admission-config.yaml
    content: |
      apiVersion: apiserver.config.k8s.io/v1
      kind: AdmissionConfiguration
      plugins:
        - name: PodSecurity
          configuration:
            apiVersion: pod-security.admission.config.k8s.io/v1
            kind: PodSecurityConfiguration
            defaults:
              enforce: "baseline"
              enforce-version: "latest"
              audit: "restricted"
              audit-version: "latest"
              warn: "restricted"
              warn-version: "latest"
            exemptions:
              namespaces:
                - kube-system
                - cilium-system
                - monitoring
                - vault

  - path: /home/ubuntu/kubeadm-config.yaml
    content: |
      apiVersion: kubeadm.k8s.io/v1beta4
      kind: ClusterConfiguration
      clusterName: ${cluster_name}
      kubernetesVersion: stable-${k8s_version}
      controlPlaneEndpoint: "CP_IP:6443"
      networking:
        podSubnet: "${pod_cidr}"
        serviceSubnet: "${service_cidr}"
      apiServer:
        extraArgs:
          - name: admission-control-config-file
            value: /etc/kubernetes/psa/admission-config.yaml
        extraVolumes:
          - name: psa-config
            hostPath: /etc/kubernetes/psa
            mountPath: /etc/kubernetes/psa
            readOnly: true
      controllerManager:
        extraArgs:
          - name: bind-address
            value: "0.0.0.0"
      scheduler:
        extraArgs:
          - name: bind-address
            value: "0.0.0.0"
      etcd:
        local:
          extraArgs:
            - name: listen-metrics-urls
              value: "http://0.0.0.0:2381"
      ---
      apiVersion: kubeadm.k8s.io/v1beta4
      kind: InitConfiguration
      skipPhases:
        - addon/kube-proxy
%{ endif ~}

runcmd:
  - modprobe overlay
  - modprobe br_netfilter
  - sysctl --system
  - mkdir -p /etc/apt/keyrings
  - curl -fsSL https://pkgs.k8s.io/core:/stable:/v${k8s_version}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  - echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${k8s_version}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
  - apt-get update
  - apt-get install -y kubelet kubeadm kubectl
  - apt-mark hold kubelet kubeadm kubectl
  - mkdir -p /etc/containerd
  - containerd config default > /etc/containerd/config.toml
  - sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  # insecure registry를 위한 certs.d 디렉토리 방식 활성화
  - sed -i 's|config_path = ""|config_path = "/etc/containerd/certs.d"|' /etc/containerd/config.toml
  - mkdir -p /etc/containerd/certs.d
  - systemctl restart containerd
  - systemctl enable containerd
  - systemctl enable kubelet
%{ if role == "control-plane" ~}
  - |
    CP_IP=$(hostname -I | awk '{print $1}')
    sed -i "s/CP_IP:6443/$${CP_IP}:6443/" /home/ubuntu/kubeadm-config.yaml
%{ endif ~}

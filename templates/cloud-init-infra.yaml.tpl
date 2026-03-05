#cloud-config
# Infra VM cloud-init (Harbor / Nexus)
# K8s 미포함 - Docker CE + Docker Compose만 설치

package_update: true
package_upgrade: true
packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - lsb-release
  - jq
  - wget
  - net-tools
  - openssl

hostname: ${hostname}
manage_etc_hosts: true

write_files:
  - path: /opt/${service}/.keep
    content: ""

runcmd:
  # Docker 공식 GPG 키 등록
  - mkdir -p /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  - chmod a+r /etc/apt/keyrings/docker.gpg
  # Docker 공식 저장소 추가
  - echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  # Docker CE 설치
  - apt-get update
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  - systemctl enable docker
  - systemctl start docker
  # ubuntu 사용자를 docker 그룹에 추가
  - usermod -aG docker ubuntu
  # 데이터 디렉토리 생성
  - mkdir -p /opt/${service}/data
  - chown -R ubuntu:ubuntu /opt/${service}

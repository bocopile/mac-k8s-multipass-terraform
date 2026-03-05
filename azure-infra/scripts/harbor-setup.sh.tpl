#!/bin/bash
set -euo pipefail

# Harbor 설치 스크립트 (Azure VM 내부 실행)
# Terraform templatefile로 변수 주입됨

HARBOR_VERSION="${harbor_version}"
HARBOR_IP="${harbor_ip}"
HARBOR_ADMIN_PASSWORD="${harbor_admin_password}"
HARBOR_DATA_DIR="/opt/harbor/data"

echo "========================================="
echo "Harbor ${HARBOR_VERSION} Installation"
echo "IP: ${HARBOR_IP}"
echo "========================================="

# Docker 준비 확인
echo "[1/4] Checking Docker..."
docker info > /dev/null 2>&1 || { echo "ERROR: Docker not ready"; exit 1; }
docker compose version > /dev/null 2>&1 || { echo "ERROR: Docker Compose not ready"; exit 1; }
echo "  Docker OK"

# Harbor online installer 다운로드
echo "[2/4] Downloading Harbor $${HARBOR_VERSION}..."
cd /tmp
wget -q "https://github.com/goharbor/harbor/releases/download/$${HARBOR_VERSION}/harbor-online-installer-$${HARBOR_VERSION}.tgz"
tar xzf "harbor-online-installer-$${HARBOR_VERSION}.tgz"
cd /tmp/harbor

# harbor.yml 설정
echo "[3/4] Configuring harbor.yml..."
cp harbor.yml.tmpl harbor.yml

# hostname: Azure 공인 IP 사용
sed -i "s|hostname: reg.mydomain.com|hostname: $${HARBOR_IP}|" harbor.yml

# HTTPS 비활성화 (로컬 개발 환경)
python3 - << 'PYEOF'
import re
with open('harbor.yml', 'r') as f:
    c = f.read()
c = re.sub(r'^(https:)', r'#\1', c, flags=re.MULTILINE)
c = re.sub(r'^(  port: 443)',       r'#\1', c, flags=re.MULTILINE)
c = re.sub(r'^(  certificate: .*)', r'#\1', c, flags=re.MULTILINE)
c = re.sub(r'^(  private_key: .*)', r'#\1', c, flags=re.MULTILINE)
with open('harbor.yml', 'w') as f:
    f.write(c)
PYEOF

# admin 비밀번호
sed -i "s|harbor_admin_password: Harbor12345|harbor_admin_password: $${HARBOR_ADMIN_PASSWORD}|" harbor.yml

# 데이터 경로
sed -i "s|data_volume: /data|data_volume: $${HARBOR_DATA_DIR}|" harbor.yml

sudo mkdir -p "$${HARBOR_DATA_DIR}"

# Harbor 설치 및 시작
echo "[4/4] Installing and starting Harbor..."
sudo bash install.sh

echo ""
echo "========================================="
echo "Harbor installation complete!"
echo "  URL:   http://$${HARBOR_IP}"
echo "  Admin: admin / $${HARBOR_ADMIN_PASSWORD}"
echo "========================================="

#!/bin/bash
set -euo pipefail

# Nexus Repository Manager 3 설치 스크립트 (Azure VM 내부 실행)

NEXUS_DATA_DIR="/opt/nexus/data"

echo "========================================="
echo "Nexus Repository Manager Installation"
echo "========================================="

# Docker 준비 확인
echo "[1/3] Checking Docker..."
docker info > /dev/null 2>&1 || { echo "ERROR: Docker not ready"; exit 1; }
echo "  Docker OK"

# 데이터 디렉토리 생성 (Nexus 컨테이너 UID=200)
echo "[2/3] Preparing data directory..."
sudo mkdir -p "${NEXUS_DATA_DIR}"
sudo chown -R 200:200 "${NEXUS_DATA_DIR}"

# Docker Compose 파일 생성
echo "[3/3] Starting Nexus with Docker Compose..."
sudo mkdir -p /opt/nexus
sudo tee /opt/nexus/docker-compose.yml > /dev/null << 'COMPOSE'
services:
  nexus:
    image: sonatype/nexus3:latest
    container_name: nexus
    restart: unless-stopped
    ports:
      - "8081:8081"
      - "8082:8082"
      - "8083:8083"
    volumes:
      - /opt/nexus/data:/nexus-data
    environment:
      - INSTALL4J_ADD_VM_PARAMS=-Xms1g -Xmx2g -XX:MaxDirectMemorySize=2g
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8081/service/rest/v1/status"]
      interval: 30s
      timeout: 10s
      retries: 15
      start_period: 120s
COMPOSE

cd /opt/nexus
sudo docker compose up -d

# 시작 대기
echo ""
echo "Waiting for Nexus to start (up to 3 minutes)..."
for i in $(seq 1 36); do
  if curl -sf "http://localhost:8081/service/rest/v1/status" > /dev/null 2>&1; then
    echo "  Nexus is up!"
    break
  fi
  printf "  Waiting... (%d/36)\r" "$i"
  sleep 5
done

# 초기 admin 비밀번호 출력
ADMIN_PASS=$(sudo cat /opt/nexus/data/admin.password 2>/dev/null || echo "")
echo ""
echo "========================================="
echo "Nexus installation complete!"
echo "  URL:   http://$(hostname -I | awk '{print $1}'):8081"
if [[ -n "$ADMIN_PASS" ]]; then
  echo "  Admin: admin / ${ADMIN_PASS}  (초기 비밀번호 - 첫 로그인 후 변경 필요)"
else
  echo "  Admin: admin / <sudo cat /opt/nexus/data/admin.password>"
fi
echo "========================================="

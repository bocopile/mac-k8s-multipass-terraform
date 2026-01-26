#!/bin/bash
set -e
LOGFILE="/home/ubuntu/redis-install.log"
exec > >(tee -a $LOGFILE) 2>&1

echo "[REDIS] Configuring Redis with password..."
REDIS_CONF="/etc/redis/redis.conf"

sudo sed -i "s/^# requirepass .*/requirepass $1/" $REDIS_CONF
sudo systemctl restart redis-server
echo "[REDIS] Redis configured and restarted."
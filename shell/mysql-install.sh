#!/bin/bash
set -euo pipefail
LOGFILE="/home/ubuntu/mysql-install.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "[MYSQL] Securing MySQL installation..."

# Security: Use MYSQL_PWD environment variable to avoid password exposure in process list
# Set root password and create database/user
sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$1'; FLUSH PRIVILEGES;"

# Use MYSQL_PWD to avoid command-line password exposure
export MYSQL_PWD="$1"
sudo -E mysql -uroot -e "CREATE DATABASE IF NOT EXISTS $2;"
sudo -E mysql -uroot -e "CREATE USER IF NOT EXISTS '$3'@'%' IDENTIFIED WITH mysql_native_password BY '$4';"
sudo -E mysql -uroot -e "GRANT ALL PRIVILEGES ON $2.* TO '$3'@'%'; FLUSH PRIVILEGES;"
unset MYSQL_PWD

echo "[MYSQL] MySQL root password, user, and database configured."
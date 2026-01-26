#!/bin/bash
set -e
LOGFILE="/home/ubuntu/mysql-install.log"
exec > >(tee -a $LOGFILE) 2>&1

echo "[MYSQL] Securing MySQL installation..."

# Set root password and create database/user
sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$1'; FLUSH PRIVILEGES;"
sudo mysql -uroot -p$1 -e "CREATE DATABASE IF NOT EXISTS $2;"
sudo mysql -uroot -p$1 -e "CREATE USER IF NOT EXISTS '$3'@'%' IDENTIFIED WITH mysql_native_password BY '$4';"
sudo mysql -uroot -p$1 -e "GRANT ALL PRIVILEGES ON $2.* TO '$3'@'%'; FLUSH PRIVILEGES;"

echo "[MYSQL] MySQL root password, user, and database configured."
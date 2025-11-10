#!/usr/bin/env bash
# online_deploy_slave.sh
# JMeter Slave 在線一鍵部署
# 適用於有網路連接的 Ubuntu 環境

set -euo pipefail

#-----------------------------
# 基本參數
#-----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="/var/log/online_deploy_slave.log"

# 環境變數
export LC_ALL=C

#-----------------------------
# 輔助函數
#-----------------------------
cecho() { echo -e "\033[1;36m[INFO]\033[0m $*"; }
wecho() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
eecho() { echo -e "\033[1;31m[FAIL]\033[0m $*"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    eecho "請以 root 執行此腳本"
    exit 1
  fi
}

trap 'eecho "發生錯誤，請檢查日誌：$LOGFILE"' ERR

# 日誌輸出
exec > >(tee -a "$LOGFILE") 2>&1

#-----------------------------
# 前置檢查
#-----------------------------
require_root
cecho "開始 JMeter Slave 在線部署，日誌：$LOGFILE"

# 讀取系統信息
OS_ID="$(. /etc/os-release; echo "${ID:-unknown}")"
OS_VER="$(. /etc/os-release; echo "${VERSION_ID:-unknown}")"
KERNEL="$(uname -r)"
cecho "系統：$OS_ID $OS_VER (kernel $KERNEL)"

#-----------------------------
# Step 1：安裝 Java JRE
#-----------------------------
cecho "Step 1：安裝 Java JRE"

if ! command -v java >/dev/null 2>&1; then
  cecho "安裝 OpenJDK 11 JRE (Headless)..."
  apt-get update -y
  apt-get install -y openjdk-11-jre-headless
  cecho "Java 安裝完成：$(java -version 2>&1 | head -n1)"
else
  cecho "Java 已安裝，跳過"
  java -version 2>&1 | head -n1
fi

#-----------------------------
# Step 2：安裝 Docker（在線）
#-----------------------------
if ! command -v docker >/dev/null 2>&1; then
  cecho "Step 2：在線安裝 Docker"

  # 更新包索引
  apt-get update -y

  # 安裝必要依賴
  apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

  # 添加 Docker 官方 GPG key
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  # 設置 Docker repository
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

  # 安裝 Docker Engine
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # 啟動 Docker 服務
  systemctl enable --now docker

  cecho "Docker 安裝完成：$(docker --version)"
else
  cecho "Step 2：Docker 已安裝，跳過"
  docker --version
fi

#-----------------------------
# Step 3：系統調校
#-----------------------------
cecho "Step 3：系統調校"

# 設置系統限制
cecho "配置系統限制..."
cat >> /etc/security/limits.conf <<EOF
* soft nofile 65535
* hard nofile 65535
* soft nproc 65535
* hard nproc 65535
EOF

# 內核參數優化
cecho "優化內核參數..."
cat >> /etc/sysctl.conf <<EOF
# JMeter Slave 性能優化
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
vm.max_map_count = 262144
EOF

sysctl -p || true

#-----------------------------
# Step 4：構建 JMeter Slave 鏡像
#-----------------------------
cecho "Step 4：構建 JMeter Slave Docker 鏡像"

if [[ ! -f "$SCRIPT_DIR/Dockerfile.slave" ]]; then
  eecho "找不到 Dockerfile.slave：$SCRIPT_DIR/Dockerfile.slave"
  exit 1
fi

cd "$SCRIPT_DIR"
docker build -f Dockerfile.slave -t jmeter-slave . || {
  eecho "鏡像構建失敗"
  exit 1
}

cecho "JMeter Slave 鏡像構建完成"
docker images | grep jmeter-slave || true

#-----------------------------
# Step 5：部署 JMeter Slave
#-----------------------------
cecho "Step 5：部署 JMeter Slave"

if [[ ! -f "$SCRIPT_DIR/deploy_jmeter_slave.sh" ]]; then
  eecho "找不到部署腳本：$SCRIPT_DIR/deploy_jmeter_slave.sh"
  exit 1
fi

chmod +x "$SCRIPT_DIR/deploy_jmeter_slave.sh"
bash "$SCRIPT_DIR/deploy_jmeter_slave.sh"

#-----------------------------
# Step 6：安裝監控工具
#-----------------------------
cecho "Step 6：安裝監控工具"

apt-get install -y \
  htop \
  iotop \
  iftop \
  net-tools \
  vim \
  curl \
  wget || true

#-----------------------------
# 收尾與摘要
#-----------------------------
HOST_IP=$(hostname -I | awk '{print $1}')

cecho "✅ JMeter Slave 在線部署完成！"
cecho ""
cecho "Docker 版本：$(docker --version)"
cecho ""
cecho "運行中的容器："
docker ps
cecho ""
cecho "JMeter Slave 連線資訊："
cecho "  Slave IP: $HOST_IP"
cecho "  RMI 埠: 1099"
cecho ""
cecho "在 Master 節點配置："
cecho "  1. 編輯 jmeter.properties"
cecho "  2. 設定 remote_hosts=$HOST_IP:1099"
cecho "  3. 在 Master 執行遠端測試"
cecho ""
cecho "查看 Slave 日誌："
cecho "  docker logs -f jmeter-slave"
cecho ""
cecho "日誌文件：$LOGFILE"

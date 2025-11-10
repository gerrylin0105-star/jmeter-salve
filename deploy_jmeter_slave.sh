#!/usr/bin/env bash
#========================================
# JMeter Slave 部署腳本
# 功能：生成 docker-compose.yml 並使用 docker compose 部署
#========================================

set -euo pipefail

#-----------------------------
# 環境變數與路徑設定
#-----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-jmeter-slave}"
SLAVE_COUNT="${SLAVE_COUNT:-5}"      # 預設部署 5 個容器
BASE_PORT="${BASE_PORT:-7001}"       # RMI 起始端口：7001, 7002, ...
DATA_BASE="${DATA_BASE:-50001}"      # Data 起始端口：50001, 50002, ...
TIMEZONE="${TIMEZONE:-Asia/Taipei}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"

#-----------------------------
# 輔助函數
#-----------------------------
cecho() { echo -e "\033[1;36m[INFO]\033[0m $*"; }
wecho() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
eecho() { echo -e "\033[1;31m[FAIL]\033[0m $*"; }
secho() { echo -e "\033[1;32m[DONE]\033[0m $*"; }

cleanup() {
  if [[ $? -ne 0 ]]; then
    eecho "部署過程發生錯誤，請檢查上方錯誤信息"
    eecho "可執行以下命令排查："
    eecho "  docker compose -f $COMPOSE_FILE logs"
    eecho "  docker compose -f $COMPOSE_FILE ps"
  fi
}

trap cleanup EXIT

#-----------------------------
# 前置檢查
#-----------------------------
cecho "=========================================="
cecho "JMeter Slave 部署 (${SLAVE_COUNT} 個容器)"
cecho "=========================================="
echo ""

# 檢查 Docker 是否運行
if ! docker info >/dev/null 2>&1; then
  eecho "Docker daemon 未運行，請先啟動 Docker"
  exit 1
fi

# 檢查 docker compose 命令
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  eecho "未找到 docker compose 命令"
  eecho "請安裝 docker-compose-plugin 或 docker-compose"
  exit 1
fi

# 檢查鏡像是否存在
if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  wecho "找不到鏡像 $IMAGE_NAME，開始自動構建..."
  if [[ ! -f "$SCRIPT_DIR/Dockerfile.slave" ]]; then
    eecho "找不到 Dockerfile.slave，無法構建鏡像"
    exit 1
  fi
  docker build -f "$SCRIPT_DIR/Dockerfile.slave" -t "$IMAGE_NAME" "$SCRIPT_DIR" || {
    eecho "鏡像構建失敗"
    exit 1
  }
  cecho "鏡像構建完成"
fi

# 獲取內網 IP
PRIVATE_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")

# 獲取公網 IP
PUBLIC_IP=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || echo "Unknown")

# 使用公網 IP
HOST_IP="${PUBLIC_IP}"

cecho "內網 IP: $PRIVATE_IP"
cecho "公網 IP: $PUBLIC_IP"
cecho "使用 IP: $HOST_IP"
echo ""

#-----------------------------
# 設置時區
#-----------------------------
cecho "[1/5] 設置系統時區為 ${TIMEZONE}..."
if command -v timedatectl >/dev/null 2>&1; then
  sudo timedatectl set-timezone "$TIMEZONE" 2>/dev/null || wecho "時區設置失敗（可能已設置）"
fi
echo ""

#-----------------------------
# 解壓 JMeter 到主機
#-----------------------------
cecho "[2/6] 解壓 JMeter 到主機..."
JMETER_TAR="${SCRIPT_DIR}/apache-jmeter-5.6.3.tgz"
JMETER_DIR="${SCRIPT_DIR}/apache-jmeter-5.6.3"

if [[ ! -f "$JMETER_TAR" ]]; then
  eecho "找不到 JMeter 壓縮檔：$JMETER_TAR"
  exit 1
fi

if [[ ! -d "$JMETER_DIR" ]]; then
  cecho "解壓 JMeter 到 ${SCRIPT_DIR}..."
  tar -xzf "$JMETER_TAR" -C "${SCRIPT_DIR}/"
  chmod -R 755 "$JMETER_DIR"
else
  cecho "JMeter 已存在於 $JMETER_DIR，跳過解壓"
fi
echo ""

#-----------------------------
# 生成 docker-compose.yml
#-----------------------------
cecho "[3/6] 生成 docker-compose.yml..."
echo "配置："
echo "  容器數量: ${SLAVE_COUNT}"
echo "  RMI 端口: ${BASE_PORT}-$((BASE_PORT + SLAVE_COUNT - 1))"
echo "  Data 端口: ${DATA_BASE}-$((DATA_BASE + SLAVE_COUNT - 1))"
echo "  主機 IP: ${PUBLIC_IP}"
echo "  時區: ${TIMEZONE}"
echo "  JMeter 掛載: ${JMETER_DIR}"
echo ""

# 生成 docker-compose.yml 檔頭
cat > "$COMPOSE_FILE" <<EOF
version: "3.9"

# JMeter Slave 分散式測試節點
# 生成時間: $(date '+%Y-%m-%d %H:%M:%S')
# 容器數量: ${SLAVE_COUNT}
# RMI 端口範圍: ${BASE_PORT}-$((BASE_PORT + SLAVE_COUNT - 1))
# Data 端口範圍: ${DATA_BASE}-$((DATA_BASE + SLAVE_COUNT - 1))

services:
EOF

# 逐台寫入 service 區塊
for i in $(seq 1 $SLAVE_COUNT); do
  CONTAINER_NAME="${PUBLIC_IP}-jmeter-slave-${i}"
  RMI_PORT=$((BASE_PORT + i - 1))
  DATA_PORT=$((DATA_BASE + i - 1))

  cat >> "$COMPOSE_FILE" <<EOF
  ${CONTAINER_NAME}:
    image: ${IMAGE_NAME}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    network_mode: "host"
    environment:
      - TZ=${TIMEZONE}
      - JAVA_OPTS=-Xms512m -Xmx2048m -XX:+UseG1GC -Duser.timezone=${TIMEZONE}
    volumes:
      - ${JMETER_DIR}:/opt/apache-jmeter-5.6.3:ro
    command:
      - jmeter-server
      - -Dserver.rmi.ssl.disable=true
      - -Dserver_port=${RMI_PORT}
      - -Djava.rmi.server.hostname=${PUBLIC_IP}

EOF
done

echo "✅ docker-compose.yml 已生成：${COMPOSE_FILE}"
echo ""

#-----------------------------
# 清理舊容器
#-----------------------------
cecho "[4/6] 清理舊容器..."

# 若有 docker-compose 檔案，先正常 down
if [ -f "$COMPOSE_FILE" ]; then
  $COMPOSE_CMD -f "$COMPOSE_FILE" down 2>/dev/null || true
fi

# 額外清除殘留的 jmeter-slave 相關容器
cecho "正在移除舊的 jmeter-slave 容器..."
docker ps -a --format '{{.Names}}' | grep -E '\-slave\-' | xargs -r docker rm -f || true
cecho "已清除名稱中包含 -slave- 的容器"

echo ""
#-----------------------------
# 啟動容器
#-----------------------------
cecho "[5/6] 使用 docker-compose 啟動容器..."
if ! $COMPOSE_CMD -f "$COMPOSE_FILE" up -d; then
  eecho "容器啟動失敗"
  eecho "請執行以下命令查看詳細日誌："
  eecho "  $COMPOSE_CMD -f $COMPOSE_FILE logs"
  exit 1
fi
echo ""

#-----------------------------
# 驗證部署
#-----------------------------
cecho "[6/6] 驗證部署..."
sleep 3

RUNNING=$(docker ps --filter "name=jmeter-slave-" --format "{{.Names}}" | wc -l | tr -d ' ')

if [ "$RUNNING" -eq "$SLAVE_COUNT" ]; then
  secho "✅ 成功部署 ${RUNNING}/${SLAVE_COUNT} 個容器"
else
  wecho "⚠️ 部分容器啟動失敗：${RUNNING}/${SLAVE_COUNT}"
fi

echo ""
cecho "容器列表："
docker ps --filter "name=jmeter-slave-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""

# 驗證時區
if [ "$RUNNING" -gt 0 ]; then
  CONTAINER_TIME=$(docker exec jmeter-slave-1 date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "UNKNOWN")
  cecho "容器時間：$CONTAINER_TIME"
  echo ""
fi

#-----------------------------
# 容器管理命令
#-----------------------------
cecho "=========================================="
cecho "容器管理命令："
cecho "=========================================="
echo "# 查看容器狀態"
echo "$COMPOSE_CMD -f ${COMPOSE_FILE} ps"
echo ""
echo "# 查看日誌"
echo "$COMPOSE_CMD -f ${COMPOSE_FILE} logs -f"
echo ""
echo "# 停止所有容器"
echo "$COMPOSE_CMD -f ${COMPOSE_FILE} down"
echo ""
echo "# 重啟所有容器"
echo "$COMPOSE_CMD -f ${COMPOSE_FILE} restart"
echo ""
echo "# 停止單個容器"
echo "$COMPOSE_CMD -f ${COMPOSE_FILE} stop jmeter-slave-1"
echo ""
echo "# 啟動單個容器"
echo "$COMPOSE_CMD -f ${COMPOSE_FILE} start jmeter-slave-1"
echo ""

secho "=========================================="
secho "✅ 部署完成！"
secho "=========================================="

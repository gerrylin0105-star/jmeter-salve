#!/usr/bin/env bash
#========================================
# JMeter Slave 診斷腳本
#========================================

set -e

cecho() { echo -e "\033[1;36m[INFO]\033[0m $*"; }
wecho() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
eecho() { echo -e "\033[1;31m[FAIL]\033[0m $*"; }
secho() { echo -e "\033[1;32m[DONE]\033[0m $*"; }

echo "========================================"
echo "JMeter Slave 診斷工具"
echo "========================================"
echo ""

#-----------------------------
# 1. 檢查容器狀態
#-----------------------------
cecho "1. 檢查容器狀態"
RUNNING=$(docker ps --filter "name=jmeter-slave" --format "{{.Names}}" | wc -l)
echo "運行中的容器數量: $RUNNING"

if [ "$RUNNING" -eq 0 ]; then
  eecho "沒有運行中的 JMeter Slave 容器！"
  exit 1
fi

docker ps --filter "name=jmeter-slave" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""

#-----------------------------
# 2. 檢查容器日誌（錯誤）
#-----------------------------
cecho "2. 檢查容器日誌中的錯誤"
FIRST_CONTAINER=$(docker ps --filter "name=jmeter-slave" --format "{{.Names}}" | head -1)

if docker logs "$FIRST_CONTAINER" 2>&1 | grep -i "error\|exception" | tail -10; then
  wecho "發現錯誤訊息（上方最後 10 行）"
else
  secho "未發現明顯錯誤"
fi
echo ""

#-----------------------------
# 3. 檢查 RMI 端口監聽
#-----------------------------
cecho "3. 檢查 RMI 端口監聽狀態"
echo "RMI 控制端口 (7001-7010):"
netstat -tuln | grep ":700[0-9]" || echo "未找到監聽端口"
echo ""
echo "RMI 數據端口 (50001-50010):"
netstat -tuln | grep ":5000[0-9]" || echo "未找到監聽端口"
echo ""

#-----------------------------
# 4. 檢查 JMeter 版本
#-----------------------------
cecho "4. 檢查 JMeter 版本"
docker exec "$FIRST_CONTAINER" sh -c 'ls -la /opt/ | grep jmeter'
echo ""

#-----------------------------
# 5. 檢查已安裝的 Plugins
#-----------------------------
cecho "5. 檢查已安裝的 Plugins"
echo "檢查容器: $FIRST_CONTAINER"
docker exec "$FIRST_CONTAINER" sh -c 'ls /opt/apache-jmeter-5.6.3/lib/ext/*.jar 2>/dev/null | wc -l' || echo "0"
echo "個 JAR 檔案在 lib/ext/"
echo ""
echo "關鍵 Plugins:"
docker exec "$FIRST_CONTAINER" sh -c 'ls /opt/apache-jmeter-5.6.3/lib/ext/ | grep -E "jpgc|jmeter-plugins"' || echo "未找到 Plugins"
echo ""

#-----------------------------
# 6. 測試 RMI 連接（從本機）
#-----------------------------
cecho "6. 測試 RMI 端口連通性"
PUBLIC_IP=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || echo "Unknown")
echo "公網 IP: $PUBLIC_IP"
echo ""

for PORT in 7001 7002 50001 50002; do
  if timeout 2 bash -c "echo > /dev/tcp/127.0.0.1/$PORT" 2>/dev/null; then
    secho "端口 $PORT: ✅ 可連接"
  else
    eecho "端口 $PORT: ❌ 無法連接"
  fi
done
echo ""

#-----------------------------
# 7. 檢查容器資源使用
#-----------------------------
cecho "7. 檢查容器資源使用"
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" \
  $(docker ps --filter "name=jmeter-slave" --format "{{.Names}}")
echo ""

#-----------------------------
# 8. 生成 Master 連線字串
#-----------------------------
cecho "8. Master 連線配置"
SLAVE_COUNT=$(docker ps --filter "name=jmeter-slave" --format "{{.Names}}" | wc -l)
HOSTS=""
for i in $(seq 1 $SLAVE_COUNT); do
  PORT=$((7000 + i))
  if [ -z "$HOSTS" ]; then
    HOSTS="${PUBLIC_IP}:${PORT}"
  else
    HOSTS="${HOSTS},${PUBLIC_IP}:${PORT}"
  fi
done

echo "在 Master 的 jmeter.properties 中設定："
echo "remote_hosts=${HOSTS}"
echo ""

#-----------------------------
# 完成
#-----------------------------
secho "========================================"
secho "診斷完成"
secho "========================================"
echo ""
echo "如果發現問題，請執行以下命令查看完整日誌："
echo "docker logs $FIRST_CONTAINER"
echo ""
echo "檢查防火牆："
echo "sudo ufw status"
echo "或"
echo "sudo firewall-cmd --list-ports"

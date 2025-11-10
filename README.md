# JMeter Slave 自動化部署

## 概述
自動化部署 JMeter Slave 容器到多台 Ubuntu 主機。

## 檔案說明

- `Dockerfile.slave` - JMeter Slave Docker 映像檔
- `deploy_jmeter_slave.sh` - 本地部署腳本（生成 docker-compose.yml 並啟動容器）
- `online_deploy_slave.sh` - 在線部署腳本（完整環境安裝）
- `docker-compose.yml` - Docker Compose 配置檔（由腳本自動生成）
- `hosts.txt` - 部署主機 IP 列表
- `.github/workflows/deploy.yml` - GitHub Actions 自動部署工作流

## 使用方式

### 方法 1：本地部署（單台主機）

```bash
# 構建映像
docker build -f Dockerfile.slave -t jmeter-slave .

# 部署容器（預設 5 個）
./deploy_jmeter_slave.sh

# 自訂容器數量
SLAVE_COUNT=10 ./deploy_jmeter_slave.sh
```

### 方法 2：GitHub Actions 自動部署（多台主機）

#### 設定步驟：

1. **編輯主機列表**

   編輯 `.github/workflows/deploy.yml`，修改 matrix.host 區塊：
   ```yaml
   matrix:
     host:
       - ip: 你的主機IP1
         username: ${{ secrets.HOST1_USERNAME }}
         password: ${{ secrets.HOST1_PASSWORD }}
       - ip: 你的主機IP2
         username: ${{ secrets.HOST2_USERNAME }}
         password: ${{ secrets.HOST2_PASSWORD }}
   ```

2. **設定 GitHub Secrets**

   前往 `Settings > Secrets and variables > Actions`，新增：
   - `HOST1_USERNAME` - 主機 1 的 SSH 使用者名稱
   - `HOST1_PASSWORD` - 主機 1 的 SSH 密碼
   - `HOST2_USERNAME` - 主機 2 的 SSH 使用者名稱
   - `HOST2_PASSWORD` - 主機 2 的 SSH 密碼
   - 依此類推...

3. **觸發部署**
   - 自動部署：push 到 main 分支
   - 手動部署：在 Actions 頁面點擊 "Run workflow"

## 環境變數

| 變數 | 預設值 | 說明 |
|------|--------|------|
| `SLAVE_COUNT` | 5 | 部署的容器數量 |
| `BASE_PORT` | 7001 | RMI 起始端口 |
| `DATA_BASE` | 50001 | Data 起始端口 |
| `TIMEZONE` | Asia/Taipei | 容器時區 |
| `IMAGE_NAME` | jmeter-slave | Docker 映像名稱 |

## 容器管理

```bash
# 查看容器狀態
docker compose ps

# 查看日誌
docker compose logs -f

# 停止所有容器
docker compose down

# 重啟容器
docker compose restart
```

## 時區設定

容器時區已透過以下方式設定：
- 環境變數 `TZ=Asia/Taipei`
- Java 參數 `-Duser.timezone=Asia/Taipei`
- Dockerfile 安裝 `tzdata` 套件

## 注意事項

1. 目標主機需要已安裝 Docker 和 Docker Compose
2. 確保防火牆開放所需端口（7001-7010, 50001-50010）
3. 建議使用 SSH 金鑰認證取代密碼認證
4. 部署前請先測試單台主機是否正常運作

## 故障排除

**容器時區不正確：**
- 檢查 Dockerfile 是否包含 `tzdata`
- 重新構建映像：`docker build -f Dockerfile.slave -t jmeter-slave .`

**無法連接到容器：**
- 檢查防火牆設定
- 確認端口沒有被佔用：`netstat -tuln | grep 7001`

**GitHub Actions 部署失敗：**
- 檢查 Secrets 是否正確設定
- 查看 Actions 日誌確認錯誤訊息

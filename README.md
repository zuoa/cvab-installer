# cvab-installer

RK3588 盒子环境初始化脚本：检查并无损升级 **RKNN Runtime 2.3.2**、安装 **Docker / Compose**，再落盘 RKNN 版 `docker-compose.yml`（可选 MQTT）。

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/zuoa/cvab-installer/master/install.sh | sudo bash
```

GitHub raw 本身超时可用国内镜像拉脚本：

```bash
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/zuoa/cvab-installer/master/install.sh | sudo bash
```

已 clone 本仓库时：

```bash
sudo bash install.sh
```

交互过程会询问：

1. 带 MQTT 还是不带 MQTT
2. 是否立刻 `docker compose up -d`

## 非交互

```bash
sudo bash install.sh --mqtt --no-start
sudo bash install.sh --no-mqtt --start --workdir /opt/cvab
```

| 参数 | 说明 |
|---|---|
| `--mqtt` / `--no-mqtt` | 选择 compose 变体 |
| `--workdir PATH` | 工作目录，默认 `/opt/cvab` |
| `--start` / `--no-start` | 是否拉镜像并启动 |
| `--skip-rknn` | 跳过 Runtime 升级 |
| `--skip-docker` | 跳过 Docker 安装 |
| `--force` | 未识别到 RK3588 也继续 |

`curl | bash` 时没有 TTY，必须带上 `--mqtt` 或 `--no-mqtt`。无 TTY 且未指定 `--start` 时默认不启动容器。

## 脚本会做什么

1. **RKNN Runtime 2.3.2（无损）**
   - 读 `librknnrt.so` / `rknn_server` 版本
   - 已是 2.3.2：跳过
   - 高于 2.3.2：**不降级**
   - 低于或未安装：备份到 `/var/backups/rknn-runtime/<时间戳>/` 再替换
   - 失败自动回滚；也可手动：`sudo bash /var/backups/rknn-runtime/<时间戳>/restore.sh`
   - **不刷内核**。驱动过旧只警告。

2. **Docker**
   - 已有 `docker` + `docker compose` 则跳过
   - 否则走官方 apt 源，失败再回退 `get.docker.com`
   - `SUDO_USER` 加入 `docker` 组（需重新登录）

3. **Compose**
   - `docker-compose.yml.rknn` → 带 MQTT
   - `docker-compose.no-mqtt.yml.rknn` → 不带 MQTT
   - 复制为 `/opt/cvab/docker-compose.yml`，并补齐 `mediamtx.yml`、`deploy/mosquitto.conf`、`data/`
   - 已有 compose 会先备份，不覆盖 `data/`

## 访问

| 服务 | 地址 |
|---|---|
| 前端 | `http://<盒子IP>:8080` |
| API | `http://<盒子IP>:5002` |
| WebRTC | `http://<盒子IP>:8889`（默认关闭，需 `MEDIAMTX_ENABLED=true`） |

```bash
cd /opt/cvab
docker compose ps
docker compose logs -f
docker compose down
```

镜像来自 `ghcr.io/zuoa/video-ba-pipe:rk`，盒子需要能访问 ghcr。

## 注意

- 脚本只应在 **RK3588 / aarch64 / Debian 或 Ubuntu** 上跑。
- 拉 GitHub 文件时先走官方源（约 10s 连接 / 45s 总超时）；失败后自动换 ghfast、gh-proxy、ghproxy、gitdl、gitmirror、jsDelivr、kkgithub。`git clone` 同样回退。
- 不修改 Docker 镜像加速；国内拉官方/ghcr 较慢时请自行配置 daemon mirror。
- worker 需要 NPU/MPP 设备节点（`/dev/dri`、`/dev/mpp_service`、`/dev/rga`）以及 privileged；节点缺失脚本只警告。

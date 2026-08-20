# cvab-installer

按当前机器探测平台（RK3588 / Jetson / x86+CUDA / CPU），可选部署 **MQTT**、**RabbitMQ**，生成一份 `/opt/cvab/docker-compose.yml`。RK3588 还会检查并无损升级 **RKNN Runtime 2.3.2**，并安装 Docker / Compose。

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/zuoa/cvab-installer/master/install.sh | sudo bash
```

GitHub raw 超时可用国内镜像拉脚本：

```bash
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/zuoa/cvab-installer/master/install.sh | sudo bash
```

已 clone 本仓库时：

```bash
sudo bash install.sh
```

交互会问：是否装 MQTT、是否装 RabbitMQ、是否立刻 `docker compose up -d`。

## 非交互

```bash
sudo bash install.sh --platform rknn --mqtt --no-rabbitmq --no-start
sudo bash install.sh --no-mqtt --start --workdir /opt/cvab
```

| 参数 | 说明 |
|---|---|
| `--platform rknn\|jetson\|cuda\|cpu` | 覆盖自动探测 |
| `--mqtt` / `--no-mqtt` | 是否部署 Mosquitto；`curl \| bash` 必须显式指定 |
| `--rabbitmq` / `--no-rabbitmq` | 是否部署 RabbitMQ；未指定时 cuda 默认开，其余默认关 |
| `--workdir PATH` | 工作目录，默认 `/opt/cvab` |
| `--start` / `--no-start` | 是否拉镜像并启动 |
| `--skip-rknn` | 跳过 Runtime 升级 |
| `--skip-docker` | 跳过 Docker 安装 |
| `--force` | 平台无法识别时按 cpu 继续 |

`curl | bash` 没有 TTY 时必须带 `--mqtt` 或 `--no-mqtt`。未指定 `--start` 时默认不启动容器。

## 平台探测

| 条件 | 平台 | 底座 compose | 镜像 |
|---|---|---|---|
| device-tree 含 `rk3588` | rknn | `docker-compose.no-mqtt.yml.rknn` | `:rk` |
| `/etc/nv_tegra_release` 或 compatible 含 tegra | jetson | `*.yml.jetson` | `:jetson` |
| x86_64 且 `nvidia-smi` 可用 | cuda | `*.yml.x86+cuda` | `:cuda` |
| 其余 | cpu | `docker-compose.no-mqtt.yml` | `:cpu` |

脚本把底座和 `overlays/mqtt.yml` / `overlays/rabbitmq.yml` 合成最终的 `docker-compose.yml`，并写入 `install-options.env`。

## 脚本会做什么

1. **探测平台**，仅 RK3588 升级 RKNN Runtime 2.3.2（已是目标版本则跳过，更高则不降级；备份在 `/var/backups/rknn-runtime/<时间戳>/`）
2. **Docker**：已有 `docker` + `docker compose` 则跳过
3. **生成 compose**：按 MQTT / RabbitMQ 选择渲染，拷贝 `mediamtx.yml`、`frontend/nginx.conf`，MQTT 时再拷 `deploy/mosquitto.conf`

## 访问

| 服务 | 地址 |
|---|---|
| 前端 | `http://<盒子IP>:8080` |
| API | `http://<盒子IP>:5002` |
| WebRTC | `http://<盒子IP>:8889`（默认关闭，需 `MEDIAMTX_ENABLED=true`） |
| RabbitMQ 管理台 | `http://<盒子IP>:15672`（若启用；默认 admin / admin123） |

```bash
cd /opt/cvab
docker compose ps
docker compose logs -f
docker compose down
```

镜像来自 `ghcr.io/zuoa/video-ba-pipe`，盒子需要能访问 ghcr。应用里 MQTT/RabbitMQ 的连接参数仍在系统设置页配置，脚本只决定是否部署 broker 容器。

## 注意

- 目标系统：Debian 或 Ubuntu。RKNN 升级只在 RK3588 上执行。
- 拉 GitHub 文件时先走官方源（约 10s 连接 / 45s 总超时）；失败后自动换 ghfast、gh-proxy、ghproxy、gitdl、gitmirror、jsDelivr、kkgithub。`git clone` 同样回退。
- 不修改 Docker 镜像加速；国内拉官方/ghcr 较慢时请自行配置 daemon mirror。
- RK3588 worker 需要 NPU/MPP 设备节点（`/dev/dri`、`/dev/mpp_service`、`/dev/rga`）以及 privileged；节点缺失脚本只警告。

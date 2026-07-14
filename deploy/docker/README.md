# Docker Compose 生产部署

Bay + Ship + Gull 的 Docker Compose 自包含生产部署方案。

## 架构

```
┌──────────────────────────────────────────────────────┐
│  Docker Host                                          │
│                                                       │
│  ┌─────────────────────────────────────────────────┐  │
│  │  bay-network (bridge)                           │  │
│  │                                                  │  │
│  │  ┌──────────┐                                   │  │
│  │  │  Bay     │ :8114 ──→ Host :8114              │  │
│  │  │ (API GW) │                                   │  │
│  │  └────┬─────┘                                   │  │
│  │       │  container_network 直连                  │  │
│  │       ├──→ Ship Pod (sandbox-xxx)               │  │
│  │       ├──→ Ship Pod (sandbox-yyy)               │  │
│  │       └──→ Gull Pod (sandbox-zzz-browser)       │  │
│  │                                                  │  │
│  └─────────────────────────────────────────────────┘  │
│                                                       │
│  bay-data volume    ← SQLite 数据库                  │
│  bay-cargos volume  ← Cargo 持久化存储               │
└──────────────────────────────────────────────────────┘
```

## 前置条件

- Docker Engine 24+ (带 Compose v2 插件)
- 镜像已通过 CD 自动推送到 GHCR（`ghcr.io/astrbotdevs/shipyard-neo-{bay,ship,gull}`）
- 使用 `resources.gpus: all` 的 Ship profile 还要求宿主机已安装 NVIDIA
  驱动和 [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)

## 快速开始

```bash
# 1. 编辑 config.yaml，搜索 CHANGE-ME 修改必须项：
#    - security.api_key → 设置强随机密钥 (e.g. `openssl rand -hex 32`)
#      （若同时设置 BAY_API_KEY 环境变量，则 BAY_API_KEY 优先）
vi config.yaml

# 2. 启动
docker compose up -d

# 3. 验证健康
curl http://localhost:8114/health

# 4. 查看日志
docker compose logs -f bay
```

## AstrBot 联合部署

使用 overlay compose 文件将 AstrBot 加入 Bay 编排：

```bash
# 启动 Bay + AstrBot
docker compose -f docker-compose.yaml -f docker-compose.with-astrbot.yaml up -d

# 查看日志
docker compose -f docker-compose.yaml -f docker-compose.with-astrbot.yaml logs -f
```

启动后：

1. **打开 Dashboard**: http://localhost:6185（默认用户名密码: astrbot）
2. **配置 Computer Use**:
   - 运行环境 → `sandbox`
   - 沙箱环境驱动器 → `shipyard_neo`
   - Endpoint → `http://bay:8114`（Docker 内部 DNS）
   - 访问令牌 → **留空**（自动从 bay-data 卷发现）
3. **保存** — 应显示 "保存成功~"

> **原理**: AstrBot 以只读方式挂载 Bay 的 `bay-data` 卷，通过 `BAY_DATA_DIR=/bay-data` 环境变量让 `_discover_bay_credentials()` 自动找到 `credentials.json` 中的 API Key。

## 文件说明

| 文件 | 说明 |
|------|------|
| `docker-compose.yaml` | Compose 编排文件，定义 Bay 服务、网络、存储卷 |
| `docker-compose.with-astrbot.yaml` | AstrBot overlay，联合部署 Bay + AstrBot |
| `config.yaml` | Bay 完整配置（profiles、driver、GC 等） |
| `README.md` | 本文档 |

## 配置

所有配置集中在 [`config.yaml`](config.yaml)，已针对生产环境优化：

- **驱动模式**: `container_network` — Bay 和 Ship/Gull 处于同一 Docker 网络，通过容器 IP 直连
- **端口映射**: 禁用 (`publish_ports: false`) — sandbox 容器不暴露宿主机端口，减少攻击面
- **认证**: 强制要求 API Key (`allow_anonymous: false`)
  - API Key 读取优先级：`BAY_API_KEY` > `security.api_key` >（首次启动且 DB 为空时）自动生成
- **GC**: 启用自动回收（包括 orphan container 检测），每 5 分钟一轮
- **Profile**: 包含 4 个常用 profile：
  - `python-default` — 标准 Python 沙箱 (1 CPU / 1GB)
  - `python-data` — 数据科学沙箱 (2 CPU / 4GB)
  - `python-gpu` — 显式请求全部 NVIDIA GPU，不启用 warm pool
  - `browser-python` — 浏览器自动化 + Python 多容器沙箱

### 代理配置

如果需要让 sandbox 内的 Python / Shell 使用代理，不要只写 Docker `build.args`；`build.args` 只在构建镜像时生效，不会传给 Bay 运行时，也不会传给 Bay 动态创建的 Ship/Gull 容器。

推荐在 `docker-compose.yaml` 的 `bay.environment` 中启用 Bay 代理注入：

```yaml
environment:
  - BAY_PROXY__ENABLED=true
  - BAY_PROXY__HTTP_PROXY=http://host.docker.internal:7890
  - BAY_PROXY__HTTPS_PROXY=http://host.docker.internal:7890
  - BAY_PROXY__NO_PROXY=127.0.0.1,localhost,bay,bay-network
```

也可以在 `config.yaml` 的 `proxy:` 段配置同样的值。配置后需要重建 Bay 容器，并新建 sandbox；已存在的 sandbox 不会自动更新环境变量。

### Ship GPU

Ship 运行时镜像基于 `nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04`，包含
CUDA/cuDNN runtime。镜像构建本身不需要 GPU，也不会在构建阶段执行
`nvidia-smi`；NVIDIA Container Toolkit 会在 GPU 容器启动时提供驱动侧 utility，
因此只有在具备 NVIDIA 驱动和 Container Toolkit 的宿主机上，容器内才可运行
`nvidia-smi` 并访问实际设备。

GPU 是每个 Ship 容器的显式 opt-in。生产配置中的 `python-default`、
`python-data` 和 `browser-python` 保持 CPU-only；只有专用的 `python-gpu`
profile 请求 GPU，且不会创建 GPU warm pool：

```yaml
resources:
  cpus: 1.0
  memory: "1g"
  gpus: all
```

Bay 通过 Docker socket 动态创建 Ship，并把 `gpus: all` 映射为 Docker Engine
`DeviceRequests`（NVIDIA driver、`Count: -1`、`gpu` capability）。因此不要给
Compose 中的 `bay`、`gull-service` 或 AstrBot 服务添加 GPU reservation：
reservation 只作用于那个静态 Compose 服务，不会传播给 Bay 后续创建的 sandbox。
唯一例外是 `dev/docker-compose.yaml` 中 profile 为 `build` 的静态 `ship`
服务；它直接代表 Ship 预制环境，因此自身带有等价的 Compose NVIDIA GPU
reservation。该 reservation 不替代生产环境中 Bay 为动态 sandbox 设置的
`DeviceRequests`，也不表示镜像构建阶段会执行或需要运行 `nvidia-smi`。
未配置 `gpus` 的 profile 保持 CPU-only；Gull 不会收到 GPU request。CUDA
基础镜像也可以在不请求 DeviceRequests 的 CPU-only Ship 中运行。宿主 NVIDIA
驱动需满足 CUDA 12.8 的兼容要求。

### Profile API

通过 `GET /v1/profiles` 查看可用 profile：

```bash
# 基础信息
curl -H "Authorization: Bearer <your-api-key>" http://localhost:8114/v1/profiles

# 包含 description 和容器拓扑
curl -H "Authorization: Bearer <your-api-key>" "http://localhost:8114/v1/profiles?detail=true"
```

### upload / download

`upload` 和 `download` 功能已集成在 `filesystem` capability 中，无需单独声明。
对应 API 端点为 `POST .../filesystem/upload` 和 `GET .../filesystem/download`。

## 运维

### 停止 & 清理

```bash
# 停止 Bay（不影响已运行的 sandbox 容器）
docker compose down

# 停止 Bay 并清理所有 sandbox 容器
docker compose down
docker ps -a --filter "label=bay.managed=true" -q | xargs -r docker rm -f
docker volume ls --filter "label=bay.managed=true" -q | xargs -r docker volume rm
```

### 数据备份

```bash
# 备份 SQLite 数据库
docker cp bay:/app/data/bay.db ./bay-$(date +%Y%m%d).db

# 备份 cargo 存储
docker run --rm -v bay-cargos:/data -v $(pwd):/backup \
  alpine tar czf /backup/cargos-$(date +%Y%m%d).tar.gz -C /data .
```

### 监控

Bay 提供以下端点：

- `GET /health` — 健康检查（无需认证）
- `GET /v1/admin/gc/status` — GC 状态
- `POST /v1/admin/gc/run` — 手动触发 GC

### 升级

```bash
# 拉取新镜像（GHCR 自动构建）
docker compose pull

# 重建（Bay 容器无状态，sandbox 不受影响）
docker compose up -d --force-recreate bay
```

### 使用指定版本

默认使用 `latest` 标签。如需锁定版本，编辑对应文件中的镜像 tag：

```bash
# docker-compose.yaml 中 Bay 的镜像
image: ghcr.io/astrbotdevs/shipyard-neo-bay:0.1.0

# config.yaml 中 Ship/Gull 的镜像
image: "ghcr.io/astrbotdevs/shipyard-neo-ship:0.1.0"
image: "ghcr.io/astrbotdevs/shipyard-neo-gull:0.1.0"
```

可用标签格式：`latest`、`0.1.0`（semver）、`0.1`（major.minor）、`sha-abc1234`（commit hash）。

## 镜像来源

所有镜像通过 GitHub Actions CD 自动构建并推送到 GHCR：

| 镜像 | 地址 |
|------|------|
| Bay  | `ghcr.io/astrbotdevs/shipyard-neo-bay` |
| Ship | `ghcr.io/astrbotdevs/shipyard-neo-ship` |
| Gull | `ghcr.io/astrbotdevs/shipyard-neo-gull` |

触发方式：推送 `v*` 格式 tag 或在 GitHub Actions 页面手动触发。

## 安全建议

1. **必须配置 API Key** — 建议至少设置 `security.api_key`；若同时设置 `BAY_API_KEY`，以环境变量为准
2. **使用反向代理** — 在 Bay 前部署 nginx/traefik 进行 TLS 终止
3. **限制 Docker Socket 访问** — Bay 容器需要 Docker socket，建议使用 Docker Socket Proxy
4. **网络隔离** — sandbox 容器仅通过 `bay-network` 与 Bay 通信，不暴露宿主机端口
5. **定期备份** — SQLite 数据库和 cargo 存储

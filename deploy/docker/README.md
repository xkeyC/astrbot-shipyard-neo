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

### 沙箱包管理镜像源

Ship 的 agent 以非 root 用户 `shipyard` 运行，自己装依赖时用的是 conda、uv/pip、
bun、rustup/cargo 和 Nix。它们的镜像源通过 profile 的 `env` 注入，Ship 的入口脚本
在容器启动时把下面的变量翻译成各工具自己的设置，Python、Shell 和终端里都生效：

| 变量 | 作用于 | 示例 |
|------|--------|------|
| `SHIPYARD_PYPI_MIRROR` | pip（`PIP_INDEX_URL`）、uv（`UV_DEFAULT_INDEX`） | `https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple` |
| `SHIPYARD_CONDA_MIRROR` | conda channel alias（`conda-forge` → `<mirror>/conda-forge`） | `https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud` |
| `SHIPYARD_NPM_MIRROR` | bun / npm registry | `https://registry.npmmirror.com` |
| `SHIPYARD_RUSTUP_MIRROR` | rustup（`RUSTUP_DIST_SERVER`、`RUSTUP_UPDATE_ROOT`） | `https://mirrors.tuna.tsinghua.edu.cn/rustup` |
| `SHIPYARD_CRATES_MIRROR` | cargo 的 crates.io 源替换（写入 `$CARGO_HOME/config.toml`） | `https://mirrors.tuna.tsinghua.edu.cn/crates.io-index/` |
| `SHIPYARD_NIX_MIRROR` | Nix 二进制缓存 substituters（仍保留 cache.nixos.org 兜底） | `https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store` |
| `SHIPYARD_PACMAN_MIRROR` | pacman 的 `/etc/pacman.d/mirrorlist`（写 Arch 源根地址即可） | `https://mirrors.tuna.tsinghua.edu.cn/archlinux` |
| `SHIPYARD_PYTHON_MIRROR` | `uv python install` 下载的 Python 构建 | `https://registry.npmmirror.com/-/binary/python-build-standalone` |

```yaml
profiles:
  - id: python-default
    env:
      SHIPYARD_PYPI_MIRROR: "https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple"
      SHIPYARD_NPM_MIRROR: "https://registry.npmmirror.com"
      SHIPYARD_RUSTUP_MIRROR: "https://mirrors.tuna.tsinghua.edu.cn/rustup"
      SHIPYARD_CRATES_MIRROR: "https://mirrors.tuna.tsinghua.edu.cn/crates.io-index/"
      SHIPYARD_NIX_MIRROR: "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
      SHIPYARD_PACMAN_MIRROR: "https://mirrors.tuna.tsinghua.edu.cn/archlinux"
```

- 不设置的变量不生效，工具使用各自的官方源。
- conda 建议不设镜像：官方 conda.anaconda.org 提供分片索引（repodata shards），
  `conda install` 只下载用到的那几片（缓存约 5 MB）。TUNA、USTC、BFSU、NJU 等国内镜像
  都没有分片，conda 会退回去下载并解析完整的 conda-forge 索引（linux-64 约 450 MB）：
  1 GB 内存的沙箱里 conda 直接被 OOM 杀掉，内存够时也要多占约 650 MB 磁盘。只在官方源
  连不上、且 profile 内存在 4 GB 左右时再设 `SHIPYARD_CONDA_MIRROR`。
- `SHIPYARD_CRATES_MIRROR` 不带协议前缀时按 sparse 索引处理（自动加 `sparse+`）；
  也可以直接写 `sparse+...` 或 `git+...`。入口脚本只改写自己生成的
  `config.toml`，agent 在沙箱里改过的文件不会被覆盖。
- `SHIPYARD_NIX_MIRROR`、`SHIPYARD_PACMAN_MIRROR` 可以写多个，用空格分隔；pacman 的地址
  也可以写完整形式（含 `$repo/os/$arch`）。
- agent 没有 root，不能用 pacman 安装软件包（只能 `pacman -Ss`/`-Si` 查询镜像里自带的
  包数据库）；pacman 镜像用于 `docker exec -u root` 之类的运维操作。agent 需要系统工具时
  用 `nix profile install`，它走 `SHIPYARD_NIX_MIRROR`。
- `nixpkgs` 源码在构建镜像时已预取并固定，求值不需要下载；运行期 Nix 只从 substituters
  下载二进制。
- 工具自己的变量（`PIP_INDEX_URL`、`UV_DEFAULT_INDEX`、`NPM_CONFIG_REGISTRY`、
  `RUSTUP_DIST_SERVER`、`NIX_CONFIG`、`HF_ENDPOINT` 等）直接写进 `env` 同样有效。
- 和代理一样，修改后需要新建 sandbox 才会生效。

构建镜像时的下载源用 build args 指定，和运行期无关，全部可选，不传就走官方源：

| build arg | 作用 | 示例 |
|-----------|------|------|
| `BASE_IMAGE` | 基础镜像（默认 `archlinux:base-devel`） | `docker.m.daocloud.io/library/archlinux:base-devel` |
| `PACMAN_MIRROR` | Arch 源根地址，同时写进镜像的 mirrorlist | `https://mirrors.tuna.tsinghua.edu.cn/archlinux` |
| `PYPI_MIRROR` | PyPI | `https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple` |
| `CONDA_MIRROR` | conda channel alias | `https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud` |
| `MINIFORGE_MIRROR` | Miniforge 安装脚本目录 | `https://mirrors.tuna.tsinghua.edu.cn/github-release/conda-forge/miniforge/LatestRelease` |
| `RUSTUP_MIRROR` | rustup 分发服务器 | `https://mirrors.tuna.tsinghua.edu.cn/rustup` |
| `PLAYWRIGHT_MIRROR` | Playwright 浏览器 | `https://registry.npmmirror.com/-/binary/playwright` |
| `PYTHON_MIRROR` | uv 下载 Ship 服务用的 Python | `https://registry.npmmirror.com/-/binary/python-build-standalone` |
| `NIXPKGS_MIRROR` | 预取的 nixpkgs 源码 tarball（默认 GitHub 的 nixpkgs-unstable） | `https://mirrors.tuna.tsinghua.edu.cn/nix-channels/nixpkgs-unstable/nixexprs.tar.xz` |

`pkgs/ship/Makefile` 的 `make build` 和 `dev/docker-compose.yaml` 的 ship 构建默认带上上面这组
国内镜像；`make build MIRROR_ARGS=` 则全部走官方源。

### Ship GPU

Ship 运行时镜像基于 Arch Linux，预装 Arch 的 `cuda`（完整 CUDA toolkit，含
`nvcc`，位于 `/opt/cuda`）和 `cudnn`。镜像构建本身不需要 GPU，也不会在构建阶段执行
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
驱动需满足镜像中 CUDA 版本（Arch 当前为 CUDA 13.x，需要 580 及以上驱动）的
兼容要求；镜像不带驱动库，`libcuda` 与 `nvidia-smi` 均由 Container Toolkit 从宿主注入。

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

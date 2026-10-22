# Ship 架构文档

> **状态**: 完整版
> **最后更新**: 2026-02-11

## 1. 概述

**Ship** 是 Shipyard 平台中的 **容器化沙箱运行时 (Container Runtime)**，以独立 Docker 容器形式运行在每个沙箱实例内部。它基于 FastAPI 构建，对外暴露 HTTP/WebSocket API（端口 `8123`），为上层编排服务 **Bay** 提供以下核心能力：

- 文件系统操作（CRUD、上传/下载）
- IPython 内核（Python 代码执行、图表渲染）
- Shell 命令执行（前台/后台进程）
- 交互式终端（基于 WebSocket + PTY）

### 在 Shipyard 中的定位

```
┌──────────────────────────────────────────────┐
│                  MCP Client                  │
│              (AI Agent / IDE)                │
└────────────────┬─────────────────────────────┘
                 │ MCP Protocol
┌────────────────▼─────────────────────────────┐
│                    Bay                       │
│         (编排层 · 管理沙箱生命周期)             │
│         ShipAdapter ─── HTTP ──┐             │
└────────────────────────────────┼─────────────┘
                                 │
              ┌──────────────────▼─────────────┐
              │           Ship 容器             │
              │   FastAPI  :8123               │
              │  ┌─────────────────────────┐   │
              │  │ /fs/*      Filesystem   │   │
              │  │ /ipython/* IPython      │   │
              │  │ /shell/*   Shell        │   │
              │  │ /term/ws   Terminal     │   │
              │  └─────────────────────────┘   │
              │   /workspace  (挂载卷)          │
              └────────────────────────────────┘
```

---

## 2. 目录结构

```
pkgs/ship/
├── run.py                    # Uvicorn 启动入口
├── Dockerfile                # 基于 Arch Linux 构建（conda、uv、bun、rustup、Nix、CUDA）
├── entrypoint.sh             # 容器入口：修复 /workspace 权限后启动应用
├── Makefile                  # 构建/运行/测试快捷命令
├── pyproject.toml            # 项目元数据与依赖
├── requirements.txt          # pip 兼容依赖列表
├── app/
│   ├── __init__.py
│   ├── main.py               # FastAPI 应用定义、路由注册、生命周期
│   ├── workspace.py          # 路径安全解析（沙箱根 /workspace）
│   └── components/
│       ├── filesystem.py     # 文件系统 CRUD + 上传/下载
│       ├── ipython.py        # Jupyter 内核管理 + 代码执行
│       ├── shell.py          # Shell 命令路由
│       ├── term.py           # WebSocket 交互式终端 (PTY)
│       └── user_manager.py   # 命令执行引擎（以 shipyard 身份执行、进程管理）
├── skills/                   # 内置 skill（构建时打包进镜像，启动时注入 workspace）
│   └── python-sandbox/SKILL.md
└── tests/
    ├── e2e/                  # 端到端测试
    └── unit/                 # 单元测试
```

---

## 3. 核心模块

### 3.1 应用入口 — [`main.py`](../pkgs/ship/app/main.py)

- 使用 FastAPI `lifespan` 在启动时 **预热 Jupyter Kernel**，避免首次请求冷启动延迟
- 注册四个子路由：`/fs`、`/ipython`、`/shell`、`/term`
- 提供 `/health`、`/meta`、`/stat` 等运维端点
- `/meta` 端点返回 runtime 自描述信息，**Bay 用此端点校验运行时版本与能力集**

### 3.2 路径安全 — [`workspace.py`](../pkgs/ship/app/workspace.py)

- 固定沙箱根目录 `WORKSPACE_ROOT = Path("/workspace")`
- `resolve_path()` 函数对所有用户输入路径做 **路径遍历防护**：
  - 相对路径 → 拼接到 `/workspace` 下
  - 绝对路径 → 必须在 `/workspace` 子树内
  - 违规 → HTTP 403

### 3.3 文件系统组件 — [`filesystem.py`](../pkgs/ship/app/components/filesystem.py)

| 端点 | 方法 | 功能 |
|------|------|------|
| `/fs/create_file` | POST | 创建文件（支持设置权限模式） |
| `/fs/read_file` | POST | 读取文件（支持 offset/limit 分页读取） |
| `/fs/write_file` | POST | 写入/追加文件 |
| `/fs/edit_file` | POST | 字符串搜索替换编辑 |
| `/fs/delete_file` | POST | 删除文件或目录（递归） |
| `/fs/list_dir` | POST | 列出目录内容 |
| `/fs/upload` | POST | 二进制文件上传（multipart/form-data） |
| `/fs/download` | GET | 文件下载 |

### 3.4 IPython 组件 — [`ipython.py`](../pkgs/ship/app/components/ipython.py)

- **单例内核模式**：每个 Ship 容器维护一个 `AsyncKernelManager` 实例
- 内核跑在 conda base 的 Python（`/opt/conda/bin/python`）上：Ship 服务 venv 里的 kernelspec `python3` 指向它，所以 agent 往 conda base 装的包在内核里直接可用
- 启动时通过 `start_kernel(cwd="/workspace")` 将内核工作目录设为沙箱根
- 内核初始化包括 **matplotlib 中文/emoji 字体配置**（Noto CJK + WenQuanYi + Noto Color Emoji + Symbola fallback）
- 支持文本输出和 Base64 PNG 图像输出
- 提供内核重启和关闭接口

### 3.5 Shell 组件 — [`shell.py`](../pkgs/ship/app/components/shell.py) + [`user_manager.py`](../pkgs/ship/app/components/user_manager.py)

- Ship 进程本身就以 `shipyard` 运行，命令直接以 `bash -lc "..."` 执行，继承服务的环境（含镜像源设置）
- 支持 **前台执行**（等待完成，返回 stdout/stderr/return_code）
- 支持 **后台执行**（立即返回 process_id，可查询/终止）
- 后台进程注册表自动清理已完成的进程

### 3.6 终端组件 — [`term.py`](../pkgs/ship/app/components/term.py)

- WebSocket 端点 `/term/ws`，面向 xterm.js 前端集成
- 每个连接创建独立 PTY（`pty.fork()` → `bash -l`）
- 支持终端尺寸调整（`TIOCSWINSZ`）
- 连接断开时自动清理 PTY 和子进程

---

## 4. 安全模型

Ship 采用 **三层防御** 策略来保障沙箱的安全隔离：

### 4.1 容器隔离（第一层）

每个沙箱是一个独立的 Docker 容器，由 Bay 编排层管理生命周期。容器级别提供：

- **进程隔离**: 容器内进程无法访问宿主机或其他容器的进程
- **网络隔离**: 容器拥有独立的网络命名空间
- **文件系统隔离**: 仅通过 `/workspace` 卷挂载有限的持久化存储

### 4.2 用户权限隔离（第二层）

容器里没有以 root 运行的进程：

```
entrypoint.sh (root，只在启动时)
  └─ 修正 /workspace 权限、写入镜像源配置、注入 skills
  └─ exec setpriv --reuid shipyard --regid shipyard --init-groups
               --inh-caps=-all --bounding-set=-all --no-new-privs

shipyard (UID 1000, GID 1000)
  └─ 运行 FastAPI 应用、IPython 内核、Shell 命令和终端
  └─ HOME=/workspace
  └─ 没有 sudo，没有 capability；no_new_privs 让 setuid 程序也拿不回 root
  └─ 拥有用户态工具链目录：/opt/conda、/opt/rustup、/opt/cargo、/opt/bun、/nix
```

关键实现（见 [`entrypoint.sh`](../pkgs/ship/entrypoint.sh) 与 [`user_manager.py`](../pkgs/ship/app/components/user_manager.py)）：

- Shell 命令执行: `bash -lc "export PATH=... && source .bay_env.sh && cd <cwd> && <command>"`
- 交互式终端: `bash -l`（通过 PTY fork）
- Ship 服务运行在 root 拥有的 `/opt/ship/venv`（uv 管理的 Python 3.13），agent 改动 conda base 不会影响它
- 系统目录对 shipyard 只读，`pacman` 无法使用；系统级工具通过 `nix profile install` 安装

### 4.3 路径沙箱（第三层）

[`workspace.py`](../pkgs/ship/app/workspace.py) 中的 `resolve_path()` 对所有文件系统操作做路径遍历防护：

```python
# 防护逻辑伪代码
def resolve_path(path: str) -> Path:
    workspace = Path("/workspace").resolve()
    candidate = (workspace / path) if not is_absolute(path) else Path(path)
    candidate = candidate.resolve()  # 解析 .. 和符号链接
    if not candidate.is_relative_to(workspace):
        raise HTTP 403  # 拒绝访问 workspace 外的路径
    return candidate
```

防护场景：

| 输入路径 | 解析结果 | 是否允许 |
|---------|---------|---------|
| `hello.txt` | `/workspace/hello.txt` | ✅ |
| `sub/dir/file.py` | `/workspace/sub/dir/file.py` | ✅ |
| `../../etc/passwd` | `/etc/passwd` | ❌ 403 |
| `/etc/shadow` | `/etc/shadow` | ❌ 403 |
| `/workspace/ok.txt` | `/workspace/ok.txt` | ✅ |

Shell 命令执行也有独立的路径校验逻辑（`cwd` 参数必须在 `/workspace` 内），见 [`user_manager.py`](../pkgs/ship/app/components/user_manager.py:236-249)。

---

## 5. 容器构建

Ship 使用 Arch Linux 基础镜像（`archlinux:base-devel`）构建（见 [`Dockerfile`](../pkgs/ship/Dockerfile)）。

### 5.1 Python 环境

```
/opt/conda    Miniforge，conda base 固定为 Python 3.13，归 shipyard 所有
              └─ uv pip install requirements-sandbox.txt（数据、文档、Playwright、ipykernel）
/opt/ship     Ship 服务：uv 管理的 Python 3.13 + venv，安装 requirements.txt（FastAPI、jupyter-client）
              └─ venv/share/jupyter/kernels/python3 → /opt/conda/bin/python
```

`pyproject.toml` 的 `dependencies` 只含服务依赖，预装给 agent 的库在 `sandbox` extra 里；
两份 requirements 由 `uv export` 生成。

### 5.2 最终镜像

```
archlinux:base-devel
  ├─ pacman（构建期，可用 PACMAN_MIRROR 指定镜像）:
  │   ├─ 构建: base-devel, cmake, ninja, meson, pkgconf
  │   ├─ 工具链: uv, bun, rustup, nix
  │   ├─ CLI: git, git-lfs, openssh, curl, wget, jq, ripgrep, fd, sqlite, tmux, htop, lsof, iproute2, rsync, tree, zip/unzip/7z, vim, nano
  │   ├─ 媒体/文档: ffmpeg, imagemagick, poppler
  │   ├─ 字体: noto-fonts, noto-fonts-cjk, noto-fonts-emoji, wqy-microhei, wqy-zenhei, ttf-dejavu
  │   ├─ 浏览器运行库: nss, gtk3, alsa-lib, libcups, libxss, ...
  │   └─ GPU: cuda（/opt/cuda，含 nvcc）, cudnn；移除 opencl-nvidia，驱动库由 Container Toolkit 注入
  │
  ├─ 用户 shipyard (UID 1000)，不在 sudoers 中
  ├─ Miniforge /opt/conda + 预装 Python 库
  ├─ Playwright Chromium → /ms-playwright
  ├─ rustup stable（minimal + rustfmt + clippy）→ /opt/rustup, /opt/cargo
  ├─ 单用户 Nix → /nix；nixpkgs 预取进 store，/etc/nix/registry.json 把 `nixpkgs` 固定到它
  ├─ node / npx → bun 的转发脚本（/usr/local/bin）
  ├─ Ship 服务 venv /opt/ship
  ├─ matplotlib 字体缓存预热（$XDG_CACHE_HOME=/var/cache/shipyard）
  │
  └─ ENTRYPOINT: entrypoint.sh（root → setpriv 降权）→ CMD: /opt/ship/venv/bin/python run.py
```

### 5.3 入口流程

[`entrypoint.sh`](../pkgs/ship/entrypoint.sh) 在容器启动时：

1. 把 `SHIPYARD_*_MIRROR` 翻译成各包管理器的设置并 export（cargo 写入 `$CARGO_HOME/config.toml`），见 [`deploy/docker/README.md`](../deploy/docker/README.md#沙箱包管理镜像源)
2. 生成 `/workspace/.bay_env.sh`，去掉旧镜像写进 `.bashrc` 的固定 PATH，建立 `~/.nix-profile` 链接
3. 修复 `/workspace` 目录所有权为 `shipyard:shipyard`（处理卷挂载权限问题）
4. 注入内置 skills 到 `/workspace/skills/`（per-skill overwrite，见 [§10](#10-扩展机制--built-in-skills-注入)）
5. `exec setpriv ... -- "$@"` 以 shipyard 身份执行 CMD（`/opt/ship/venv/bin/python run.py`）

### 5.4 应用启动流程

```
/opt/ship/venv/bin/python run.py   (shipyard)
  └─ uvicorn "app.main:app" host=0.0.0.0 port=8123
       └─ lifespan 启动:
            └─ 预热 Jupyter Kernel (get_or_create_kernel)
                 ├─ AsyncKernelManager().start_kernel(cwd="/workspace")
                 └─ 初始化 matplotlib 中文字体配置
       └─ 注册路由: /fs, /ipython, /shell, /term
       └─ 开始接收请求
```

### 5.5 预装软件清单

| 类别 | 工具 | 用途 |
|------|------|------|
| Python | 3.13（conda base） | 运行时 + IPython 内核；conda / uv 安装依赖 |
| bun | 系统包 | 代替 Node.js；`node`、`npx` 转发给 bun |
| Rust | rustup stable | rustc、cargo、rustfmt、clippy |
| Nix | 单用户 | `nix profile install nixpkgs#...` 安装其它系统工具 |
| CUDA / cuDNN | 系统包 | `/opt/cuda`，含 nvcc |
| Git | 系统包 | 版本控制 |
| matplotlib | Python 包 | 图表绘制（含中文字体） |
| pandas/numpy/scikit-learn | Python 包 | 数据科学 |
| Pillow/OpenCV | Python 包 | 图像处理 |
| pdfplumber/pypdf/reportlab | Python 包 | PDF 处理 |
| python-docx/python-pptx/openpyxl | Python 包 | Office 文档处理 |
| beautifulsoup4/lxml | Python 包 | HTML/XML 解析 |

---

## 6. Bay ↔ Ship 交互协议

Bay 通过 [`ShipAdapter`](../pkgs/bay/app/adapters/ship.py) 与 Ship 容器通信。这是一个 **纯 HTTP 适配器**，使用 `httpx.AsyncClient` 连接池实现高性能请求复用。

### 6.1 能力映射

| Bay 能力 | Ship 端点 | 方法 | 说明 |
|----------|-----------|------|------|
| `python` | `/ipython/exec` | POST | IPython 内核执行 Python 代码 |
| `shell` | `/shell/exec` | POST | Shell 命令执行 |
| `filesystem` | `/fs/create_file` | POST | 创建文件 |
| `filesystem` | `/fs/read_file` | POST | 读取文件 |
| `filesystem` | `/fs/write_file` | POST | 写入文件 |
| `filesystem` | `/fs/edit_file` | POST | 编辑文件（搜索替换） |
| `filesystem` | `/fs/delete_file` | POST | 删除文件/目录 |
| `filesystem` | `/fs/list_dir` | POST | 列出目录 |
| `filesystem` | `/fs/upload` | POST | 上传二进制文件 |
| `filesystem` | `/fs/download` | GET | 下载文件 |
| `terminal` | `/term/ws` | WS | WebSocket 交互终端 |

### 6.2 通信流程

```
Bay (ShipAdapter)                              Ship Container
       │                                              │
       │──── GET /health ─────────────────────────────▶│  健康检查
       │◀─── 200 {"status": "healthy"} ───────────────│
       │                                              │
       │──── GET /meta ───────────────────────────────▶│  获取运行时元数据
       │◀─── 200 {runtime, workspace, capabilities} ──│  (结果会被缓存)
       │                                              │
       │──── POST /ipython/exec ──────────────────────▶│  执行 Python
       │     {"code": "...", "timeout": 30}           │
       │◀─── 200 {success, output, error} ────────────│
       │                                              │
       │──── POST /shell/exec ────────────────────────▶│  执行 Shell
       │     {"command": "...", "timeout": 30}        │
       │◀─── 200 {success, stdout, stderr, ...} ──────│
       │                                              │
       │──── POST /fs/upload ─────────────────────────▶│  上传文件
       │     multipart/form-data {file, file_path}    │  (Cargo 传输)
       │◀─── 200 {success, file_path, size} ──────────│
       │                                              │
```

### 6.3 超时策略

ShipAdapter 采用 **双层超时**：

- **请求超时**: 用户指定的 `timeout` 参数（如 30s）
- **传输超时**: `timeout + 5s`（给予网络传输额外缓冲）

```python
# 示例：exec_python 的超时设置
result = await self._post(
    "/ipython/exec",
    {"code": code, "timeout": timeout, "silent": False},
    timeout=timeout + 5,  # 传输超时 = 执行超时 + 5s
)
```

### 6.4 `/meta` 端点响应格式

Ship 的 `/meta` 端点返回完整的运行时自描述信息，Bay 用此进行版本校验和能力发现：

```json
{
  "runtime": {
    "name": "ship",
    "version": "0.1.0",
    "api_version": "v1",
    "build": {
      "image": "ship:default",
      "image_digest": null,
      "git_sha": null
    }
  },
  "workspace": {
    "mount_path": "/workspace"
  },
  "capabilities": {
    "filesystem": {
      "operations": ["create", "read", "write", "edit", "delete", "list", "upload", "download"],
      "path_mode": "relative_to_mount",
      "endpoints": { ... }
    },
    "shell": {
      "operations": ["exec", "processes"],
      "endpoints": { ... }
    },
    "python": {
      "operations": ["exec"],
      "engine": "ipython",
      "endpoints": { ... }
    },
    "terminal": {
      "operations": ["ws"],
      "protocol": "websocket",
      "endpoints": { ... }
    }
  },
  "built_in_skills": [
    {
      "name": "python-sandbox",
      "description": "Ship runtime usage guide for code execution sandboxes...",
      "path": "/app/skills/python-sandbox/SKILL.md"
    }
  ]
}
```

> **注意**: `built_in_skills` 字段由 [`_scan_built_in_skills()`](../pkgs/ship/app/main.py:93) 在请求时扫描 `/app/skills/*/SKILL.md` 并解析 YAML frontmatter 生成。`path` 字段返回的是镜像内路径，用于诊断。

### 6.5 连接池

ShipAdapter 优先使用 Bay 全局的 `http_client_manager.client`（共享 `httpx.AsyncClient`），实现跨请求的 TCP 连接复用。测试场景下会 fallback 到临时创建的 client。

---

## 7. IPython 输出格式

Ship 的 IPython 内核支持多种输出格式，通过 Jupyter 消息协议采集执行结果。

### 7.1 输出结构

`/ipython/exec` 端点返回的 `output` 字段结构如下：

```json
{
  "success": true,
  "execution_count": 1,
  "output": {
    "text": "纯文本输出内容",
    "images": [
      {"image/png": "<base64-encoded-png>"}
    ]
  },
  "error": null
}
```

### 7.2 输出类型

| Jupyter 消息类型 | 采集内容 | 映射到 output 字段 |
|-----------------|---------|-------------------|
| `stream` | `print()` 等标准输出 | `text`（拼接） |
| `execute_result` | 表达式求值结果 | `text/plain` → `text`；`image/png` → `images` |
| `display_data` | `plt.show()` 等显示数据 | `image/png` → `images`；`text/plain` → `text` |
| `error` | 异常 traceback | `error` 字段 |

### 7.3 图表输出流程

```
用户代码:
  import matplotlib.pyplot as plt
  plt.plot([1,2,3], [4,5,6])
  plt.title("测试图表")
  plt.show()

执行流程:
  1. IPython 内核执行代码
  2. matplotlib 使用 Agg 后端生成 PNG
  3. 通过 display_data 消息发送 base64 PNG
  4. Ship 采集到 images 数组
  5. Bay 通过 ShipAdapter 接收完整 output 对象
  6. MCP 层将 base64 PNG 返回给 AI Agent
```

### 7.4 中文字体支持

内核初始化时配置了字体 fallback 链（见 [`ipython.py`](../pkgs/ship/app/components/ipython.py:62-85)）：

```
Noto Sans CJK SC → Noto Sans CJK JP → Noto Sans CJK TC → WenQuanYi Zen Hei → WenQuanYi Micro Hei → Symbola → Noto Color Emoji → DejaVu Sans
```

- **CJK 字体**: 支持中日韩文字的图表标题和标签，包括 Noto CJK 和 WenQuanYi
- **Emoji 字体**: Noto Color Emoji + Symbola fallback
- **DejaVu Sans**: 最终 fallback

---

## 8. 请求/响应数据模型

### 8.1 文件系统

#### `POST /fs/create_file`

**请求体** (`CreateFileRequest`):

```json
{
  "path": "hello.txt",         // 相对或绝对路径
  "content": "Hello World!",   // 文件内容（默认空字符串）
  "mode": 420                  // Unix 权限模式（默认 0o644 = 420）
}
```

**响应**:

```json
{
  "success": true,
  "message": "File created: hello.txt",
  "path": "/workspace/hello.txt"
}
```

#### `POST /fs/read_file`

**请求体** (`ReadFileRequest`):

```json
{
  "path": "hello.txt",
  "encoding": "utf-8",    // 默认 utf-8
  "offset": 1,            // 起始行号（1-based），null 表示从头
  "limit": 100            // 最大读取行数，null 表示全部
}
```

**响应** (`FileResponse`):

```json
{
  "content": "Hello World!",
  "path": "/workspace/hello.txt",
  "size": 12
}
```

#### `POST /fs/write_file`

**请求体** (`WriteFileRequest`):

```json
{
  "path": "hello.txt",
  "content": "New content",
  "mode": "w",            // "w" 覆盖写入，"a" 追加
  "encoding": "utf-8"
}
```

#### `POST /fs/edit_file`

**请求体** (`EditFileRequest`):

```json
{
  "path": "hello.txt",
  "old_string": "Hello",      // 要查找的字符串
  "new_string": "Hi",         // 替换后的字符串
  "replace_all": false,       // 是否替换所有匹配（默认 false）
  "encoding": "utf-8"
}
```

**响应**:

```json
{
  "success": true,
  "message": "File edited: hello.txt",
  "path": "/workspace/hello.txt",
  "replacements": 1,
  "size": 10
}
```

> **注意**: 当 `old_string` 出现多次且 `replace_all=false` 时，返回 400 错误，要求显式设置 `replace_all=true`。

#### `POST /fs/list_dir`

**请求体** (`ListDirRequest`):

```json
{
  "path": ".",              // 默认当前目录
  "show_hidden": false      // 是否显示隐藏文件
}
```

**响应** (`ListDirResponse`):

```json
{
  "files": [
    {
      "name": "src",
      "path": "/workspace/src",
      "is_file": false,
      "is_dir": true,
      "size": null,
      "modified_time": 1707550000.0
    },
    {
      "name": "main.py",
      "path": "/workspace/main.py",
      "is_file": true,
      "is_dir": false,
      "size": 1024,
      "modified_time": 1707550000.0
    }
  ],
  "current_path": "/workspace"
}
```

> 结果按 **目录优先** 排序，同类按名称字母顺序排列。

### 8.2 IPython

#### `POST /ipython/exec`

**请求体** (`ExecuteCodeRequest`):

```json
{
  "code": "print('hello')",
  "timeout": 30,           // 超时秒数（默认 30）
  "silent": false           // 静默模式不记录历史
}
```

**响应** (`ExecuteCodeResponse`):

```json
{
  "success": true,
  "execution_count": 1,
  "output": {
    "text": "hello",
    "images": []
  },
  "error": null
}
```

### 8.3 Shell

#### `POST /shell/exec`

**请求体** (`ExecuteShellRequest`):

```json
{
  "command": "ls -la",
  "cwd": null,              // 工作目录（相对于 /workspace）
  "env": null,              // 额外环境变量
  "timeout": 30,            // 超时秒数
  "shell": true,            // 是否使用 shell 模式
  "background": false       // 是否后台执行
}
```

**前台响应** (`ExecuteShellResponse`):

```json
{
  "success": true,
  "return_code": 0,
  "stdout": "total 4\ndrwxr-xr-x 2 ...",
  "stderr": "",
  "pid": 12345,
  "process_id": null,
  "error": null
}
```

**后台响应**（`background: true`）:

```json
{
  "success": true,
  "return_code": 0,
  "stdout": "",
  "stderr": "",
  "pid": 12346,
  "process_id": "a1b2c3d4",
  "error": null
}
```

---

## 9. 错误处理与错误码

### 9.1 HTTP 状态码使用

| 状态码 | 场景 |
|-------|------|
| 200 | 请求成功 |
| 400 | 参数错误（如 edit_file 的 old_string 未找到、路径不是文件等） |
| 403 | 路径越界（路径遍历防护触发） |
| 404 | 文件/目录/内核不存在 |
| 500 | 服务器内部错误 |

### 9.2 错误响应格式

Ship 使用 FastAPI 标准的 `HTTPException`，错误响应格式：

```json
{
  "detail": "Access denied: path must be within workspace /workspace"
}
```

### 9.3 IPython 执行错误

IPython 执行错误不通过 HTTP 错误码返回，而是在响应体中标识：

```json
{
  "success": false,
  "execution_count": 2,
  "output": {"text": "", "images": []},
  "error": "Traceback (most recent call last):\n  ...\nNameError: name 'undefined_var' is not defined"
}
```

### 9.4 Shell 执行错误

类似地，Shell 命令执行错误通过 `return_code` 和 `stderr` 字段传达：

```json
{
  "success": false,
  "return_code": 127,
  "stdout": "",
  "stderr": "bash: nonexistent_command: command not found",
  "error": null
}
```

超时情况会设置 `error` 字段：

```json
{
  "success": false,
  "return_code": -1,
  "stdout": "",
  "stderr": "",
  "error": "Command timed out"
}
```

---

## 10. 扩展机制 — Built-in Skills 注入

Ship 和 Gull 容器各自携带 **Built-in Skills**（内置技能文件），在容器启动时自动注入到共享 Cargo Volume 的 `/workspace/skills/` 目录。Skills 是 **结构化的知识文档**，用于指导 AI Agent 如何使用容器内预装的工具和库。

### 10.1 注入机制

#### 容器自注入（Container Self-Injection）

每个容器镜像在构建时将 skills 打包到 `/app/skills/` 目录，容器启动时通过 [`entrypoint.sh`](../pkgs/ship/entrypoint.sh) 注入到共享的 `/workspace/skills/`：

```
┌──── Ship 镜像 ────┐    启动时注入     ┌──── Cargo Volume ────────────────────┐
│  /app/skills/      │ ═══════════════▶ │  /workspace/skills/                  │
│  └─ python-sandbox/│    rm -rf + cp   │  ├── python-sandbox/   ← Ship 注入   │
│     └─ SKILL.md    │                  │  │   └── SKILL.md                    │
└────────────────────┘                  │  ├── browser-automation/ ← Gull 注入  │
                                        │  │   ├── SKILL.md                    │
┌──── Gull 镜像 ────┐    启动时注入     │  │   └── references/                 │
│  /app/skills/      │ ═══════════════▶ │  │       └── browser.md              │
│  └─ browser-       │    rm -rf + cp   │  └── my-custom-skill/  ← Agent 自定义 │
│     automation/    │                  │      └── SKILL.md                    │
│     ├─ SKILL.md    │                  └──────────────────────────────────────┘
│     └─ references/ │
│        └─ browser.md│
└────────────────────┘
```

#### 铺平命名空间（Flat Namespace）

所有 skills 直接放在 `/workspace/skills/<skill_name>/` 下，**不分 runtime 子目录**。Ship 和 Gull 的 built-in skill 使用不同名称避免冲突。上层 agent 也可以在此目录下自由添加自定义 skill。

#### Per-skill Overwrite（幂等覆盖）

注入时按 skill 级别逐个覆盖：

```bash
for skill_dir in /app/skills/*/; do
    skill_name=$(basename "$skill_dir")
    rm -rf "/workspace/skills/$skill_name"   # 只删除本 skill
    cp -r "$skill_dir" "/workspace/skills/$skill_name"
done
```

**关键特性**：
- 每个容器只覆盖自己管理的 skill，不影响其他容器的 built-in skill 和 agent 的自定义 skill
- 容器重启后 built-in skill 恢复为镜像版本（idempotent）
- 用户修改的 built-in skill 会在下次容器启动时被覆盖（by design）

### 10.2 镜像构建配置

#### Ship

- [`.dockerignore`](../pkgs/ship/.dockerignore) 显式允许 `skills/**` 进入镜像
- `Dockerfile` 使用 `COPY . .` 将 skills 目录包含在内
- [`entrypoint.sh`](../pkgs/ship/entrypoint.sh) 中实现 shell 注入逻辑，注入后执行 `chown -R shipyard:shipyard`

#### Gull

- [`Dockerfile`](../pkgs/gull/Dockerfile) 显式 `COPY skills ./skills`
- [`entrypoint.sh`](../pkgs/gull/entrypoint.sh) 中实现 shell 注入逻辑（与 Ship 一致的 per-skill overwrite）

### 10.3 SKILL.md 格式

每个 Skill 目录至少包含一个 `SKILL.md` 文件，带有 YAML frontmatter：

```yaml
---
name: python-sandbox
description: "Ship runtime usage guide for code execution sandboxes..."
---
```

可选附加文件：
- `references/*.md` — 更详细的参考资料
- `scripts/` — 辅助脚本（未来扩展）
- `assets/` — 静态资源（未来扩展）

### 10.4 内置 Skills

| 容器 | Skill | 描述 | 文件 |
|------|-------|------|------|
| Ship | `python-sandbox` | Python/Shell/Filesystem 执行指南 | [`SKILL.md`](../pkgs/ship/skills/python-sandbox/SKILL.md) |
| Gull | `browser-automation` | 浏览器自动化操作指南 | [`SKILL.md`](../pkgs/gull/skills/browser-automation/SKILL.md) + [`references/browser.md`](../pkgs/gull/skills/browser-automation/references/browser.md) |

### 10.5 `/meta` 端点暴露

Ship 和 Gull 的 `/meta` 端点均返回 `built_in_skills` 字段，列出镜像内打包的所有 skill 元数据。Bay 和 MCP 层可通过此字段观测容器携带了哪些 built-in skill。

扫描逻辑：[`_scan_built_in_skills()`](../pkgs/ship/app/main.py:93) 遍历 `/app/skills/*/SKILL.md`，解析 YAML frontmatter 提取 `name` 和 `description`。

### 10.6 三层 Skill 体系

Shipyard Neo 中有三个层级的 skill，各自独立管理：

| 层级 | 位置（源码） | 位置（运行时） | 管理者 |
|------|-------------|---------------|--------|
| MCP 层 | `skills/shipyard-neo/` | Agent 本地 `.kilocode/skills/` | MCP Server / Agent 框架 |
| Ship 内置 | `pkgs/ship/skills/` | `/workspace/skills/` | Ship 容器 entrypoint |
| Gull 内置 | `pkgs/gull/skills/` | `/workspace/skills/` | Gull 容器 entrypoint |

### 10.7 设计理念

Skills 不是可执行代码插件，而是 **知识增强** 机制：

- AI Agent 在需要特定能力时，读取对应的 SKILL.md
- SKILL.md 提供该领域的完整操作指南、代码模板和安全约束
- Agent 根据指南生成代码，通过 `/ipython/exec` 或 `/shell/exec` 执行
- 容器自注入确保 skills 始终与镜像版本一致，无需外部协调

---

## 11. Ship 与 Gull 对比

Shipyard 平台有两种容器运行时：**Ship**（代码执行）和 **Gull**（浏览器自动化），它们通过 Bay 的 Capability Router 协同工作。

### 11.1 定位对比

| 维度 | Ship | Gull |
|------|------|------|
| **角色** | 代码执行沙箱 | 浏览器自动化运行时 |
| **核心能力** | filesystem, python, shell, terminal | browser |
| **端口** | 8123 | 8080 |
| **API 风格** | 多端点（每个能力独立路由） | 单端点 CLI 透传（`POST /exec`） |
| **执行引擎** | IPython 内核 + subprocess | agent-browser CLI |
| **状态管理** | IPython 内核状态 + 后台进程表 | 浏览器 Session + Profile 持久化 |
| **用户隔离** | 整个进程降权为 shipyard（无 sudo） | 无（CLI 进程隔离） |

### 11.2 架构差异

```
Ship 容器                          Gull 容器
┌─────────────────────┐           ┌─────────────────────┐
│ FastAPI :8123        │           │ FastAPI :8080        │
│  /fs/*               │           │  /exec              │
│  /ipython/exec       │           │  /exec_batch        │
│  /shell/exec         │           │  /health            │
│  /term/ws            │           │  /meta              │
│  /health, /meta      │           └─────────┬───────────┘
└─────────┬───────────┘                      │
          │                           agent-browser CLI
   Jupyter Kernel                            │
   + subprocess                       Chromium Browser
   + PTY                                     │
          │                                  │
    /workspace ◀──── Cargo Volume ────▶ /workspace
```

### 11.3 协同模式

Ship 和 Gull 共享同一个 **Cargo Volume**（`/workspace`），实现跨运行时的文件传递：

1. **浏览器截图 → 代码分析**: Gull 执行 `screenshot /workspace/page.png` → Ship 通过 IPython 分析图片
2. **代码生成 → 浏览器部署**: Ship 生成前端代码到 `/workspace/dist/` → Gull 打开本地文件预览
3. **数据抓取 → 数据处理**: Gull 抓取网页数据保存到文件 → Ship 用 pandas 处理

### 11.4 Bay 适配器对比

| 特性 | `ShipAdapter` | `GullAdapter` |
|------|--------------|---------------|
| 通信协议 | HTTP + WebSocket | HTTP |
| 连接池 | 共享 httpx.AsyncClient | 共享 httpx.AsyncClient |
| Meta 缓存 | ✅ | ✅ |
| 支持能力 | python, shell, filesystem, terminal | browser |
| 错误类型 | ShipError, RequestTimeoutError | ShipError (复用) |
